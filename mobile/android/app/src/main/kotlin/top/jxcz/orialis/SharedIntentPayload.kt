package top.jxcz.orialis

import android.content.Intent
import android.net.Uri
import android.text.Html
import android.text.style.URLSpan

internal data class SharedIntentPayload(val text: String, val mime: String, val uris: List<Uri>) {
    companion object {
        @Suppress("DEPRECATION")
        fun read(intent: Intent): SharedIntentPayload {
            require(intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) { "不支持的分享方式" }
            val mime = ShareText.mime(intent.type)
            require(ShareText.generic(mime) || ChatShareRules.supports(mime)) { "只支持文字、链接、图片和 PDF 分享" }
            val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()
                ?: intent.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString()
            val plain = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            val rawHtml = intent.getStringExtra(Intent.EXTRA_HTML_TEXT)
            require(rawHtml == null || rawHtml.length <= 64000) { "分享网页内容过长，请分享链接" }
            val html = rawHtml?.let { Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY) }
            val links = mutableListOf<String>()
            html?.getSpans(0, html.length, URLSpan::class.java)?.forEach { links.add(it.url) }
            val clips = mutableListOf<String>()
            val clipUris = mutableListOf<Uri>()
            val clip = intent.clipData
            require((clip?.itemCount ?: 0) <= 32) { "分享内容过多，请分次分享" }
            for (index in 0 until (clip?.itemCount ?: 0)) {
                val item = clip!!.getItemAt(index)
                item.text?.toString()?.let { clips.add(it) }
                item.htmlText?.let {
                    require(it.length <= 64000) { "分享网页内容过长，请分享链接" }
                    val body = Html.fromHtml(it, Html.FROM_HTML_MODE_LEGACY)
                    clips.add(body.toString())
                    body.getSpans(0, body.length, URLSpan::class.java).forEach { span -> links.add(span.url) }
                }
                item.uri?.let { clipUris.add(it) }
                item.intent?.data?.takeIf { it.scheme == "http" || it.scheme == "https" }?.let { links.add(it.toString()) }
            }
            val rawStream = intent.extras?.get(Intent.EXTRA_STREAM)
            val streams = when (rawStream) {
                null -> emptyList()
                is Uri -> listOf(rawStream)
                is ArrayList<*> -> rawStream.map { require(it is Uri) { "分享附件地址无效" }; it }
                else -> error("分享附件地址无效")
            }
            // EXTRA_STREAM owns attachments; ClipData may only be a preview thumbnail.
            val provided = if (streams.isNotEmpty()) streams else clipUris
            clipUris.filter { it.scheme == "http" || it.scheme == "https" }.forEach { links.add(it.toString()) }
            val uris = mutableListOf<Uri>()
            for (uri in provided) {
                when (uri.scheme) {
                    "content" -> uris.add(uri)
                    "http", "https" -> links.add(uri.toString())
                    else -> error("只支持系统分享提供的附件")
                }
            }
            intent.data?.let {
                if (it.scheme == "http" || it.scheme == "https") links.add(it.toString())
                else if (provided.isEmpty() && it.scheme == "content") uris.add(it)
            }
            val text = ShareText.combine(subject, plain, html?.toString(), clips, links)
            // A text share's ClipData content URI can be an ungranted preview thumbnail.
            val attachments = uris.distinct().filter {
                streams.isNotEmpty() || !mime.startsWith("text/") || text.isBlank() || it == intent.data
            }
            require(attachments.size <= ChatShareRules.MAX_FILES) { "一次最多分享 8 张图片" }
            require(text.isNotBlank() || attachments.isNotEmpty()) { "分享中没有文字、链接或附件" }
            return SharedIntentPayload(text, mime, attachments)
        }
    }
}
