package top.jxcz.orialis

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/** Account-isolated private inbox; no network calls or automatic uploads. */
internal object MemoryStore {
    private fun prefs(context: Context) = context.getSharedPreferences("screen_memory_v1", 0)
    @Synchronized fun scope(context: Context): String? = prefs(context).getString("scope", null)
    @Synchronized fun setScope(context: Context, scope: String?) {
        require(scope == null || scope.matches(Regex("[a-fA-F0-9]{64}"))) { "A SHA-256 account scope is required" }
        check(prefs(context).edit().putString("scope", scope).commit()) { "无法保存记忆账号" }
    }
    private fun directory(context: Context, scope: String): File {
        require(scope.matches(Regex("[a-fA-F0-9]{64}")))
        return File(context.filesDir, "screen_memory_v1/$scope").apply { check(isDirectory || mkdirs()) }
    }
    private fun recordFile(context: Context, scope: String, id: String): File {
        require(id.matches(Regex("[0-9a-f-]{36}"))) { "Invalid memory id" }
        return File(directory(context, scope), "$id.json")
    }
    private fun write(file: File, record: JSONObject) {
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try { output.write(record.toString().toByteArray(Charsets.UTF_8)); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output); throw error }
    }
    fun newId(): String = UUID.randomUUID().toString()
    @Synchronized fun imageFile(context: Context, scope: String, id: String): File {
        recordFile(context, scope, id)
        return File(directory(context, scope), "$id.png")
    }
    @Synchronized fun save(context: Context, scope: String, id: String, sourcePackage: String,
        sourceLabel: String, visibleText: String, sharedText: String? = null, imagePath: String? = null): JSONObject {
        check(scope(context) == scope) { "账号已变更，请重新记录" }
        val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
        val text = visibleText.take(64000)
        val record = JSONObject().put("id", id).put("createdAt", stamp)
            .put("sourcePackage", sourcePackage).put("sourceLabel", sourceLabel)
            .put("visibleText", text).put("urls", JSONArray(MemoryUrls.extract(sharedText.orEmpty() + "\n" + text)))
            .put("title", text.lineSequence().firstOrNull { it.isNotBlank() }?.take(120) ?: "屏幕记忆")
            .put("analysisStatus", "pending")
        sharedText?.let { record.put("sharedText", it.take(64000)) }
        imagePath?.let { require(it == imageFile(context, scope, id).absolutePath); record.put("imagePath", it) }
        write(recordFile(context, scope, id), record)
        return record
    }
    @Synchronized fun read(context: Context, id: String): JSONObject? {
        val scope = scope(context) ?: return null
        val file = recordFile(context, scope, id)
        if (!file.exists() && !File(file.path + ".bak").exists()) return null
        return JSONObject(AtomicFile(file).openRead().bufferedReader().use { it.readText() }).also {
            require(it.optString("id") == id)
            if (it.has("imagePath")) require(it.getString("imagePath") == imageFile(context, scope, id).absolutePath)
        }
    }
    @Synchronized fun list(context: Context): List<JSONObject> {
        val scope = scope(context) ?: return emptyList()
        return directory(context, scope).listFiles().orEmpty().filter { it.extension == "json" }
            .mapNotNull { read(context, it.nameWithoutExtension) }.sortedByDescending { it.optString("createdAt") }
    }
    @Synchronized fun update(context: Context, id: String, fields: Map<*, *>): JSONObject {
        val scope = scope(context) ?: error("请先登录并打开记忆页面")
        val record = read(context, id) ?: error("记忆不存在")
        val allowed = setOf("title", "summary", "analysisStatus", "analysisConversationId", "analysisMessageId", "analysisError", "note", "notes")
        for ((key, value) in fields) {
            require(key is String && key in allowed) { "Unsupported memory field" }
            require(value == null || value is String && value.length <= 64000)
            record.put(key, value ?: JSONObject.NULL)
        }
        write(recordFile(context, scope, id), record)
        return record
    }
    @Synchronized fun delete(context: Context, id: String): Boolean {
        val scope = scope(context) ?: return false
        val record = read(context, id) ?: return false
        AtomicFile(uploadFile(context, scope, id)).delete()
        record.optString("imagePath").takeIf { it.isNotBlank() }?.let { check(!File(it).exists() || File(it).delete()) }
        AtomicFile(recordFile(context, scope, id)).delete()
        return true
    }
    private fun uploadFile(context: Context, scope: String, id: String): File {
        recordFile(context, scope, id)
        val directory = File(context.cacheDir, "screen_memory_upload_v1/$scope")
        check(directory.isDirectory || directory.mkdirs()) { "无法创建上传图片缓存" }
        return File(directory, "$id.jpg")
    }
    @Synchronized fun prepareUpload(context: Context, id: String): String {
        val scope = scope(context) ?: error("请先登录并打开记忆页面")
        val record = read(context, id) ?: error("记忆不存在")
        val source = record.optString("imagePath").takeIf { it.isNotBlank() } ?: error("这条记忆没有图片")
        require(source == imageFile(context, scope, id).absolutePath) { "记忆图片路径无效" }
        val target = AtomicFile(uploadFile(context, scope, id))
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "无法读取记忆图片" }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3200) sample *= 2
        val bitmap = BitmapFactory.decodeFile(source, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: error("无法读取记忆图片")
        var scaled: Bitmap? = null
        try {
            val factor = minOf(1.0, 1600.0 / maxOf(bitmap.width, bitmap.height))
            val prepared = if (factor < 1) Bitmap.createScaledBitmap(bitmap,
                maxOf(1, (bitmap.width * factor).toInt()), maxOf(1, (bitmap.height * factor).toInt()), true) else bitmap
            scaled = prepared
            val encoded = ByteArrayOutputStream()
            check(prepared.compress(Bitmap.CompressFormat.JPEG, 80, encoded)) { "无法压缩上传图片" }
            if (encoded.size() > 900 * 1024) {
                encoded.reset()
                check(prepared.compress(Bitmap.CompressFormat.JPEG, 55, encoded)) { "无法压缩上传图片" }
            }
            check(encoded.size() <= 900 * 1024) { "压缩图片仍超过 900 KiB，请分享链接或裁剪后重试；原图已保留" }
            check(scope(context) == scope) { "账号已变更，请重试" }
            val stream = target.startWrite()
            try { encoded.writeTo(stream); target.finishWrite(stream) }
            catch (error: Exception) { target.failWrite(stream); throw error }
            check(scope(context) == scope) { "账号已变更，请重试" }
            return target.baseFile.absolutePath
        } catch (error: Exception) { target.delete(); throw error }
        finally { if (scaled !== bitmap) scaled?.recycle(); bitmap.recycle() }
    }
    fun asMap(record: JSONObject): Map<String, Any?> = record.keys().asSequence().associateWith { key ->
        when (val value = record.get(key)) {
            JSONObject.NULL -> null
            is JSONArray -> (0 until value.length()).map { value.get(it) }
            else -> value
        }
    }
}
