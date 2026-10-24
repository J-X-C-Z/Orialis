package top.jxcz.orialis

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

internal object ChatShareStore {
    private fun directory(context: Context, scope: String): File {
        require(scope.matches(Regex("[a-fA-F0-9]{64}")))
        return File(context.filesDir, "chat_share_v1/$scope").apply { check(isDirectory || mkdirs()) }
    }
    fun itemDirectory(context: Context, scope: String, id: String): File {
        require(id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")))
        return File(directory(context, scope), id)
    }
    fun newId() = UUID.randomUUID().toString()
    fun guard(context: Context, scope: String) = synchronized(MemoryStore) {
        check(MemoryStore.scope(context) == scope) { "账号已变更，请重新分享" }
    }
    fun save(context: Context, scope: String, id: String, text: String, files: JSONArray) = synchronized(MemoryStore) {
        guard(context, scope)
        val file = AtomicFile(File(itemDirectory(context, scope, id), "share.json"))
        val payload = JSONObject().put("id", id).put("text", text).put("files", files).put("createdAt", System.currentTimeMillis())
        val stream = file.startWrite()
        try {
            stream.write(payload.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Exception) { file.failWrite(stream); throw error }
        guard(context, scope)
    }
    fun read(context: Context, id: String): Map<String, Any?>? = synchronized(MemoryStore) {
        val scope = MemoryStore.scope(context) ?: return@synchronized null
        val dir = itemDirectory(context, scope, id)
        val file = AtomicFile(File(dir, "share.json"))
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return@synchronized null
        val record = JSONObject(file.openRead().bufferedReader().use { it.readText() })
        require(record.getString("id") == id)
        val source = record.getJSONArray("files")
        require(source.length() <= ChatShareRules.MAX_FILES)
        var total = 0L
        val files = (0 until source.length()).map { index ->
            val item = source.getJSONObject(index)
            val name = item.getString("name")
            val mime = item.getString("mimeType")
            require(ChatShareRules.supports(mime) && ChatShareRules.fileName(name, mime) == name)
            val expected = File(dir, "${index}_$name")
            require(item.getString("path") == expected.absolutePath && expected.isFile)
            val size = expected.length()
            require(item.getLong("size") == size)
            total += size
            ChatShareRules.checkSize(size, total)
            mapOf("path" to expected.absolutePath, "name" to name, "mimeType" to mime, "size" to size)
        }
        mapOf("id" to id, "text" to record.getString("text"), "files" to files)
    }
    fun pending(context: Context, preferredId: String?): Map<String, Any?>? = synchronized(MemoryStore) {
        val scope = MemoryStore.scope(context) ?: return@synchronized null
        if (preferredId != null) read(context, preferredId)?.let { return@synchronized it }
        directory(context, scope).listFiles().orEmpty().filter { it.isDirectory }
            .sortedBy { File(it, "share.json").lastModified() }
            .firstNotNullOfOrNull { read(context, it.name) }
    }
    fun complete(context: Context, id: String) = synchronized(MemoryStore) {
        val scope = MemoryStore.scope(context) ?: return@synchronized
        val dir = itemDirectory(context, scope, id)
        check(!dir.exists() || dir.deleteRecursively()) { "无法清理分享附件" }
    }
}
