import 'package:flutter_test/flutter_test.dart';
import 'package:orialis_mobile/features/wear/wear_protocol.dart';
import 'package:orialis_mobile/features/wear/wear_snapshot_ordering.dart';

void main() {
  test('prioritizes open relevant tasks and keeps completed tasks last', () {
    final now = DateTime(2026, 6, 10, 12);
    final candidates = {
      'tasks': [
        {'id': 'done-today', 'due': '2026-06-10', 'completed': true},
        {'id': 'undated', 'completed': false},
        {'id': 'future-later', 'due': '2026-06-12', 'completed': false},
        {'id': 'overdue-older', 'due': '2026-06-08', 'completed': false},
        {'id': 'today', 'due': '2026-06-10', 'completed': false},
        {'id': 'future-sooner', 'due': '2026-06-11', 'completed': false},
        {'id': 'overdue-sooner', 'due': '2026-06-09', 'completed': false},
        {'id': 'no-position', 'due': '2026-06-10', 'completed': false},
        {
          'id': 'explicit-position',
          'due': '2026-06-10',
          'completed': false,
          'manualPosition': 2,
        },
      ],
    };

    WearSnapshotOrdering.sort(candidates, now);

    expect(candidates['tasks']!.map((task) => task['id']), [
      'explicit-position',
      'no-position',
      'today',
      'overdue-sooner',
      'overdue-older',
      'future-sooner',
      'future-later',
      'undated',
      'done-today',
    ]);
  });

  test('keeps active and future zoned schedules ahead of ended history', () {
    final now = DateTime.utc(2026, 6, 9, 23, 30);
    final candidates = {
      'schedules': [
        {
          'id': 'ended',
          'startAt': '2026-06-10T00:00:00+10:00',
          'endAt': '2026-06-10T00:30:00+10:00',
        },
        {
          'id': 'future',
          'startAt': '2026-06-11T09:00:00+08:00',
          'endAt': '2026-06-11T10:00:00+08:00',
        },
        {
          'id': 'active-across-local-date',
          'startAt': '2026-06-10T12:00:00+14:00',
          'endAt': '2026-06-10T14:00:00+14:00',
        },
      ],
    };

    WearSnapshotOrdering.sort(candidates, now);

    expect(candidates['schedules']!.map((event) => event['id']), [
      'active-across-local-date',
      'future',
      'ended',
    ]);
    expect(WearProtocol.maxSnapshotBytes, 16384);
  });
}
