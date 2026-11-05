package com.yarnway.dontforget

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Live microphone recognition using the user's configured Android speech service. */
class LiveDictationBridge(private val activity: Activity, private val channel: MethodChannel) :
    MethodChannel.MethodCallHandler {
    companion object { const val PERMISSION_REQUEST = 0xD17A }
    private val handler = Handler(Looper.getMainLooper())
    private val prefs = activity.getSharedPreferences("dontforget.dictation.v1", 0)
    private var session: String? = null
    private var recognizer: SpeechRecognizer? = null
    private var pending: MethodChannel.Result? = null
    private var partial = ""
    private var finishing = false
    private var permissionOutstanding = false
    private val deadline = Runnable { finish("error", "dictation_timeout") }
    private fun language(): String = prefs.getString("locale", null)
        ?.takeIf { it == "zh-CN" || it == "en-US" }
        ?: if (Locale.getDefault().language == "zh") "zh-CN" else "en-US"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "availability" -> result.success(mapOf(
                "available" to SpeechRecognizer.isRecognitionAvailable(activity), "locale" to language()))
            "setLanguage" -> {
                val locale = call.argument<String>("locale")
                if (session != null) result.error("dictation_busy", null, null)
                else if (locale != "zh-CN" && locale != "en-US") result.error("dictation_language", null, null)
                else if (!prefs.edit().putString("locale", locale).commit()) result.error("dictation_settings", null, null)
                else result.success(null)
            }
            "openSettings" -> try {
                activity.startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS))
                result.success(null)
            } catch (_: Exception) { result.error("dictation_unavailable", null, null) }
            "start" -> {
                val id = call.argument<String>("session")
                if (session != null || permissionOutstanding) { result.error("dictation_busy", null, null); return }
                if (id.isNullOrBlank() || id.length > 80) { result.error("dictation_session", null, null); return }
                if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
                    result.error("dictation_unavailable", null, null); return
                }
                session = id; partial = ""; finishing = false; pending = result
                handler.postDelayed(deadline, 60000)
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    permissionOutstanding = true
                    activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
                } else begin()
            }
            "stop" -> {
                if (call.argument<String>("session") == session && session != null) {
                    if (recognizer == null) finish("cancelled")
                    else if (!finishing) {
                        finishing = true
                        emit("finishing")
                        handler.removeCallbacks(deadline); handler.postDelayed(deadline, 8000)
                        try { recognizer?.stopListening() } catch (_: Exception) { finish("error", "dictation_unavailable") }
                    }
                }
                result.success(null)
            }
            "cancel" -> {
                if (call.argument<String>("session") == session) finish("cancelled")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onPermissionResult(grants: IntArray) {
        if (!permissionOutstanding) return
        permissionOutstanding = false
        if (session == null) return // Cancellation during the permission dialog cannot start the microphone.
        if (grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) begin()
        else finish("error", "dictation_permission")
    }

    private fun begin() {
        val id = session ?: return
        try {
            val engine = SpeechRecognizer.createSpeechRecognizer(activity)
            recognizer = engine
            engine.setRecognitionListener(object : RecognitionListener {
                private fun current() = session == id && recognizer === engine
                override fun onReadyForSpeech(params: Bundle?) { if (current()) emit("ready") }
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() { if (current()) {
                    finishing = true; emit("finishing")
                    handler.removeCallbacks(deadline); handler.postDelayed(deadline, 8000)
                } }
                override fun onError(error: Int) { if (current()) finish("error", when (error) {
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "dictation_permission"
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "dictation_network"
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "dictation_empty"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "dictation_busy"
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "dictation_language"
                    else -> "dictation_unavailable"
                }) }
                override fun onResults(results: Bundle?) { if (current()) {
                    val text = recognized(results)
                    if (text.isNotBlank()) partial = text
                    finish(if (partial.isBlank()) "error" else "final", if (partial.isBlank()) "dictation_empty" else null)
                } }
                override fun onPartialResults(results: Bundle?) { if (current()) {
                    val text = recognized(results)
                    if (text.isNotBlank()) { partial = text; emit("partial") }
                } }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            engine.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            })
            pending?.success(null); pending = null
        } catch (_: SecurityException) { finish("error", "dictation_permission") }
        catch (_: Exception) { finish("error", "dictation_unavailable") }
    }

    private fun recognized(bundle: Bundle?): String = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        ?.firstOrNull()?.take(32000)?.trim() ?: ""
    private fun emit(type: String, code: String? = null, id: String? = session) {
        if (id == null) return
        channel.invokeMethod("onEvent", mapOf("session" to id, "type" to type, "text" to partial, "code" to code))
    }
    private fun finish(type: String, code: String? = null) {
        val id = session ?: return
        session = null; finishing = false
        handler.removeCallbacks(deadline)
        val engine = recognizer; recognizer = null
        try { engine?.cancel() } catch (_: Exception) { }
        try { engine?.destroy() } catch (_: Exception) { }
        // Release microphone before Dart is allowed to send or start another session.
        pending?.success(null); pending = null
        emit(type, code, id)
    }
    fun onBackground() { if (!permissionOutstanding) finish("cancelled") }
    fun dispose() { finish("cancelled"); channel.setMethodCallHandler(null) }
}
