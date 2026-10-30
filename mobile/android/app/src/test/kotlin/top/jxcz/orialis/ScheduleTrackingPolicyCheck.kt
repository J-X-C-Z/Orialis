package top.jxcz.orialis

fun main() {
    check(!ScheduleTrackingPolicy.isOngoing(100, 200, 99))
    check(ScheduleTrackingPolicy.isOngoing(100, 200, 100))
    check(ScheduleTrackingPolicy.isOngoing(100, 200, 199))
    check(!ScheduleTrackingPolicy.isOngoing(100, 200, 200))
    check(!ScheduleTrackingPolicy.isOngoing(100, 90, 150))
    check(!ScheduleTrackingPolicy.isOngoing(0, 200, 100))
    check(ScheduleTrackingPolicy.matchesSession("new-session", "new-session"))
    check(!ScheduleTrackingPolicy.matchesSession("new-session", "old-session"))
    check(!ScheduleTrackingPolicy.matchesSession("new-session", null))
    check(!ScheduleTrackingPolicy.matchesSession("", ""))
    println("ScheduleTrackingPolicy: 10 checks passed")
}
