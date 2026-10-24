package top.jxcz.orialis

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class MemoryTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply { label = "记住屏幕"; state = Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        super.onClick()
        unlockAndRun {
            val intent = Intent(this, MemoryCaptureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            else { @Suppress("DEPRECATION") startActivityAndCollapse(intent) }
        }
    }
}
