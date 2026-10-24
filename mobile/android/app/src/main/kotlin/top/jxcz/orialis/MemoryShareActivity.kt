package top.jxcz.orialis

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File
import java.util.concurrent.Executors

class MemoryShareActivity : Activity() {
    companion object { private val worker = Executors.newSingleThreadExecutor() }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        val scope = MemoryStore.scope(this)
        if (scope == null) { complete("请先登录并打开记忆页面，再次分享"); return }
        try {
            val payload = SharedIntentPayload.read(intent)
            require(ShareText.generic(payload.mime) || payload.mime.startsWith("text/") || payload.mime.startsWith("image/")) {
                "记忆支持文字、链接和图片，文件请分享到 Orialis 聊天"
            }
            worker.execute { saveShare(scope, payload) }
        } catch (error: Exception) { complete(error.message ?: "无法读取分享内容") }
    }

    private fun saveShare(scope: String, payload: SharedIntentPayload) {
        var saved = 0
        var lastId: String? = null
        var total = 0L
        var unownedImage: File? = null
        var failure: String? = null
        try {
            val images: List<Uri?> = if (payload.uris.isEmpty()) listOf(null) else payload.uris
            for ((index, uri) in images.withIndex()) {
                ChatShareStore.guard(this, scope)
                val id = MemoryStore.newId()
                if (uri != null) {
                    var name: String? = null
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (n >= 0) name = cursor.getString(n)
                            val s = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (s >= 0 && !cursor.isNull(s)) {
                                val size = cursor.getLong(s)
                                if (size >= 0) ChatShareRules.checkSize(size, total + size)
                            }
                        }
                    }
                    require(ShareText.attachmentMime(contentResolver.getType(uri), payload.mime, name).startsWith("image/")) {
                        "记忆仅支持图片附件，其他文件请分享到 Orialis 聊天"
                    }
                    val staged = File.createTempFile("memory-share-", ".image", cacheDir)
                    try {
                        var size = 0L
                        contentResolver.openInputStream(uri).use { input ->
                            requireNotNull(input) { "无法打开分享图片" }
                            staged.outputStream().use { output ->
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
                        require(size > 0) { "分享图片为空" }
                        total += size
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeFile(staged.path, bounds)
                        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "无法读取分享图片" }
                        var sample = 1
                        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2560) sample *= 2
                        val bitmap = BitmapFactory.decodeFile(staged.path, BitmapFactory.Options().apply { inSampleSize = sample })
                            ?: error("无法读取分享图片")
                        val image = MemoryStore.imageFile(this, scope, id)
                        unownedImage = image
                        try { image.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
                        finally { bitmap.recycle() }
                    } finally { staged.delete() }
                }
                val source = MemoryUrls.sourceLabel(payload.text) ?: "系统分享"
                val label = if (images.size > 1) "$source · 图片 ${index + 1}/${images.size}" else source
                MemoryStore.save(this, scope, id, "", label, payload.text, sharedText = payload.text, imagePath = unownedImage?.absolutePath)
                unownedImage = null
                lastId = id
                saved++
            }
        } catch (error: Exception) {
            unownedImage?.delete()
            failure = error.message ?: "分享保存失败"
        }
        val message = if (failure != null) {
            if (saved > 0) "已保存 $saved 条记忆；其余未保存：$failure" else failure
        } else if (saved > 1) "已存入 $saved 条 Orialis 记忆" else "已存入 Orialis 记忆"
        runOnUiThread {
            lastId?.let { MemoryBridge.notifyChanged(it) }
            complete(message)
        }
    }
    private fun complete(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        finish()
    }
}
