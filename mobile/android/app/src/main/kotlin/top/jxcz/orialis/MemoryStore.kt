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
import java.security.MessageDigest
import android.util.Base64
import java.util.UUID

/** Account-isolated inbox for screens explicitly captured or shared by the user. */
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
        require(id.matches(Regex("[0-9a-fA-F-]{36}"))) { "Invalid memory id" }
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
    private fun compressedImageFile(context: Context, scope: String, id: String): File {
        recordFile(context, scope, id)
        return File(directory(context, scope), "$id.jpg")
    }
    private fun validImagePath(context: Context, scope: String, id: String, path: String): Boolean =
        path == imageFile(context, scope, id).absolutePath ||
            path == compressedImageFile(context, scope, id).absolutePath

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
        imagePath?.let {
            require(it == imageFile(context, scope, id).absolutePath)
            record.put("imagePath", it)
        }
        write(recordFile(context, scope, id), record)
        MemoryAnalysisJobService.schedule(context, id)
        return record
    }
    @Synchronized fun read(context: Context, id: String): JSONObject? {
        val scope = scope(context) ?: return null
        val file = recordFile(context, scope, id)
        if (!file.exists() && !File(file.path + ".bak").exists()) return null
        return JSONObject(AtomicFile(file).openRead().bufferedReader().use { it.readText() }).also {
            require(it.optString("id") == id)
            if (it.has("imagePath")) require(validImagePath(context, scope, id, it.getString("imagePath")))
        }
    }
    @Synchronized fun list(context: Context): List<JSONObject> {
        val scope = scope(context) ?: return emptyList()
        return directory(context, scope).listFiles().orEmpty().filter { it.extension == "json" }
            .mapNotNull { read(context, it.nameWithoutExtension) }.sortedByDescending { it.optString("createdAt") }
    }
    @Synchronized fun update(context: Context, id: String, fields: Map<*, *>, expectedAnalysisRequestId: String? = null): JSONObject {
        val scope = scope(context) ?: error("请先登录并打开记忆页面")
        val record = read(context, id) ?: error("记忆不存在")
        val currentAnalysisId = if (record.isNull("analysisRequestId")) "" else record.optString("analysisRequestId")
        check(expectedAnalysisRequestId == null || currentAnalysisId == expectedAnalysisRequestId) { "已有更新的记忆理解任务" }
        val allowed = setOf("title", "summary", "analysisStatus", "analysisConversationId", "analysisMessageId", "analysisError", "analysisRequestId", "category", "sourceUrl", "videoStatus", "videoSummary", "videoError", "note", "notes", "cloudVersion", "cloudRecordHash", "cloudImageSha256", "cloudDeletedAt", "cloudSyncError")
        for ((key, value) in fields) {
            require(key is String && key in allowed) { "Unsupported memory field" }
            require(value == null || value is String && value.length <= 64000)
            record.put(key, value ?: JSONObject.NULL)
        }
        val dirty = fields.keys.any { it is String && !it.startsWith("cloud") } || fields["cloudDeletedAt"] == "pending"
        if (dirty) record.put("cloudSyncError", "pending")
        write(recordFile(context, scope, id), record)
        if (dirty) MemoryAnalysisJobService.schedule(context, id)
        if (record.optString("analysisStatus") in setOf("completed", "failed")) {
            AtomicFile(uploadFile(context, scope, id)).delete()
        }
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
        require(validImagePath(context, scope, id, source)) { "记忆图片路径无效" }
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
    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().sorted().joinToString(prefix = "{", postfix = "}") {
            JSONObject.quote(it) + ":" + canonical(value.get(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }
    @Synchronized fun importCloud(context: Context, incoming: Map<*, *>, expected: Map<*, *>?): JSONObject {
        val scope = scope(context) ?: error("请先登录")
        val id = incoming["id"] as? String ?: error("缺少记忆编号")
        val current = read(context, id)
        check(if (expected == null) current == null else current != null &&
            expected.all { (key, value) ->
                fun normalized(v: Any?): String {
                    if (v == null || v == JSONObject.NULL || v == "") return "null"
                    val item = if (key == "createdAt" && v is String) v.replace(Regex("(\\.\\d*?[1-9])0+Z$"), "$1Z").replace(Regex("\\.0+Z$"), "Z") else v
                    return canonical(item)
                }
                normalized(current.opt(key as String)) == normalized(JSONObject.wrap(value))
            }) { "本地记忆已更新，请刷新后重试" }
        require(!incoming.containsKey("imagePath")) { "云端不能指定本地图片路径" }
        val allowed = setOf("id", "createdAt", "updatedAt", "version", "deletedAt", "imageSha256",
            "sourcePackage", "sourceLabel", "visibleText", "sharedText", "urls", "title", "summary",
            "note", "notes", "analysisStatus", "analysisError", "analysisRequestId", "analysisConversationId",
            "analysisMessageId", "category", "sourceUrl", "videoStatus", "videoSummary", "videoError",
            "cloudVersion", "cloudRecordHash", "cloudImageSha256", "cloudDeletedAt", "cloudSyncError")
        require(incoming.keys.all { it is String && it in allowed }) { "云端记忆字段无效" }
        val record = if (current != null) JSONObject(current.toString()) else JSONObject()
        incoming.forEach { (key, value) -> record.put(key as String, value ?: JSONObject.NULL) }
        require(record.toString().toByteArray().size <= 512 * 1024) { "云端记忆过大" }
        current?.optString("imagePath")?.takeIf { it.isNotBlank() }?.let { record.put("imagePath", it) }
        write(recordFile(context, scope, id), record)
        return record
    }
    @Synchronized fun storeCloudImage(context: Context, id: String, value: Any?, mime: String, sha: String): String {
        val scope = scope(context) ?: error("请先登录")
        val record = read(context, id) ?: error("记忆不存在")
        require(mime in setOf("image/png", "image/jpeg") && sha.matches(Regex("[a-fA-F0-9]{64}")))
        val expectedHash = record.optString("cloudImageSha256").takeIf { !record.isNull("cloudImageSha256") && it.isNotBlank() }
        check(expectedHash == null || expectedHash.equals(sha, ignoreCase = true)) { "云端图片版本已更新，请重试" }
        val bytes = when (value) {
            is ByteArray -> value
            is String -> { require(value.length <= 44 * 1024 * 1024); Base64.decode(value, Base64.DEFAULT) }
            else -> error("图片数据无效")
        }
        require(bytes.isNotEmpty() && bytes.size <= 32 * 1024 * 1024)
        val actual = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        require(actual.equals(sha, ignoreCase = true)) { "图片校验失败" }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0)
        val existing = record.optString("imagePath").takeIf { it.isNotBlank() }
        // Cloud images are compressed upload copies; a local original is intentionally different.
        if (existing != null && File(existing).exists()) return existing
        val target = if (mime == "image/png") imageFile(context, scope, id) else compressedImageFile(context, scope, id)
        val atomic = AtomicFile(target)
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
        record.put("imagePath", target.absolutePath).put("cloudImageSha256", actual)
        write(recordFile(context, scope, id), record)
        return target.absolutePath
    }
    fun asMap(record: JSONObject): Map<String, Any?> = record.keys().asSequence().associateWith { key ->
        when (val value = record.get(key)) {
            JSONObject.NULL -> null
            is JSONArray -> (0 until value.length()).map { value.get(it) }
            else -> value
        }
    }
}
