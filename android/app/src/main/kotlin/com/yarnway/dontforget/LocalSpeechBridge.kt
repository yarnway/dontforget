package com.yarnway.dontforget

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.Executors

/** Recognizes finalized recordings with the on-device service.
 * Unsupported languages never silently switch to the system cloud recognizer.
 */
class LocalSpeechBridge(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var epoch = 0
    private var pending: MethodChannel.Result? = null
    private var recognizer: SpeechRecognizer? = null
    private var descriptor: ParcelFileDescriptor? = null
    private var audio: File? = null
    private var timeout: Runnable? = null
    private var disposed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cancel" -> { finish(null, "speech_cancelled"); result.success(null) }
            "transcribe" -> {
                if (disposed) { result.error("speech_unavailable", null, null); return }
                if (pending != null) { result.error("speech_busy", null, null); return }
                if (Build.VERSION.SDK_INT < 33 ||
                    !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
                    result.error("speech_unavailable", null, null); return
                }
                val path = call.argument<String>("path")
                val locale = call.argument<String>("locale")
                if (path.isNullOrBlank() || locale !in setOf("zh-CN", "en-US", "ja-JP")) {
                    result.error("speech_invalid_audio", null, null); return
                }
                val source = File(path)
                // The bridge only accepts this application's own finalized audio.
                val roots = listOfNotNull(context.cacheDir, context.filesDir,
                    File(context.dataDir, "app_flutter"),
                    context.getExternalFilesDir(null)).map { it.canonicalFile }
                val canonical = try { source.canonicalFile } catch (_: Exception) { null }
                if (canonical == null || !canonical.isFile || canonical.length() !in 1..20_000_000L ||
                    roots.none { canonical.path.startsWith(it.path + File.separator) }) {
                    result.error("speech_invalid_audio", null, null); return
                }
                pending = result
                val token = ++epoch
                timeout = Runnable { if (token == epoch) finish(null, "speech_timeout") }
                    .also { main.postDelayed(it, 45_000) }
                worker.execute {
                    var decoded: File? = null
                    try {
                        decoded = decode(canonical, token)
                        val ready = decoded
                        main.post {
                            if (token != epoch || disposed) ready.delete()
                            else { audio = ready; recognize(ready, locale!!, token) }
                        }
                    } catch (_: Exception) {
                        decoded?.delete()
                        main.post { if (token == epoch) finish(null, "speech_invalid_audio") }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    @android.annotation.TargetApi(33)
    private fun recognize(file: File, locale: String, token: Int) {
        try {
            descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, descriptor)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
            intent.putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            val speech = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            recognizer = speech
            fun active() = token == epoch && recognizer === speech
            val segments = mutableListOf<String>()
            speech.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onError(error: Int) {
                    if (!active()) return
                    finish(null, when (error) {
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "speech_permission_denied"
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "speech_language_unavailable"
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech_empty"
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "speech_network"
                        SpeechRecognizer.ERROR_CLIENT -> "speech_client"
                        SpeechRecognizer.ERROR_AUDIO -> "speech_audio"
                        SpeechRecognizer.ERROR_SERVER -> "speech_server"
                        else -> "speech_failed"
                    })
                }
                override fun onResults(results: Bundle?) {
                    if (active()) finish(text(results), null)
                }
                override fun onSegmentResults(segmentResults: Bundle) {
                    if (!active()) return
                    text(segmentResults)?.let { segments.add(it) }
                    if (segments.sumOf { it.length } > 32000) finish(null, "speech_invalid_audio")
                }
                override fun onEndOfSegmentedSession() {
                    if (active()) finish(segments.joinToString(" "), null)
                }
            })
            speech.checkRecognitionSupport(intent, context.mainExecutor, object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    if (!active()) return
                    try { speech.startListening(intent) }
                    catch (_: SecurityException) { finish(null, "speech_permission_denied") }
                    catch (_: Exception) { finish(null, "speech_failed") }
                }
                override fun onError(error: Int) {
                    if (!active()) return
                    finish(null, when (error) {
                        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
                        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "speech_language_unavailable"
                        else -> "speech_unavailable"
                    })
                }
            })
        } catch (_: SecurityException) {
            finish(null, "speech_permission_denied")
        } catch (_: Exception) {
            finish(null, "speech_failed")
        }
    }

    private fun text(bundle: Bundle?): String? =
        bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim()

    private fun finish(value: String?, error: String?) {
        val result = pending
        pending = null
        epoch++
        timeout?.let { main.removeCallbacks(it) }; timeout = null
        try { recognizer?.cancel(); recognizer?.destroy() } catch (_: Exception) {}
        recognizer = null
        try { descriptor?.close() } catch (_: Exception) {}
        descriptor = null
        audio?.delete(); audio = null
        if (result != null) {
            if (error != null) result.error(error, null, null)
            else if (value.isNullOrBlank() || value.length > 32000) result.error("speech_empty", null, null)
            else result.success(value)
        }
    }

    fun dispose() {
        disposed = true
        finish(null, "speech_cancelled")
        worker.shutdownNow()
    }

    /** Decode AAC/M4A to bounded mono 16k PCM. Never modify the source recording. */
    private fun decode(source: File, token: Int): File {
        val output = File.createTempFile("speech-", ".pcm", context.cacheDir)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(source.path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("No audio")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = decoder
            decoder.configure(format, null, null, 0); decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var phase = 0L
            var bytes = 0L
            var eos = false
            var done = false
            val info = MediaCodec.BufferInfo()
            BufferedOutputStream(output.outputStream()).use { out ->
                while (!done) {
                    check(token == epoch && !Thread.currentThread().isInterrupted)
                    if (!eos) {
                        val index = decoder.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = decoder.getInputBuffer(index)!!
                            val size = extractor.readSampleData(buffer, 0)
                            eos = size < 0
                            decoder.queueInputBuffer(index, 0, maxOf(size, 0),
                                if (eos) 0 else extractor.sampleTime,
                                if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                            if (!eos) extractor.advance()
                        }
                    }
                    val index = decoder.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val decoded = decoder.outputFormat
                        rate = decoded.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = decoded.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        check(!decoded.containsKey(MediaFormat.KEY_PCM_ENCODING) ||
                            decoded.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_16BIT)
                    } else if (index >= 0) {
                        try {
                            check(rate in 8000..192000 && channels in 1..8)
                            val buffer = decoder.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
                            buffer.position(info.offset); buffer.limit(info.offset + info.size)
                            while (buffer.remaining() >= channels * 2) {
                                var sample = 0
                                repeat(channels) { sample += buffer.short.toInt() }
                                sample /= channels
                                phase += 16000
                                while (phase >= rate) {
                                    out.write(sample and 255); out.write((sample shr 8) and 255)
                                    phase -= rate; bytes += 2
                                    check(bytes <= 19_200_000) // ten minutes
                                }
                            }
                            done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally { decoder.releaseOutputBuffer(index, false) }
                    }
                }
            }
            check(bytes > 0)
            return output
        } catch (error: Exception) {
            output.delete(); throw error
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            codec?.release(); extractor.release()
        }
    }
}
