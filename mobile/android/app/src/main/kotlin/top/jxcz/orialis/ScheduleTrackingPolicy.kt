package top.jxcz.orialis

internal object ScheduleTrackingPolicy {
    fun isOngoing(start: Long, end: Long, now: Long) = start > 0 && start <= now && now < end
    fun matchesSession(current: String, received: String?) = current.isNotBlank() && current == received
}
