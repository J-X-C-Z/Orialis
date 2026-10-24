package top.jxcz.orialis

internal object ShareText {
    fun combine(subject: String?, plain: String?, htmlPlain: String?, clips: List<String>, links: List<String>): String {
        val parts = linkedSetOf<String>()
        fun add(value: String?) { if (!value.isNullOrBlank()) parts.add(value) }
        add(subject)
        add(plain)
        if (htmlPlain?.trim() != plain?.trim()) add(htmlPlain)
        clips.forEach(::add)
        val observed = MemoryUrls.extract(parts.joinToString("\n")).toMutableSet()
        links.filter { MemoryUrls.extract(it).contains(it) }.forEach { if (observed.add(it)) add(it) }
        return parts.joinToString("\n").also { require(it.length <= 64000) { "分享文字超过 64000 字，请分次分享" } }
    }

    fun mime(value: String?) = value.orEmpty().substringBefore(';').trim().lowercase(java.util.Locale.ROOT)
    fun generic(value: String) = value.isEmpty() || value == "*/*" || value == "application/octet-stream"
    fun attachmentMime(declared: String?, fallback: String?, name: String?): String {
        val actual = mime(declared)
        if (!generic(actual)) return actual
        val hint = mime(fallback)
        return when (name.orEmpty().substringAfterLast('.').lowercase(java.util.Locale.ROOT)) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "heic" -> "image/heic"
            "heif" -> "image/heif"
            "avif" -> "image/avif"
            "pdf" -> "application/pdf"
            "txt" -> "text/plain"
            "html", "htm" -> "text/html"
            else -> hint
        }
    }
}
