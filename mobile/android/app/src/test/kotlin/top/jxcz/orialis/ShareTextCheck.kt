package top.jxcz.orialis

fun main() {
    val link = "http://xhslink.com/a/example?xsec_token=a%2Bb%3D&xsec_source=app_share#note"
    val note = "12 小红书笔记推荐 $link 复制后打开小红书！"
    check(ShareText.combine("笔记标题", note, null, listOf(note), listOf(link)) == "笔记标题\n$note")
    check(ShareText.combine(null, "", "一段网页内容", emptyList(), listOf(link)) == "一段网页内容\n$link")
    check(ShareText.combine(null, "原始文案", "额外网页正文", emptyList(), listOf(link)) == "原始文案\n额外网页正文\n$link")
    check(ShareText.combine(null, null, null, listOf(note, note), emptyList()) == note)
    check(ShareText.combine(null, null, null, emptyList(), listOf("file:///private", "javascript:alert(1)")) == "")
    check(ShareText.combine("  原文  ", "正文\n换行", null, emptyList(), emptyList()) == "  原文  \n正文\n换行")
    check(runCatching { ShareText.combine(null, "x".repeat(64001), null, emptyList(), emptyList()) }.isFailure)
    check(ShareText.combine(null, "x".repeat(64000), null, emptyList(), emptyList()).length == 64000)
    check(ShareText.mime(" Text/HTML; charset=UTF-8 ") == "text/html")
    check(ShareText.generic("") && ShareText.generic("*/*") && ShareText.generic("application/octet-stream"))
    check(ShareText.attachmentMime("image/png", "image/jpeg", "image.jpg") == "image/png")
    check(ShareText.attachmentMime("application/octet-stream", "*/*", "小红书图片.JPEG") == "image/jpeg")
    check(ShareText.attachmentMime(null, "image/*", "cover.avif") == "image/avif")
    check(ShareText.attachmentMime(null, "application/pdf", "未知文件") == "application/pdf")
    check(ShareText.attachmentMime("video/mp4", "image/png", "not-a-photo.png") == "video/mp4")
    check(ShareText.attachmentMime(null, "*/*", "unknown.bin") == "*/*")
    check(ShareText.attachmentMime(null, "text/plain", "cover.png") == "image/png")
    check(ShareText.combine(null, note, note, listOf(note), emptyList()) == note)
    println("ShareText: 18 checks passed")
}
