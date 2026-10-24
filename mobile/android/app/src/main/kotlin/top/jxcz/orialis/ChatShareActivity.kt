package top.jxcz.orialis

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class ChatShareActivity : Activity() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        val scope = MemoryStore.scope(this)
        if (scope == null) { fail("请先登录 Orialis，再次分享"); return }
        try {
            val payload = SharedIntentPayload.read(intent)
            worker.execute { copyShare(scope, payload.text, payload.mime, payload.uris) }
        } catch (error: Exception) { fail(error.message ?: "无法读取分享内容") }
    }

    private fun copyShare(scope: String, text: String, fallbackMime: String, uris: List<Uri>) {
        val id = ChatShareStore.newId()
        var dir: File? = null
        try {
            ChatShareStore.guard(this, scope)
            dir = ChatShareStore.itemDirectory(this, scope, id).apply { check(mkdirs()) }
            val files = JSONArray()
            var total = 0L
            uris.forEachIndexed { index, uri ->
                ChatShareStore.guard(this, scope)
                var displayName: String? = null
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameColumn >= 0) displayName = cursor.getString(nameColumn)
                        val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                            val declaredSize = cursor.getLong(sizeColumn)
                            if (declaredSize >= 0) ChatShareRules.checkSize(declaredSize, total + declaredSize)
                        }
                    }
                }
                val mime = ShareText.attachmentMime(contentResolver.getType(uri), fallbackMime, displayName)
                require(ChatShareRules.supports(mime)) { "不支持的附件格式" }
                require(uris.size <= 1 || mime.startsWith("image/")) { "多附件分享仅支持图片" }
                val name = ChatShareRules.fileName(displayName, mime)
                val target = File(dir, "${index}_$name")
                var size = 0L
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "无法打开分享附件" }
                    target.outputStream().use { output ->
                        val buffer = ByteArray(32 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            size += count
                            ChatShareRules.checkSize(size, total + size)
                            ChatShareStore.guard(this, scope)
                            output.write(buffer, 0, count)
                        }
                    }
                }
                require(size > 0) { "分享附件为空，请选择有效文件" }
                total += size
                files.put(JSONObject().put("path", target.absolutePath).put("name", name).put("mimeType", mime).put("size", size))
            }
            ChatShareStore.save(this, scope, id, text, files)
            runOnUiThread {
                try {
                    ChatShareStore.guard(this, scope)
                    startActivity(Intent(this, MainActivity::class.java).putExtra(ChatShareBridge.ID_EXTRA, id)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    finish()
                } catch (error: Exception) { dir?.deleteRecursively(); fail(error.message ?: "打开聊天失败") }
            }
        } catch (error: Exception) {
            dir?.deleteRecursively()
            runOnUiThread { fail(error.message ?: "分享保存失败") }
        }
    }
    private fun fail(message: String) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); finish() }
}
