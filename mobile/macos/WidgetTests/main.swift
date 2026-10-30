import Foundation

let start = Calendar.current.startOfDay(for: Date())
let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start)!
let formatter = ISO8601DateFormatter()
let snapshot = WidgetSnapshot(tasks: [
  WidgetTask(id: "today", title: "Today", dueAt: formatter.string(from: start), completed: false),
  WidgetTask(id: "tomorrow", title: "Tomorrow", dueAt: formatter.string(from: tomorrow), completed: true),
  WidgetTask(id: "undated", title: "Undated", dueAt: nil, completed: false)
], updatedAt: formatter.string(from: start))
assert(snapshot.today(at: start).map(\.id) == ["today"])
assert(snapshot.today(at: tomorrow).map(\.id) == ["tomorrow"])
assert(snapshot.today(at: tomorrow).first?.completed == true)
let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
assert(decoded.tasks.count == 3)
print("Widget snapshot date rollover and JSON checks passed")
