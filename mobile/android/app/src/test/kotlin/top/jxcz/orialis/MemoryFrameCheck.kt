package top.jxcz.orialis

/** Compile together with MemoryFrame.kt and run main; no Android runtime or dependencies. */
fun main() {
    check(!MemoryFrame.hasVisibleContent(1080, 2340) { _, _ -> 0 })
    check(!MemoryFrame.hasVisibleContent(1080, 2340) { _, _ -> 0xff000000.toInt() })
    check(!MemoryFrame.hasVisibleContent(1080, 2340) { _, _ -> 0x00ffffff })
    check(MemoryFrame.hasVisibleContent(1080, 2340) { _, _ -> 0xffffffff.toInt() })
    check(MemoryFrame.hasVisibleContent(16, 16) { x, y -> if (x == 8 && y == 8) 0xff000001.toInt() else 0 })
    check(MemoryFrame.hasVisibleContent(1, 1) { _, _ -> 0xff010101.toInt() })
    var sampled = 0
    check(!MemoryFrame.hasVisibleContent(1080, 2340) { _, _ -> sampled++; 0 })
    check(sampled == 256)
    println("MemoryFrame: 8 checks passed")
}
