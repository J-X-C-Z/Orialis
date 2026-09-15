use chrono::{Duration, NaiveDate, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 方寸网页端持久化文档的稳定边界。
/// 允许未来字段继续扩展，避免 Rust 核心与网页端版本强耦合。
#[derive(Debug, Default, Deserialize)]
pub struct Document {
    #[serde(default)]
    pub tasks: Vec<Value>,
    #[serde(default)]
    pub projects: Vec<Value>,
    #[serde(default)]
    pub courses: Vec<Value>,
}

#[derive(Debug, Default, Serialize, PartialEq, Eq)]
pub struct DocumentCounts {
    pub tasks: usize,
    #[serde(rename = "pendingTasks")]
    pub pending_tasks: usize,
    pub projects: usize,
    pub courses: usize,
}

#[derive(Debug, Default, Serialize, PartialEq, Eq)]
pub struct DocumentSummary {
    pub counts: DocumentCounts,
    #[serde(rename = "dataBytes")]
    pub data_bytes: usize,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ValidationError {
    pub field: &'static str,
    pub message: &'static str,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct LocalEvent {
    pub local_key: String,
    pub kind: String,
    pub source_id: String,
    pub title: String,
    pub description: String,
    pub location: String,
    pub date: String,
    pub time: String,
    pub end_date: String,
    pub end_time: String,
    pub all_day: bool,
    pub reminder_minutes: i64,
    pub updated_at: i64,
}

fn text(value: &Value, key: &str) -> String { value.get(key).and_then(Value::as_str).unwrap_or_default().to_string() }
fn number(value: &Value, key: &str) -> i64 { value.get(key).and_then(Value::as_i64).or_else(|| value.get(key).and_then(Value::as_f64).map(|v| v as i64)).unwrap_or(0) }
fn date(value: &str) -> Option<NaiveDate> { NaiveDate::parse_from_str(value, "%Y-%m-%d").ok() }
fn date_string(value: NaiveDate) -> String { value.format("%Y-%m-%d").to_string() }
fn add_days(value: &str, days: i64) -> String { date(value).map(|d| date_string(d + Duration::days(days))).unwrap_or_default() }
fn slot_for(slots: &[Value], number: i64) -> Option<&Value> { slots.iter().find(|slot| number_from(slot, "number") == number) }
fn number_from(value: &Value, key: &str) -> i64 { value.get(key).and_then(Value::as_i64).or_else(|| value.get(key).and_then(Value::as_f64).map(|v| v as i64)).unwrap_or(0) }

fn task_event(task: &Value) -> Option<LocalEvent> {
    if task.get("completed").and_then(Value::as_bool) == Some(true) { return None; }
    let date = { let start = text(task, "startDate"); if start.is_empty() { text(task, "due") } else { start } };
    if date.is_empty() { return None; }
    let time = { let start = text(task, "startTime"); if start.is_empty() { text(task, "dueTime") } else { start } };
    let all_day = time.is_empty();
    let mut end_date = text(task, "endDate");
    let mut end_time = text(task, "endTime");
    if all_day { end_date = add_days(&date, 1); }
    if !all_day && end_time.is_empty() {
        let parsed = chrono::NaiveTime::parse_from_str(&time, "%H:%M").ok()?;
        let total_minutes = (parsed.hour() * 60 + parsed.minute()) as i64 + if text(task, "startDate").is_empty() { 15 } else { 60 };
        end_time = format!("{:02}:{:02}", (total_minutes / 60) % 24, total_minutes % 60);
        end_date = if total_minutes >= 24 * 60 { add_days(&date, 1) } else { date.clone() };
    }
    Some(LocalEvent { local_key: format!("task:{}", text(task, "id")), kind: "task".into(), source_id: text(task, "id"), title: if !text(task, "due").is_empty() && text(task, "startDate").is_empty() { format!("DDL · {}", if text(task, "title").is_empty() { "事项".into() } else { text(task, "title") }) } else if text(task, "title").is_empty() { "事项".into() } else { text(task, "title") }, description: text(task, "notes"), location: text(task, "location"), date, time, end_date, end_time, all_day, reminder_minutes: task.get("reminderMinutes").and_then(Value::as_i64).unwrap_or(-1), updated_at: number(task, "updatedAt").max(number(task, "createdAt")) })
}

/// 将网页文档转换为两个日历提供商共用的本地事件集合。
pub fn local_events(document_json: &str) -> Result<Vec<LocalEvent>, serde_json::Error> {
    let value: Value = serde_json::from_str(document_json)?;
    let mut events: Vec<LocalEvent> = value.get("tasks").and_then(Value::as_array).map(|items| items.iter().filter_map(task_event).collect()).unwrap_or_default();
    let semester_start = value.get("semester").and_then(|v| v.get("startDate")).and_then(Value::as_str).unwrap_or_default();
    let slots = value.get("timeSlots").and_then(Value::as_array).cloned().unwrap_or_default();
    if let Some(courses) = value.get("courses").and_then(Value::as_array) {
        for course in courses {
            let weeks = course.get("weeks").and_then(Value::as_array).cloned().unwrap_or_default();
            for week in weeks.iter().filter_map(Value::as_i64) {
                let day = number(course, "day").max(1);
                let Some(original) = date(semester_start).map(|d| d + Duration::days((week - 1) * 7 + day - 1)) else { continue };
                let original_string = date_string(original);
                let exception = value.get("courseExceptions").and_then(Value::as_array).and_then(|items| items.iter().find(|item| text(item, "courseId") == text(course, "id") && text(item, "date") == original_string));
                if exception.and_then(|v| v.get("type")).and_then(Value::as_str) == Some("cancel") { continue; }
                let target = exception.and_then(|v| v.get("targetDate")).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| original_string.clone());
                if value.get("calendarRules").and_then(Value::as_array).map(|rules| rules.iter().any(|r| text(r, "date") == target && text(r, "type") == "holiday")).unwrap_or(false) { continue; }
                let start_number = exception.and_then(|v| v.get("startSection")).and_then(Value::as_i64).unwrap_or_else(|| number(course, "startSection"));
                let end_number = exception.and_then(|v| v.get("endSection")).and_then(Value::as_i64).unwrap_or_else(|| number(course, "endSection"));
                let (Some(start), Some(end)) = (slot_for(&slots, start_number), slot_for(&slots, end_number)) else { continue; };
                events.push(LocalEvent { local_key: format!("course:{}:{}", text(course, "id"), original_string), kind: "course".into(), source_id: text(course, "id"), title: exception.map(|v| text(v, "name")).filter(|s| !s.is_empty()).unwrap_or_else(|| if text(course, "name").is_empty() { "课程".into() } else { text(course, "name") }), description: [text(course, "code"), text(course, "teacher"), text(course, "notes")].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · "), location: [text(course, "campus"), text(course, "location")].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · "), date: target.clone(), time: text(start, "startTime"), end_date: target, end_time: text(end, "endTime"), all_day: false, reminder_minutes: course.get("reminderMinutes").and_then(Value::as_i64).unwrap_or(-1), updated_at: number(course, "updatedAt").max(number(course, "createdAt")) });
            }
        }
    }
    Ok(events)
}

/// 统计服务端管理页所需的文档摘要。
pub fn summarize(document_json: &str) -> Result<DocumentSummary, serde_json::Error> {
    let document: Document = serde_json::from_str(document_json)?;
    let pending_tasks = document
        .tasks
        .iter()
        .filter(|task| task.get("completed").and_then(Value::as_bool) != Some(true))
        .count();
    Ok(DocumentSummary {
        counts: DocumentCounts {
            tasks: document.tasks.len(),
            pending_tasks,
            projects: document.projects.len(),
            courses: document.courses.len(),
        },
        data_bytes: document_json.len(),
    })
}

/// 校验持久化文档的顶层结构。空文档是合法的，未知字段保持兼容。
pub fn validate(document_json: &str) -> Result<(), Vec<ValidationError>> {
    let value: Value = match serde_json::from_str(document_json) {
        Ok(value) => value,
        Err(_) => {
            return Err(vec![ValidationError {
                field: "document",
                message: "必须是合法 JSON",
            }])
        }
    };
    let Some(object) = value.as_object() else {
        return Err(vec![ValidationError {
            field: "document",
            message: "顶层必须是对象",
        }]);
    };
    let mut errors = Vec::new();
    for field in ["tasks", "projects", "courses"] {
        if let Some(value) = object.get(field) {
            if !value.is_array() {
                errors.push(ValidationError {
                    field,
                    message: "必须是数组",
                });
            }
        }
    }
    if errors.is_empty() { Ok(()) } else { Err(errors) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarizes_current_document_shape() {
        let input = r#"{"tasks":[{"completed":false},{"completed":true},{}],"projects":[{}],"courses":[{},{}]}"#;
        let summary = summarize(input).unwrap();
        assert_eq!(summary.counts.tasks, 3);
        assert_eq!(summary.counts.pending_tasks, 2);
        assert_eq!(summary.counts.projects, 1);
        assert_eq!(summary.counts.courses, 2);
    }

    #[test]
    fn accepts_unknown_fields_and_empty_documents() {
        assert!(validate(r#"{"tasks":[],"futureField":{}}"#).is_ok());
        assert_eq!(summarize("{}").unwrap().counts, DocumentCounts::default());
    }

    #[test]
    fn rejects_wrong_top_level_types() {
        let errors = validate(r#"{"tasks":{}}"#).unwrap_err();
        assert_eq!(errors[0].field, "tasks");
    }

    #[test]
    fn creates_task_and_course_calendar_events() {
        let input = r#"{
          "tasks":[{"id":"t1","title":"复习","due":"2026-09-14","dueTime":"23:55","completed":false}],
          "semester":{"startDate":"2026-09-07"},
          "timeSlots":[{"number":1,"startTime":"08:00","endTime":"09:40"}],
          "courses":[{"id":"c1","name":"Rust","day":2,"weeks":[1],"startSection":1,"endSection":1}]
        }"#;
        let events = local_events(input).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].local_key, "task:t1");
        assert_eq!(events[0].end_date, "2026-09-15");
        assert_eq!(events[1].local_key, "course:c1:2026-09-08");
    }

    #[test]
    fn skips_cancelled_course_occurrences() {
        let input = r#"{"semester":{"startDate":"2026-09-07"},"timeSlots":[{"number":1,"startTime":"08:00","endTime":"09:40"}],"courses":[{"id":"c1","day":2,"weeks":[1],"startSection":1,"endSection":1}],"courseExceptions":[{"courseId":"c1","date":"2026-09-08","type":"cancel"}]}"#;
        assert!(local_events(input).unwrap().is_empty());
    }
}
