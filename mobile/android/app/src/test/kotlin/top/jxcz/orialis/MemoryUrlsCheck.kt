package top.jxcz.orialis

/** Dependency-free JVM self-check; compile together with MemoryUrls.kt and run main. */
fun main() {
    check(MemoryUrls.extract("推荐视频，没有链接").isEmpty())
    check(MemoryUrls.extract("https://b23.tv/AbCd，https://b23.tv/AbCd").single() == "https://b23.tv/AbCd")
    check(MemoryUrls.extract("BV1xx411c7mD").single() == "https://www.bilibili.com/video/BV1xx411c7mD")
    check(MemoryUrls.extract("BV1xx411c7mDextra").isEmpty())
    check(MemoryUrls.extract("javascript:alert(1) file:///data/private").isEmpty())
    check(MemoryUrls.extract("分享 https://b23.tv/test?share=1#part。BV1xx411c7mD").first() == "https://b23.tv/test?share=1#part")
    check(MemoryUrls.extract("https://www.bilibili.com/video/BV1xx411c7mD").size == 1)
    val note = "https://www.xiaohongshu.com/explore/abc?xsec_token=AB%2Bcd%2Fef%3D&xsec_source=pc_share&app_platform=android#section"
    val short = "https://xhslink.com/a/abc123"
    check(MemoryUrls.extract("53 小红书笔记：$note 。复制打开小红书！短链：$short").toSet() == setOf(note, short))
    check(MemoryUrls.extract("「$short」【https://v.douyin.com/ABC/】《https://v.kuaishou.com/XYZ》") ==
        listOf(short, "https://v.douyin.com/ABC/", "https://v.kuaishou.com/XYZ"))
    check(MemoryUrls.extract("（https://example.com/a_(b)），(https://example.com/c_(d)).") ==
        listOf("https://example.com/a_(b)", "https://example.com/c_(d)"))
    check(MemoryUrls.extract("[https://example.com/search?q=(a)&xsec_token=AB==]").single() ==
        "https://example.com/search?q=(a)&xsec_token=AB==")
    check(MemoryUrls.extract("https://example.com/a?token=a,b;!?&empty=").single() ==
        "https://example.com/a?token=a,b;!?&empty=")
    check(MemoryUrls.extract("https://example.com/ordinary.").single() == "https://example.com/ordinary")
    check(MemoryUrls.extract("https://example.com/" + "x".repeat(8192)).isEmpty())
    check(MemoryUrls.extract((1..40).joinToString(" ") { "https://example.com/$it" }).size == 32)
    check(MemoryUrls.sourceLabel("小红书 " + note) == "小红书链接")
    check(MemoryUrls.sourceLabel(short) == "小红书链接")
    check(MemoryUrls.sourceLabel("https://m.XIAOHONGSHU.com/explore/1") == "小红书链接")
    check(MemoryUrls.sourceLabel("https://xiaohongshu.com.evil.test/a https://evilxiaohongshu.com/a https://xiaohongshu.com@evil.test/a") == "网页链接")
    check(MemoryUrls.sourceLabel("https://v.douyin.com/ABC") == "抖音链接")
    check(MemoryUrls.sourceLabel("https://v.kuaishou.com/ABC") == "快手链接")
    check(MemoryUrls.sourceLabel("https://weibo.com/123/456") == "微博链接")
    check(MemoryUrls.sourceLabel("https://www.zhihu.com/question/123") == "知乎链接")
    check(MemoryUrls.sourceLabel("https://mp.weixin.qq.com/s?__biz=AB==&mid=1&sn=a") == "微信文章链接")
    check(MemoryUrls.sourceLabel("https://example.com/path?q=1#part") == "网页链接")
    check(MemoryUrls.sourceLabel("BV1xx411c7mD") == "Bilibili链接")
    check(MemoryUrls.sourceLabel("$short https://b23.tv/ABC") == "多来源链接")
    check(MemoryUrls.sourceLabel("推荐一篇小红书笔记，未提供链接") == null)
    check(MemoryUrls.extract("https://example.com/a" + ")".repeat(8000)).single() == "https://example.com/a")
    check(MemoryUrls.extract("https://example.com/a" + ")".repeat(64000)).isEmpty())
    check(MemoryUrls.extract("(https://example.com/a?q=(b)),以及下一句").single() == "https://example.com/a?q=(b)")
    check(MemoryUrls.extract("[https://example.com/a?token=x,;!?&empty=],").single() == "https://example.com/a?token=x,;!?&empty=")
    println("MemoryUrls: 32 checks passed")
}
