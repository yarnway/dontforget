package com.yarnway.dontforget

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var speechChannel: MethodChannel? = null
    private var speechBridge: LocalSpeechBridge? = null
    private var protocolChannel: MethodChannel? = null
    private var protocolReady = false
    private var pendingProtocolUrl: String? = null

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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val url = protocolUrl(intent) ?: return
        if (protocolReady) {
            protocolChannel?.invokeMethod("onProtocolUrl", url)
        } else {
            // Before Dart is ready, retain the latest explicit activation.
            pendingProtocolUrl = url
        }
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
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun protocolUrl(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != "dontforget") return null
        val url = uri.toString()
        return url.takeIf { it.length <= 8192 }
    }
}
