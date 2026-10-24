import test from "node:test";
import assert from "node:assert/strict";
import {
  addDays,
  dateKey,
  expandOccurrences,
  monthDays,
  occursOn,
  overlaps,
  toIso,
  toLocalInput,
  weekDays,
  type RecurrenceRule,
} from "../src/calendar";

process.env.TZ = "America/New_York";
const rule = (overrides: Partial<RecurrenceRule> = {}): RecurrenceRule => ({
  frequency: "daily",
  interval: 1,
  weekdays: [1],
  until: "",
  count: 3,
  ...overrides,
});
const local = (value: string) => new Date(toIso(value));

test("local input validates dates and nonexistent DST times", () => {
  assert.equal(toLocalInput(toIso("2026-10-13T09:30")), "2026-10-13T09:30");
  for (const bad of [
    "2026-02-30T12:00",
    "2026-13-01T12:00",
    "2026-10-13T24:00",
    "2026-03-08T02:30",
    "bad",
  ]) {
    assert.throws(() => toIso(bad));
  }
});

test("week starts Monday and month grid always includes 42 local dates", () => {
  const days = weekDays(local("2026-10-18T20:00"));
  assert.equal(dateKey(days[0]), "2026-10-12");
  assert.equal(dateKey(days[6]), "2026-10-18");
  const month = monthDays(local("2026-03-15T12:00"));
  assert.equal(month.length, 42);
  assert.equal(dateKey(month[0]), "2026-02-23");
  assert.equal(dateKey(month[41]), "2026-04-05");
  assert.ok(month.every((date) => date.getHours() === 0));
  assert.equal(addDays(local("2026-03-07T09:00"), 1).getHours(), 9);
});

test("overlaps uses half-open intervals and cross-day events appear on each occupied day", () => {
  const event = {
    startAt: toIso("2026-10-13T23:00"),
    endAt: toIso("2026-10-15T00:00"),
  };
  assert.ok(occursOn(event, local("2026-10-13T00:00")));
  assert.ok(occursOn(event, local("2026-10-14T00:00")));
  assert.equal(occursOn(event, local("2026-10-15T00:00")), false);
  assert.equal(
    overlaps(event, { startAt: event.endAt, endAt: toIso("2026-10-15T01:00") }),
    false,
  );
  assert.ok(
    overlaps(event, {
      startAt: toIso("2026-10-14T09:00"),
      endAt: toIso("2026-10-14T10:00"),
    }),
  );
  assert.throws(() =>
    overlaps(event, { startAt: event.endAt, endAt: event.startAt }),
  );
});

test("daily repetition preserves both wall clocks and cross-day span through DST", () => {
  const items = expandOccurrences(
    "2026-03-07T23:00",
    "2026-03-08T09:00",
    rule(),
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.startAt)),
    ["2026-03-07T23:00", "2026-03-08T23:00", "2026-03-09T23:00"],
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.endAt)),
    ["2026-03-08T09:00", "2026-03-09T09:00", "2026-03-10T09:00"],
  );
  const allDay = expandOccurrences(
    "2026-03-07T00:00",
    "2026-03-08T00:00",
    rule(),
  );
  assert.equal(
    (Date.parse(allDay[1].endAt) - Date.parse(allDay[1].startAt)) / 3_600_000,
    23,
  );
});

test("existing zero-duration schedules display on their start day without conflicts", () => {
  const instant = {
    startAt: toIso("2026-10-14T00:00"),
    endAt: toIso("2026-10-14T00:00"),
  };
  const enclosing = {
    startAt: toIso("2026-10-13T23:00"),
    endAt: toIso("2026-10-14T01:00"),
  };
  assert.equal(overlaps(instant, enclosing), false);
  assert.equal(overlaps(enclosing, instant), false);
  assert.equal(overlaps(instant, instant), false);
  assert.equal(occursOn(instant, local("2026-10-13T12:00")), false);
  assert.equal(occursOn(instant, local("2026-10-14T12:00")), true);
  assert.equal(occursOn(instant, local("2026-10-15T12:00")), false);
  assert.throws(() =>
    occursOn(
      { startAt: enclosing.endAt, endAt: enclosing.startAt },
      local("2026-10-14T12:00"),
    ),
  );
  assert.throws(() =>
    expandOccurrences(
      "2026-10-14T00:00",
      "2026-10-14T00:00",
      rule({ frequency: "none" }),
    ),
  );
});

test("nonexistent wall-clock occurrences are skipped", () => {
  const items = expandOccurrences(
    "2026-03-07T02:30",
    "2026-03-07T03:30",
    rule({ count: 2 }),
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.startAt)),
    ["2026-03-07T02:30", "2026-03-09T02:30"],
  );
});

test("weekly repetition respects selected weekdays, Monday intervals, and inclusive until", () => {
  const items = expandOccurrences(
    "2026-10-14T09:00",
    "2026-10-14T10:00",
    rule({
      frequency: "weekly",
      interval: 2,
      weekdays: [5, 1, 1],
      count: 10,
      until: "2026-10-30",
    }),
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.startAt)),
    ["2026-10-16T09:00", "2026-10-26T09:00", "2026-10-30T09:00"],
  );
});

test("monthly repetition skips missing month dates instead of spilling over", () => {
  const items = expandOccurrences(
    "2026-01-31T09:00",
    "2026-02-01T10:00",
    rule({ frequency: "monthly" }),
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.startAt)),
    ["2026-01-31T09:00", "2026-03-31T09:00", "2026-05-31T09:00"],
  );
  assert.deepEqual(
    items.map((item) => toLocalInput(item.endAt)),
    ["2026-02-01T10:00", "2026-04-01T10:00", "2026-06-01T10:00"],
  );
});

test("count and until use the first boundary reached, and no recurrence produces one event", () => {
  assert.equal(
    expandOccurrences(
      "2026-10-13T09:00",
      "2026-10-13T10:00",
      rule({ count: 2, until: "2026-12-31" }),
    ).length,
    2,
  );
  assert.equal(
    expandOccurrences(
      "2026-10-13T09:00",
      "2026-10-13T10:00",
      rule({ count: 100, until: "2026-10-13" }),
    ).length,
    1,
  );
  assert.equal(
    expandOccurrences(
      "2026-10-13T09:00",
      "2026-10-13T10:00",
      rule({ frequency: "none" }),
    ).length,
    1,
  );
  assert.equal(
    expandOccurrences(
      "2026-10-13T09:00",
      "2026-10-13T10:00",
      rule({ frequency: "weekly", weekdays: [1], until: "2026-10-13" }),
    ).length,
    0,
  );
});

test("invalid recurrence and non-positive schedules fail explicitly", () => {
  for (const bad of [
    { count: 101 },
    { count: 0 },
    { interval: 0 },
    { interval: 1.5 },
    { weekdays: [7] },
    { frequency: "weekly" as const, weekdays: [] },
    { until: "2026-02-30" },
    { until: "2026-10-12" },
  ]) {
    assert.throws(() =>
      expandOccurrences("2026-10-13T09:00", "2026-10-13T10:00", rule(bad)),
    );
  }
  assert.throws(() =>
    expandOccurrences("2026-10-13T09:00", "2026-10-13T09:00", rule()),
  );
});
