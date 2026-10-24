package top.jxcz.orialis

internal object ChatShareRules {
    const val MAX_FILES = 8
    const val MAX_FILE_BYTES = 20L * 1024 * 1024
    const val MAX_TOTAL_BYTES = 48L * 1024 * 1024
    fun supports(mime: String) = mime.startsWith("image/") || mime.startsWith("text/") || mime == "application/pdf"
    fun fileName(name: String?, mime: String): String {
        val extension = when (mime) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "image/heic" -> "heic"
            "image/heif" -> "heif"
            "image/avif" -> "avif"
            "application/pdf" -> "pdf"
            "text/html" -> "html"
            "text/csv" -> "csv"
            else -> if (mime.startsWith("text/")) "txt" else "img"
        }
        val leaf = name.orEmpty().substringAfterLast('/').substringAfterLast('\\')
        val stem = leaf.substringBeforeLast('.', leaf).replace(Regex("[^\\p{L}\\p{N} _()-]"), "_")
            .trim().take(80).ifBlank { "分享文件" }
        return "$stem.$extension"
    }
    fun checkSize(fileBytes: Long, totalBytes: Long) {
        require(fileBytes in 0..MAX_FILE_BYTES) { "单个附件不能超过 20 MiB" }
        require(totalBytes in 0..MAX_TOTAL_BYTES) { "分享附件总计不能超过 48 MiB" }
    }
}
