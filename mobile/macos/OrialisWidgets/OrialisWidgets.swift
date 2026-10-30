import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
}

struct TodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayEntry {
    TodayEntry(date: .now, snapshot: WidgetSnapshot(tasks: [], updatedAt: ""))
  }
  func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
    completion(read())
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
    let entry = read()
    let midnight = Calendar.current.startOfDay(for: entry.date).addingTimeInterval(36 * 3600)
    let nextDay = Calendar.current.startOfDay(for: midnight)
    completion(Timeline(entries: [entry], policy: .after(min(nextDay, entry.date.addingTimeInterval(900)))))
  }
  private func read() -> TodayEntry {
    let snapshot = WidgetSnapshot.fileURL.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
    return TodayEntry(date: .now, snapshot: snapshot)
  }
}

struct TodayWidgetView: View {
  let entry: TodayEntry
  @Environment(\.widgetFamily) private var family
  private var tasks: [WidgetTask] { entry.snapshot?.today(at: entry.date) ?? [] }
  private var pending: [WidgetTask] { tasks.filter { !$0.completed } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("今日待办", systemImage: "checkmark.circle.fill")
          .font(.headline).foregroundStyle(.tint).widgetAccentable()
        Spacer()
        Text(entry.date, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
      }
      if entry.snapshot == nil {
        Spacer(minLength: 0)
        Text("打开 Orialis 同步待办").font(.subheadline).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("\(pending.count)").font(.system(size: 32, weight: .semibold, design: .rounded)).widgetAccentable()
          Text("项待完成").font(.caption).foregroundStyle(.secondary)
          Spacer()
          if family == .systemMedium {
            Text("已完成 \(tasks.count - pending.count)/\(tasks.count)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if pending.isEmpty {
          Text(tasks.isEmpty ? "今天还没有安排" : "今日待办已完成")
            .font(.subheadline).foregroundStyle(.secondary)
        } else {
          ForEach(Array(pending.prefix(family == .systemSmall ? 2 : 3))) { task in
            HStack(spacing: 7) {
              Image(systemName: "circle").font(.caption).foregroundStyle(.secondary)
              Text(task.title).font(.subheadline).lineLimit(1)
            }.accessibilityElement(children: .combine)
          }
        }
        Spacer(minLength: 0)
        if let stamp = entry.snapshot?.updatedAt,
           let updated = WidgetTask(id: "", title: "", dueAt: stamp, completed: false).dueDate,
           entry.date.timeIntervalSince(updated) > 3600 {
          Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .containerBackground(.background, for: .widget)
  }
}

@main
struct OrialisTodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.kind, provider: TodayProvider()) { entry in
      TodayWidgetView(entry: entry)
    }
    .configurationDisplayName("Orialis · 今日待办")
    .description("查看今天的安排与完成进度。点击打开 Orialis。")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
