package com.yarnway.dontforget

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/** Private handoff journal. Never acknowledges a share before Dart commits it. */
internal class SharedTextBridge(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("shared_text_handoff", Context.MODE_PRIVATE)
    private val handoffRoot = File(appContext.filesDir, "shared_handoff")
    private val identity = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private val controls = Regex("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]")
    private var datasetEpoch: String? = null

    fun initialize(epoch: String) {
        require(epoch.isNotBlank() && epoch.length <= 256 && !controls.containsMatchIn(epoch))
        val records = load()
        // Unbound events arrived before Dart was ready. Already-bound events
        // from a replaced database are never imported into the restored data.
        val next = records.filter { it["dataset_epoch"] == null || it["dataset_epoch"] == epoch }
            .map { it + ("dataset_epoch" to epoch) }
        if (records.any { it["dataset_epoch"] != epoch }) persist(next)
        datasetEpoch = epoch
    }

    fun receive(intent: Intent?, restoredId: String? = null): String? {
        if (intent?.action != Intent.ACTION_SEND ||
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        // The reuse ID comes only from this Activity's saved instance state,
        // never from an externally supplied Intent extra or content hash.
        val id = restoredId?.takeIf { identity.matches(it) } ?: UUID.randomUUID().toString()
        val queued = load().toMutableList()
        if (queued.none { it["id"] == id }) {
            if (queued.size >= 16) throw IllegalArgumentException("full")
            val hasStream = intent.hasExtra(Intent.EXTRA_STREAM)
            val text: String
            var attachmentPath: String? = null
            var attachmentName: String? = null
            if (hasStream) {
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                    ?: throw IllegalArgumentException("unsupported")
                if (stream.scheme != "content") {
                    throw IllegalArgumentException("unsupported")
                }
                text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""
                if (text.length > 16000 || controls.containsMatchIn(text)) {
                    throw IllegalArgumentException("text_limit")
                }
                val staged = stageAttachment(id, stream, intent.type)
                attachmentPath = staged.first
                attachmentName = staged.second
            } else {
                if (intent.type !in setOf("text/plain", "text/html")) {
                    throw IllegalArgumentException("unsupported")
                }
                text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    ?: throw IllegalArgumentException("unsupported")
                if (text.isBlank() || text.length > 16000 || controls.containsMatchIn(text)) {
                    throw IllegalArgumentException("text_limit")
                }
            }
            val item = mutableMapOf<String, Any?>(
                "id" to id,
                "text" to text,
                "created_at" to System.currentTimeMillis(),
                "dataset_epoch" to datasetEpoch,
            )
            if (attachmentPath != null) {
                item["attachment_path"] = attachmentPath
                item["attachment_name"] = attachmentName
            }
            queued.add(item)
            persist(queued)
        }
        clearIntent(intent)
        return id
    }

    private fun stageAttachment(id: String, uri: Uri, fallbackMime: String?): Pair<String, String> {
        val resolver = appContext.contentResolver
        var displayName: String? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0 && !cursor.isNull(index)) {
                        displayName = cursor.getString(index)
                    }
                }
            }
        } catch (_: Exception) {}
        val mime = resolver.getType(uri) ?: fallbackMime
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)?.takeIf { it.isNotBlank() }
        val rawName = (displayName?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment ?: "shared")
            .replace(Regex("[/\\\\\\x00-\\x1f\\x7f]+"), "_")
            .trim()
            .trim('.')
            .ifEmpty { "shared" }
        val safeName = (if ('.' in rawName || ext == null) rawName else "$rawName.$ext").take(120)
        val dir = File(handoffRoot, id)
        if (dir.exists()) dir.deleteRecursively()
        check(dir.mkdirs()) { "handoff_dir" }
        val target = File(dir, safeName)
        try {
            val input = resolver.openInputStream(uri) ?: throw IllegalArgumentException("unsupported")
            var total = 0L
            input.use { stream ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read
                        if (total > MAX_ATTACHMENT_BYTES) {
                            throw IllegalArgumentException("attachment_limit")
                        }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            if (total <= 0L) throw IllegalArgumentException("attachment_limit")
            return target.absolutePath to safeName
        } catch (error: Exception) {
            dir.deleteRecursively()
            throw error
        }
    }

    fun pending(): List<Map<String, Any>> {
        val epoch = checkNotNull(datasetEpoch)
        return load().filter { it["dataset_epoch"] == epoch }.map { record ->
            val item = mutableMapOf<String, Any>(
                "id" to record["id"]!!,
                "text" to record["text"]!!,
                "created_at" to record["created_at"]!!,
            )
            record["attachment_path"]?.let { item["attachment_path"] = it }
            record["attachment_name"]?.let { item["attachment_name"] = it }
            item
        }
    }

    private fun load(): List<Map<String, Any?>> {
        val raw = preferences.getString("pending", null) ?: return emptyList()
        check(raw.length <= 1048576) { "journal" }
        val array = JSONArray(raw)
        check(array.length() <= 16) { "journal" }
        val seen = mutableSetOf<String>()
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            check(item.length() in 4..6 && item.has("dataset_epoch") && item.opt("id") is String &&
                item.opt("text") is String && (item.opt("created_at") is Long || item.opt("created_at") is Int)) { "journal" }
            val id = item.getString("id")
            val text = item.getString("text")
            val created = item.getLong("created_at")
            val epoch = if (item.isNull("dataset_epoch")) null else item.getString("dataset_epoch")
            val attachmentPath = if (!item.has("attachment_path") || item.isNull("attachment_path")) null else item.getString("attachment_path")
            val attachmentName = if (!item.has("attachment_name") || item.isNull("attachment_name")) null else item.getString("attachment_name")
            check(epoch == null || (epoch.isNotBlank() && epoch.length <= 256 && !controls.containsMatchIn(epoch))) { "journal" }
            check(identity.matches(id) && seen.add(id) && (attachmentPath != null || text.isNotBlank()) &&
                text.length <= 16000 && !controls.containsMatchIn(text) && created > 0) { "journal" }
            if (attachmentPath != null) {
                check(attachmentPath.isNotBlank() && attachmentPath.length <= 4096 && !controls.containsMatchIn(attachmentPath)) { "journal" }
                check(attachmentName == null || (attachmentName.isNotBlank() && attachmentName.length <= 255 && !controls.containsMatchIn(attachmentName))) { "journal" }
            } else {
                check(attachmentName == null) { "journal" }
            }
            val result = mutableMapOf<String, Any?>(
                "id" to id,
                "text" to text,
                "created_at" to created,
                "dataset_epoch" to epoch,
            )
            if (attachmentPath != null) {
                result["attachment_path"] = attachmentPath
                if (attachmentName != null) result["attachment_name"] = attachmentName
            }
            result
        }
    }

    fun acknowledge(id: String) {
        require(identity.matches(id))
        val queued = load()
        val next = queued.filter { it["id"] != id }
        if (next.size != queued.size) persist(next)
    }

    fun reset() {
        datasetEpoch = null
        // Keep entries if recovery is cancelled. initialize() filters bound
        // entries only after the committed data-set identity actually changes.
    }

    private fun persist(items: List<Map<String, Any?>>) {
        val array = JSONArray()
        items.forEach { item ->
            val objectValue = JSONObject()
            item.forEach { (name, value) -> objectValue.put(name, value ?: JSONObject.NULL) }
            array.put(objectValue)
        }
        val raw = array.toString()
        check(raw.length <= 1048576) { "journal" }
        check(preferences.edit().putString("pending", raw).commit()) { "journal" }
    }

    companion object {
        private const val MAX_ATTACHMENT_BYTES = 32L * 1024L * 1024L

        fun clearIntent(intent: Intent) {
            if (intent.action != Intent.ACTION_SEND) return
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_SUBJECT)
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.clipData = null
            intent.action = Intent.ACTION_MAIN
        }
    }
}
