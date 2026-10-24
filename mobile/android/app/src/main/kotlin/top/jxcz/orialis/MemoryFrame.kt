package top.jxcz.orialis

internal object MemoryFrame {
    fun hasVisibleContent(width: Int, height: Int, pixelAt: (Int, Int) -> Int): Boolean {
        require(width > 0 && height > 0)
        for (row in 0..15) for (column in 0..15) {
            val pixel = pixelAt(column * (width - 1) / 15, row * (height - 1) / 15)
            if (pixel ushr 24 != 0 && pixel and 0x00ffffff != 0) return true
        }
        return false
    }
}
