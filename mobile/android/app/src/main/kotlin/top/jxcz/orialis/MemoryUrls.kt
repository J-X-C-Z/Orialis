package top.jxcz.orialis

import java.net.URI
import java.util.Locale

internal object MemoryUrls {
    // Keep exact links and canonical links from observed BV identifiers; never infer a link from a title.
    fun extract(text: String): List<String> {
        val exact = Regex("https?://[^\\s<>\\\"'，。；！？、（）【】《》「」『』“”‘’]+", RegexOption.IGNORE_CASE)
            .findAll(text).filter { it.value.length <= 8192 }
            .map { trimBoundary(it.value, text.getOrNull(it.range.first - 1)) }
            .filter { it.length <= 8192 && runCatching { URI(it).rawAuthority?.isNotBlank() == true }.getOrDefault(false) }
        val observedVideos = Regex("(?<![A-Za-z0-9])BV[A-Za-z0-9]{10}(?![A-Za-z0-9])")
            .findAll(text).map { "https://www.bilibili.com/video/${it.value}" }
        return (exact + observedVideos).distinct().take(32).toList()
    }

    private fun trimBoundary(raw: String, preceding: Char?): String {
        val closing = when (preceding) { '(' -> ')'; '[' -> ']'; '{' -> '}'; else -> null }
        var depth = 0
        val boundary = if (closing == null) -1 else raw.indexOfFirst { char ->
            when (char) { preceding -> { depth++; false }; closing -> if (depth == 0) true else { depth--; false }; else -> false }
        }
        val candidate = if (boundary >= 0) raw.substring(0, boundary) else raw
        val brackets = mapOf(')' to '(', ']' to '[', '}' to '{')
        val counts = candidate.groupingBy { it }.eachCount().toMutableMap()
        // Query punctuation can be data; retain it exactly after removing enclosing brackets.
        val hasQuery = '?' in candidate || '#' in candidate
        var end = candidate.length
        while (end > 0) {
            val last = candidate[end - 1]
            val open = brackets[last]
            if (open != null && counts.getOrDefault(last, 0) > counts.getOrDefault(open, 0)) {
                counts[last] = counts.getOrDefault(last, 0) - 1
            } else if (hasQuery || last !in ".,;!") break
            end--
        }
        return candidate.substring(0, end)
    }

    /** Identifies the shared link's host, not the app that sent the share intent. */
    fun sourceLabel(text: String): String? {
        val urls = extract(text)
        if (urls.isEmpty()) return null
        val labels = urls.mapNotNull { url ->
            val host = runCatching { URI(url).host?.lowercase(Locale.ROOT)?.trimEnd('.') }.getOrNull() ?: return@mapNotNull null
            fun domain(name: String) = host == name || host.endsWith(".$name")
            when {
                domain("xiaohongshu.com") || domain("xhslink.com") -> "小红书链接"
                domain("bilibili.com") || domain("b23.tv") -> "Bilibili链接"
                domain("douyin.com") -> "抖音链接"
                domain("kuaishou.com") -> "快手链接"
                domain("weibo.com") || domain("weibo.cn") -> "微博链接"
                domain("zhihu.com") -> "知乎链接"
                host == "mp.weixin.qq.com" -> "微信文章链接"
                else -> null
            }
        }.distinct()
        return when (labels.size) { 0 -> "网页链接"; 1 -> labels.single(); else -> "多来源链接" }
    }
}
