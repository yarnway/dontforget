/// A token belongs to one gate and one runtime session. It cannot be forged or
/// carried into a later recovery, even if the same controller remains mounted.
class RuntimeRecoveryToken {
  RuntimeRecoveryToken._(this._owner, this.epoch);
  final RuntimeRecoveryGate _owner;
  final int epoch;
}

class RuntimeRecoveryException implements Exception {
  const RuntimeRecoveryException();
  @override
  String toString() => 'Runtime is unavailable during data recovery.';
}

/// Coordinates local producers without waiting for remote AI or file pickers.
/// Those operations keep their original token and discard any late result.
class RuntimeRecoveryGate {
  bool _paused = false;
  bool _quiesced = false;
  int _epoch = 0;
  Future<RuntimeRecoveryToken>? _pausing;
  final Map<Object, Future<void> Function()> _participants = {};

  bool get paused => _paused;
  int get epoch => _epoch;

  RuntimeRecoveryToken capture() {
    if (_paused) throw const RuntimeRecoveryException();
    return RuntimeRecoveryToken._(this, _epoch);
  }

  bool isCurrent(RuntimeRecoveryToken? token) =>
      token != null &&
      identical(token._owner, this) &&
      !_paused &&
      token.epoch == _epoch;

  void check(RuntimeRecoveryToken? token) {
    if (!isCurrent(token)) throw const RuntimeRecoveryException();
  }

  void register(Object owner, Future<void> Function() quiesce) {
    if (_paused) throw const RuntimeRecoveryException();
    _participants[owner] = quiesce;
  }

  void unregister(Object owner) => _participants.remove(owner);

  Future<RuntimeRecoveryToken> pause() {
    if (_pausing != null) return _pausing!;
    if (!_paused) {
      _paused = true;
      _epoch++;
    }
    final token = RuntimeRecoveryToken._(this, _epoch);
    if (_quiesced) return Future.value(token);
    // Invalidate synchronously, then wait for every local cleanup even when one
    // fails. A failed cleanup keeps the gate closed and may be retried.
    final work =
        Future.wait(
          List.of(
            _participants.values,
          ).map((quiesce) => Future<void>.sync(quiesce)),
          eagerError: false,
        ).then((_) {
          _quiesced = true;
          return token;
        });
    return _pausing = work.whenComplete(() => _pausing = null);
  }

  void resume(RuntimeRecoveryToken pausedToken) {
    if (!_paused ||
        !_quiesced ||
        _pausing != null ||
        !identical(pausedToken._owner, this) ||
        pausedToken.epoch != _epoch) {
      throw const RuntimeRecoveryException();
    }
    _quiesced = false;
    _paused = false;
  }
}
