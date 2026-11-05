package com.yarnway.dontforget

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Private handoff journal. Never acknowledges a share before Dart commits it. */
internal class SharedTextBridge(context: Context) {
    private val preferences = context.getSharedPreferences("shared_text_handoff", Context.MODE_PRIVATE)
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
        if (intent.type !in setOf("text/plain", "text/html") || intent.hasExtra(Intent.EXTRA_STREAM)) {
            throw IllegalArgumentException("unsupported")
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: throw IllegalArgumentException("unsupported")
        if (text.isBlank() || text.length > 16000 || controls.containsMatchIn(text)) {
            throw IllegalArgumentException("text_limit")
        }
        // The reuse ID comes only from this Activity's saved instance state,
        // never from an externally supplied Intent extra or content hash.
        val id = restoredId?.takeIf { identity.matches(it) } ?: UUID.randomUUID().toString()
        val queued = load().toMutableList()
        if (queued.none { it["id"] == id }) {
            if (queued.size >= 16) throw IllegalArgumentException("full")
            queued.add(mapOf("id" to id, "text" to text, "created_at" to System.currentTimeMillis(),
                "dataset_epoch" to datasetEpoch))
            persist(queued)
        }
        clearIntent(intent)
        return id
    }

    fun pending(): List<Map<String, Any>> {
        val epoch = checkNotNull(datasetEpoch)
        return load().filter { it["dataset_epoch"] == epoch }.map {
            mapOf("id" to it["id"]!!, "text" to it["text"]!!, "created_at" to it["created_at"]!!)
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
            check(item.length() == 4 && item.has("dataset_epoch") && item.opt("id") is String &&
                item.opt("text") is String && (item.opt("created_at") is Long || item.opt("created_at") is Int)) { "journal" }
            val id = item.getString("id")
            val text = item.getString("text")
            val created = item.getLong("created_at")
            val epoch = if (item.isNull("dataset_epoch")) null else item.getString("dataset_epoch")
            check(epoch == null || (epoch.isNotBlank() && epoch.length <= 256 && !controls.containsMatchIn(epoch))) { "journal" }
            check(identity.matches(id) && seen.add(id) && text.isNotBlank() &&
                text.length <= 16000 && !controls.containsMatchIn(text) && created > 0) { "journal" }
            mapOf("id" to id, "text" to text, "created_at" to created, "dataset_epoch" to epoch)
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
        fun clearIntent(intent: Intent) {
            if (intent.action != Intent.ACTION_SEND) return
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_SUBJECT)
            intent.clipData = null
            intent.action = Intent.ACTION_MAIN
        }
    }
}
