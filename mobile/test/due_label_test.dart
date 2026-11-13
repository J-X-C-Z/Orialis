import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/pages/shared/due_label.dart';

void main() {
  // Thursday 2026-11-12 10:30.
  final now = DateTime(2026, 11, 12, 10, 30);

  test('relative wording near today, absolute further out', () {
    expect(dueInfo('2026-11-12', null, now)!.label, '今天');
    expect(dueInfo('2026-11-12', '14:00', now)!.label, '今天 14:00');
    expect(dueInfo('2026-11-13', null, now)!.label, '明天');
    expect(dueInfo('2026-11-14', null, now)!.label, '后天');
    expect(dueInfo('2026-11-11', null, now)!.label, '昨天');
    expect(dueInfo('2026-11-15', null, now)!.label, '周日');
    expect(dueInfo('2026-11-17', null, now)!.label, '下周二');
    expect(dueInfo('2026-11-23', null, now)!.label, '11月23日');
    expect(dueInfo('2027-01-03', null, now)!.label, '2027年1月3日');
    expect(dueInfo(null, null, now), isNull);
    expect(dueInfo('bad', '08:00', now)!.label, 'bad 08:00');
  });

  test('overdue days and passed times today', () {
    final past = dueInfo('2026-11-09', null, now)!;
    expect(past.overdue, isTrue);
    expect(past.overdueDays, 3);
    final late = dueInfo('2026-11-12', '09:00', now)!;
    expect(late.overdue, isTrue);
    expect(late.overdueDays, 0);
    expect(late.today, isTrue);
    expect(dueInfo('2026-11-12', '11:00', now)!.overdue, isFalse);
    expect(dueInfo('2026-11-12', null, now)!.overdue, isFalse);
  });

  test('schedule countdown', () {
    expect(
      scheduleCountdown(
        now.add(const Duration(minutes: 25)),
        now.add(const Duration(hours: 1)),
        now,
      ),
      '25 分钟后开始',
    );
    expect(
      scheduleCountdown(
        now.add(const Duration(minutes: 90)),
        now.add(const Duration(hours: 2)),
        now,
      ),
      '1 小时 30 分后开始',
    );
    expect(
      scheduleCountdown(
        now.subtract(const Duration(minutes: 10)),
        now.add(const Duration(minutes: 40)),
        now,
      ),
      '进行中 · 还剩 40 分钟',
    );
    expect(
      scheduleCountdown(
        now.add(const Duration(hours: 13)),
        now.add(const Duration(hours: 14)),
        now,
      ),
      isNull,
    );
    expect(
      scheduleCountdown(
        now.subtract(const Duration(hours: 2)),
        now.subtract(const Duration(hours: 1)),
        now,
      ),
      isNull,
    );
  });
}
