package com.yarnway.dontforget

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var speechChannel: MethodChannel? = null
    private var speechBridge: LocalSpeechBridge? = null
    private var protocolChannel: MethodChannel? = null
    private var protocolReady = false
    private var pendingProtocolUrl: String? = null
    private var shareChannel: MethodChannel? = null
    private var shareBridge: SharedTextBridge? = null
    private var shareReady = false
    private var currentShareId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        currentShareId = savedInstanceState?.getString("dontforget.share.id")
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        currentShareId?.let { outState.putString("dontforget.share.id", it) }
        super.onSaveInstanceState(outState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        speechBridge = LocalSpeechBridge(applicationContext)
        speechChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "dontforget/local_speech").also { it.setMethodCallHandler(speechBridge) }
        protocolReady = false
        pendingProtocolUrl = protocolUrl(intent)
        protocolChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.yarnway.dontforget/protocol"
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "initialize") {
                    val initial = pendingProtocolUrl
                    pendingProtocolUrl = null
                    protocolReady = true
                    result.success(initial)
                } else {
                    result.notImplemented()
                }
            }
        }
        shareBridge = SharedTextBridge(applicationContext)
        shareReady = false
        receiveSharedText(intent, currentShareId)
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.yarnway.dontforget/share").also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    val bridge = checkNotNull(shareBridge)
                    when (call.method) {
                        "initialize" -> {
                            bridge.initialize(call.arguments as String)
                            shareReady = true
                            result.success(null)
                        }
                        "pending" -> result.success(bridge.pending())
                        "acknowledge" -> {
                            bridge.acknowledge(call.arguments as String)
                            result.success(null)
                        }
                        "reset" -> {
                            bridge.reset()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("share_storage", "Shared content is unavailable", null)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val url = protocolUrl(intent)
        if (url != null) {
            if (protocolReady) {
                protocolChannel?.invokeMethod("onProtocolUrl", url)
            } else {
                // Before Dart is ready, retain the latest explicit activation.
                pendingProtocolUrl = url
            }
        }
        receiveSharedText(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        speechChannel?.setMethodCallHandler(null)
        speechChannel = null
        speechBridge?.dispose()
        speechBridge = null
        protocolChannel?.setMethodCallHandler(null)
        protocolChannel = null
        protocolReady = false
        pendingProtocolUrl = null
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        shareBridge = null
        shareReady = false
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun receiveSharedText(incoming: Intent?, restoredId: String? = null) {
        try {
            val id = shareBridge?.receive(incoming, restoredId) ?: return
            currentShareId = id
            if (shareReady) shareChannel?.invokeMethod("onPendingShares", null)
        } catch (_: Exception) {
            val language = resources.configuration.locales[0].language
            val message = when (language) {
                "zh" -> "无法接收分享，请检查文字长度或先处理分享草稿后重试。"
                "ja" -> "共有を受信できません。文字数と共有下書きを確認して再試行してください。"
                else -> "Could not receive this share. Check its length or handle pending shared drafts, then retry."
            }
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    private fun protocolUrl(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != "dontforget") return null
        val url = uri.toString()
        return url.takeIf { it.length <= 8192 }
    }
}
