import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';

final liveDictationServiceProvider = Provider<LiveDictationService>((ref) {
  final service = LiveDictationService();
  final gate = ref.read(runtimeRecoveryGateProvider);
  gate.register(service, service.cancel);
  ref.onDispose(() {
    gate.unregister(service);
    service.dispose();
  });
  return service;
});

class DictationAvailability {
  const DictationAvailability(this.available, this.locale);
  final bool available;
  final String locale;
}

class DictationEvent {
  const DictationEvent(this.session, this.type, this.text, [this.code]);
  final String session, type, text;
  final String? code;
  bool get terminal => const {'final', 'error', 'cancelled'}.contains(type);
}

/// Session-scoped Android microphone dictation. No recorded file or app API key.
class LiveDictationService with WidgetsBindingObserver {
  static final _channelOwners = <String, LiveDictationService>{};
  LiveDictationService({
    MethodChannel? channel,
    bool? isAndroid,
    this.sessionTimeout = const Duration(seconds: 65),
    this.stopTimeout = const Duration(seconds: 10),
  }) : supported = isAndroid ?? Platform.isAndroid,
       _channel = channel ?? const MethodChannel('dontforget/live_dictation') {
    if (supported) {
      _channelOwners[_channel.name] = this;
      _channel.setMethodCallHandler(_onNative);
      WidgetsBinding.instance.addObserver(this);
    }
  }
  final bool supported;
  final MethodChannel _channel;
  final Duration sessionTimeout, stopTimeout;
  final _events = StreamController<DictationEvent>.broadcast(sync: true);
  Stream<DictationEvent> get events => _events.stream;
  String? _session;
  String _text = '';
  Timer? _timer;
  bool _disposed = false, _stopping = false;
  Future<void>? _cancelling;
  bool get active => _session != null;

  Future<DictationAvailability> availability() async {
    if (!supported) return const DictationAvailability(false, 'en-US');
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'availability',
    );
    return DictationAvailability(
      value?['available'] == true,
      value?['locale'] == 'zh-CN' ? 'zh-CN' : 'en-US',
    );
  }

  Future<void> setLanguage(String locale) async {
    if (active) throw PlatformException(code: 'dictation_busy');
    if (!const {'zh-CN', 'en-US'}.contains(locale)) {
      throw PlatformException(code: 'dictation_language');
    }
    await _channel.invokeMethod<void>('setLanguage', {'locale': locale});
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  Future<void> start(String session) async {
    if (_disposed || !supported) {
      throw PlatformException(code: 'dictation_unavailable');
    }
    if (active || _cancelling != null) {
      throw PlatformException(code: 'dictation_busy');
    }
    _session = session;
    _text = '';
    _stopping = false;
    _events.add(DictationEvent(session, 'starting', ''));
    _timer = Timer(
      sessionTimeout,
      () => unawaited(_cancelWith('dictation_timeout')),
    );
    try {
      await _channel.invokeMethod<void>('start', {'session': session});
    } on PlatformException catch (error) {
      if (_session == session) _finish('error', error.code);
    } catch (_) {
      if (_session == session) _finish('error', 'dictation_unavailable');
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (_disposed || call.method != 'onEvent' || call.arguments is! Map) return;
    final value = call.arguments as Map;
    if (_session == null ||
        value['session'] != _session ||
        _cancelling != null) {
      return;
    }
    final type = value['type'];
    if (!const {
      'ready',
      'partial',
      'finishing',
      'final',
      'error',
      'cancelled',
    }.contains(type)) {
      return;
    }
    final text = value['text'];
    if (text is! String || text.length > 32000) return;
    // Some recognizers send a blank final after a valid partial. Preserve it.
    if (text.trim().isNotEmpty) _text = text;
    final event = DictationEvent(
      _session!,
      type as String,
      _text,
      value['code'] is String ? value['code'] as String : null,
    );
    if (event.terminal) {
      _clear();
    } else if (type == 'finishing') {
      _armStopTimeout();
    }
    _events.add(event);
  }

  Future<void> stop() async {
    final id = _session;
    if (id == null || _stopping) return;
    _stopping = true;
    _events.add(DictationEvent(id, 'finishing', _text));
    _armStopTimeout();
    try {
      await _channel.invokeMethod<void>('stop', {'session': id});
    } catch (_) {
      if (_session == id) await _cancelWith('dictation_unavailable');
    }
  }

  void _armStopTimeout() {
    _stopping = true;
    _timer?.cancel();
    _timer = Timer(
      stopTimeout,
      () => unawaited(_cancelWith('dictation_timeout')),
    );
  }

  Future<void> cancel() => _cancelWith(null);
  Future<void> _cancelWith(String? code) {
    if (_cancelling != null) return _cancelling!;
    final id = _session;
    if (id == null) return Future.value();
    _timer?.cancel();
    return _cancelling = (() async {
      try {
        await _channel
            .invokeMethod<void>('cancel', {'session': id})
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        /* Native sessions also have a bounded deadline. */
      }
      if (_session == id) _finish(code == null ? 'cancelled' : 'error', code);
    })().whenComplete(() => _cancelling = null);
  }

  void _finish(String type, String? code) {
    final id = _session;
    if (id == null) return;
    final text = _text;
    _clear();
    if (!_disposed) _events.add(DictationEvent(id, type, text, code));
  }

  void _clear() {
    _timer?.cancel();
    _session = null;
    _stopping = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(cancel());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Detach synchronously. A later engine/provider may already own this name
    // when the asynchronous native cancellation finishes.
    if (identical(_channelOwners[_channel.name], this)) {
      _channelOwners.remove(_channel.name);
      _channel.setMethodCallHandler(null);
    }
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      cancel().whenComplete(() {
        _events.close();
      }),
    );
  }
}
