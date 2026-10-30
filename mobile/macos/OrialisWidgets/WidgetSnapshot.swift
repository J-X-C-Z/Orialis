import Foundation

struct WidgetTask: Codable, Identifiable {
  let id: String
  let title: String
  let dueAt: String?
  let completed: Bool

  var dueDate: Date? {
    guard let dueAt else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: dueAt) ?? ISO8601DateFormatter().date(from: dueAt)
  }
}

struct WidgetSnapshot: Codable {
  let tasks: [WidgetTask]
  let updatedAt: String
  static let group = "group.top.jxcz.orialis"
  static let kind = "OrialisToday"

  static var fileURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
      .appendingPathComponent("today-widget.json")
  }

  func today(at date: Date) -> [WidgetTask] {
    tasks.filter { task in
      guard let due = task.dueDate else { return false }
      return Calendar.current.isDate(due, inSameDayAs: date)
    }.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
  }
}
