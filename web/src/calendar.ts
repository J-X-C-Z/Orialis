export interface TimeRange {
  startAt: string;
  endAt: string;
}
export interface RecurrenceRule {
  frequency: "none" | "daily" | "weekly" | "monthly";
  interval: number;
  weekdays: number[];
  until: string;
  count: number;
}

const pad = (value: number) => String(value).padStart(2, "0");
const validDate = (date: Date) => {
  if (!Number.isFinite(date.getTime())) throw new Error("日期无效");
  return date;
};

export function dateKey(date: Date): string {
  validDate(date);
  return `${String(date.getFullYear()).padStart(4, "0")}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function parseLocal(value: string): Date {
  const match =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$/.exec(
      value,
    );
  if (!match) throw new Error("请输入有效的本地日期和时间");
  const [, y, m, d, h, min, sec = "0", ms = "0"] = match;
  const date = new Date(0);
  date.setFullYear(+y, +m - 1, +d);
  date.setHours(+h, +min, +sec, +ms.padEnd(3, "0"));
  if (
    date.getFullYear() !== +y ||
    date.getMonth() !== +m - 1 ||
    date.getDate() !== +d ||
    date.getHours() !== +h ||
    date.getMinutes() !== +min ||
    date.getSeconds() !== +sec
  ) {
    throw new Error("日期或本地时间不存在");
  }
  return validDate(date);
}

export function toLocalInput(iso: string): string {
  const date = validDate(new Date(iso));
  return `${dateKey(date)}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function toIso(local: string): string {
  return parseLocal(local).toISOString();
}

export function addDays(date: Date, days: number): Date {
  validDate(date);
  if (!Number.isInteger(days)) throw new Error("天数必须是整数");
  const result = new Date(date);
  result.setDate(result.getDate() + days);
  return validDate(result);
}

export function weekDays(anchor: Date): Date[] {
  const first = new Date(validDate(anchor));
  first.setHours(0, 0, 0, 0);
  first.setDate(first.getDate() - ((first.getDay() + 6) % 7));
  return Array.from({ length: 7 }, (_, index) => addDays(first, index));
}

export function monthDays(anchor: Date): Date[] {
  const first = new Date(validDate(anchor));
  first.setDate(1);
  return Array.from({ length: 42 }, (_, index) =>
    addDays(weekDays(first)[0], index),
  );
}

function rangeTimes(range: TimeRange): [number, number] {
  const start = validDate(new Date(range.startAt)).getTime();
  const end = validDate(new Date(range.endAt)).getTime();
  if (end < start) throw new Error("结束时间不能早于开始时间");
  return [start, end];
}

export function overlaps(a: TimeRange, b: TimeRange): boolean {
  const [aStart, aEnd] = rangeTimes(a);
  const [bStart, bEnd] = rangeTimes(b);
  if (aStart === aEnd || bStart === bEnd) return false;
  return aStart < bEnd && bStart < aEnd;
}

export function occursOn(event: TimeRange, day: Date): boolean {
  const [eventStart, eventEnd] = rangeTimes(event);
  if (eventStart === eventEnd)
    return dateKey(new Date(eventStart)) === dateKey(day);
  const start = new Date(validDate(day));
  start.setHours(0, 0, 0, 0);
  return overlaps(event, {
    startAt: start.toISOString(),
    endAt: addDays(start, 1).toISOString(),
  });
}

const dayNumber = (date: Date) => {
  const utc = new Date(0);
  utc.setUTCFullYear(date.getFullYear(), date.getMonth(), date.getDate());
  utc.setUTCHours(0, 0, 0, 0);
  return utc.getTime() / 86_400_000;
};

/** Produces independent schedules, preserving local wall clocks across DST changes. */
export function expandOccurrences(
  startLocal: string,
  endLocal: string,
  rule: RecurrenceRule,
): TimeRange[] {
  const start = parseLocal(startLocal);
  const end = parseLocal(endLocal);
  if (end <= start) throw new Error("结束时间必须晚于开始时间");
  if (!["none", "daily", "weekly", "monthly"].includes(rule.frequency))
    throw new Error("重复类型无效");
  if (!Number.isSafeInteger(rule.interval) || rule.interval < 1)
    throw new Error("重复间隔必须是正整数");
  if (!Number.isInteger(rule.count) || rule.count < 1 || rule.count > 100)
    throw new Error("生成数量须为 1–100");
  if (
    !Array.isArray(rule.weekdays) ||
    rule.weekdays.some((day) => !Number.isInteger(day) || day < 0 || day > 6)
  ) {
    throw new Error("星期须为 0–6");
  }
  if (rule.frequency === "weekly" && !rule.weekdays.length)
    throw new Error("请选择至少一个星期");
  if (rule.until && !/^\d{4}-\d{2}-\d{2}$/.test(rule.until))
    throw new Error("截止日期无效");
  if (rule.until) {
    parseLocal(`${rule.until}T12:00`);
    if (rule.until < dateKey(start))
      throw new Error("截止日期不能早于开始日期");
  }
  if (rule.frequency === "none")
    return [{ startAt: start.toISOString(), endAt: end.toISOString() }];
  const results: TimeRange[] = [];
  const endDayOffset = dayNumber(end) - dayNumber(start);
  const weekStart = weekDays(start)[0];
  // Jump directly between recurrence periods, so a large interval never requires a day-by-day scan.
  for (let period = 0; results.length < rule.count; period++) {
    let candidates: Date[];
    if (rule.frequency === "weekly") {
      candidates = [...new Set(rule.weekdays)]
        .sort((a, b) => ((a + 6) % 7) - ((b + 6) % 7))
        .map((day) =>
          addDays(weekStart, period * rule.interval * 7 + ((day + 6) % 7)),
        );
    } else if (rule.frequency === "monthly") {
      const candidate = new Date(start);
      candidate.setDate(1);
      candidate.setMonth(candidate.getMonth() + period * rule.interval);
      validDate(candidate);
      candidate.setDate(start.getDate());
      const targetMonth =
        (((start.getMonth() + period * rule.interval) % 12) + 12) % 12;
      if (candidate.getMonth() !== targetMonth) {
        if (rule.until && dateKey(candidate) > rule.until) break;
        continue;
      }
      candidates = [candidate];
    } else candidates = [addDays(start, period * rule.interval)];
    for (const candidate of candidates) {
      if (dateKey(candidate) < dateKey(start)) continue;
      if (rule.until && dateKey(candidate) > rule.until) return results;
      const candidateEnd = addDays(candidate, endDayOffset);
      candidate.setHours(
        start.getHours(),
        start.getMinutes(),
        start.getSeconds(),
        start.getMilliseconds(),
      );
      candidateEnd.setHours(
        end.getHours(),
        end.getMinutes(),
        end.getSeconds(),
        end.getMilliseconds(),
      );
      // Spring-forward gaps have no matching wall clock; do not silently shift a schedule.
      if (
        candidate.getHours() !== start.getHours() ||
        candidate.getMinutes() !== start.getMinutes() ||
        candidateEnd.getHours() !== end.getHours() ||
        candidateEnd.getMinutes() !== end.getMinutes() ||
        candidateEnd <= candidate
      )
        continue;
      results.push({
        startAt: candidate.toISOString(),
        endAt: candidateEnd.toISOString(),
      });
      if (results.length === rule.count) return results;
    }
  }
  return results;
}
