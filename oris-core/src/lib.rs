use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};

pub const SERVICE_NAME: &str = "orialis";
pub const API_VERSION: &str = "v1";

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ServiceMetadata {
    pub service: &'static str,
    pub api_version: &'static str,
    pub version: String,
    pub environment: String,
    pub public_url: String,
}

pub fn metadata(version: impl Into<String>, environment: impl Into<String>, public_url: impl Into<String>) -> ServiceMetadata {
    ServiceMetadata {
        service: SERVICE_NAME,
        api_version: API_VERSION,
        version: version.into(),
        environment: environment.into(),
        public_url: public_url.into(),
    }
}

/// IDs are UUIDs at the persistence boundary. Keeping the core layer free of a
/// UUID crate lets this scaffold remain focused on the wire/domain contract;
/// the server will generate UUIDv7 values when it owns persistence.
pub type EntityId = String;

/// RFC3339 timestamp used by the API/domain boundary.
pub type Timestamp = String;

/// The four quadrants are a view derived from the two stored decisions.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
pub enum Quadrant {
    #[serde(rename = "q1")]
    ImportantAndUrgent,
    #[serde(rename = "q2")]
    ImportantNotUrgent,
    #[serde(rename = "q3")]
    NotImportantAndUrgent,
    #[serde(rename = "q4")]
    NotImportantNotUrgent,
}

/// A task is work with a deadline, not a calendar time block.
///
/// In particular, tasks intentionally have no `start_at`/`end_at`. A course or
/// other time-bounded item belongs in [`CalendarEvent`]. `quadrant` is likewise
/// not a stored field: it is calculated from `important` and `urgent`.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: EntityId,
    pub user_id: EntityId,
    pub title: String,
    pub notes: Option<String>,
    pub important: Option<bool>,
    pub urgent: Option<bool>,
    pub completed: bool,
    pub completed_at: Option<Timestamp>,
    pub due: Option<String>,
    pub due_time: Option<String>,
    pub reminder_minutes: Option<i64>,
    pub project_id: Option<EntityId>,
    pub recurrence: Option<String>,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub version: u64,
    pub deleted_at: Option<Timestamp>,
}

impl Task {
    /// Returns `None` while either priority decision is still unclassified.
    pub fn quadrant(&self) -> Option<Quadrant> {
        match (self.important, self.urgent) {
            (Some(true), Some(true)) => Some(Quadrant::ImportantAndUrgent),
            (Some(true), Some(false)) => Some(Quadrant::ImportantNotUrgent),
            (Some(false), Some(true)) => Some(Quadrant::NotImportantAndUrgent),
            (Some(false), Some(false)) => Some(Quadrant::NotImportantNotUrgent),
            _ => None,
        }
    }
}

impl Serialize for Task {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("Task", 18)?;
        state.serialize_field("id", &self.id)?;
        state.serialize_field("userId", &self.user_id)?;
        state.serialize_field("title", &self.title)?;
        state.serialize_field("notes", &self.notes)?;
        state.serialize_field("important", &self.important)?;
        state.serialize_field("urgent", &self.urgent)?;
        state.serialize_field("quadrant", &self.quadrant())?;
        state.serialize_field("completed", &self.completed)?;
        state.serialize_field("completedAt", &self.completed_at)?;
        state.serialize_field("due", &self.due)?;
        state.serialize_field("dueTime", &self.due_time)?;
        state.serialize_field("reminderMinutes", &self.reminder_minutes)?;
        state.serialize_field("projectId", &self.project_id)?;
        state.serialize_field("recurrence", &self.recurrence)?;
        state.serialize_field("createdAt", &self.created_at)?;
        state.serialize_field("updatedAt", &self.updated_at)?;
        state.serialize_field("version", &self.version)?;
        state.serialize_field("deletedAt", &self.deleted_at)?;
        state.end()
    }
}

/// A project groups tasks and milestones; it does not create calendar blocks.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: EntityId,
    pub user_id: EntityId,
    pub name: String,
    pub goal: Option<String>,
    pub description: Option<String>,
    pub status: String,
    pub start_date: Option<String>,
    pub due: Option<String>,
    pub next_action_task_id: Option<EntityId>,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub version: u64,
    pub deleted_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Milestone {
    pub id: EntityId,
    pub user_id: EntityId,
    pub project_id: EntityId,
    pub title: String,
    pub due: Option<String>,
    pub completed: bool,
    pub completed_at: Option<Timestamp>,
    pub position: i64,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub version: u64,
    pub deleted_at: Option<Timestamp>,
}

/// A calendar item always represents a concrete time interval.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: EntityId,
    pub user_id: EntityId,
    pub title: String,
    pub description: Option<String>,
    pub location: Option<String>,
    pub start_at: Timestamp,
    pub end_at: Timestamp,
    pub all_day: bool,
    pub reminder_minutes: Option<i64>,
    pub task_id: Option<EntityId>,
    pub project_id: Option<EntityId>,
    pub source: String,
    pub external_id: Option<String>,
    pub created_at: Timestamp,
    pub updated_at: Timestamp,
    pub version: u64,
    pub deleted_at: Option<Timestamp>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncEntityType {
    Task,
    Project,
    Milestone,
    CalendarEvent,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SyncAction {
    Created,
    Updated,
    Deleted,
}

/// An append-only change-log entry. A `Deleted` event is the sync tombstone;
/// clients must not infer deletion from the absence of an entity payload.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SyncEvent {
    pub id: EntityId,
    pub cursor: u64,
    pub user_id: EntityId,
    pub entity_type: SyncEntityType,
    pub entity_id: EntityId,
    pub action: SyncAction,
    pub entity_version: u64,
    pub created_at: Timestamp,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn creates_oris_metadata() {
        let value = metadata("0.1.0", "development", "https://orialis.jxcz.top");
        assert_eq!(value.service, "orialis");
        assert_eq!(value.api_version, "v1");
        assert_eq!(value.public_url, "https://orialis.jxcz.top");
    }

    fn task(important: Option<bool>, urgent: Option<bool>) -> Task {
        Task {
            id: "0198f3b5-2d5a-7abc-8f14-7e46e6d7f001".into(),
            user_id: "0198f3b5-2d5a-7abc-8f14-7e46e6d7f002".into(),
            title: "提交作业".into(),
            notes: Some("完成实验报告并上传".into()),
            important,
            urgent,
            completed: false,
            completed_at: None,
            due: Some("2026-09-20".into()),
            due_time: Some("23:59".into()),
            reminder_minutes: Some(30),
            project_id: None,
            recurrence: None,
            created_at: "2026-09-16T08:00:00Z".into(),
            updated_at: "2026-09-16T08:00:00Z".into(),
            version: 1,
            deleted_at: None,
        }
    }

    #[test]
    fn task_quadrant_is_derived_and_tasks_are_not_calendar_events() {
        let mut value = task(Some(true), Some(false));
        assert_eq!(value.quadrant(), Some(Quadrant::ImportantNotUrgent));

        let json = serde_json::to_value(&value).unwrap();
        assert_eq!(json["quadrant"], "q2");
        assert_eq!(json["due"], "2026-09-20");
        assert_eq!(json["dueTime"], "23:59");
        assert!(json.get("startAt").is_none());
        assert!(json.get("endAt").is_none());

        value.important = Some(false);
        value.urgent = Some(true);
        assert_eq!(serde_json::to_value(&value).unwrap()["quadrant"], "q3");
    }

    #[test]
    fn unknown_priority_is_not_forced_into_a_quadrant() {
        let value = task(None, Some(true));
        assert_eq!(value.quadrant(), None);
        assert_eq!(serde_json::to_value(value).unwrap()["quadrant"], json!(null));
    }

    #[test]
    fn deserializing_a_legacy_quadrant_does_not_make_it_truth() {
        let mut input = serde_json::to_value(task(Some(true), Some(true))).unwrap();
        input["quadrant"] = json!("q4");

        let decoded: Task = serde_json::from_value(input).unwrap();
        assert_eq!(decoded.quadrant(), Some(Quadrant::ImportantAndUrgent));
    }

    #[test]
    fn project_and_milestone_keep_relationship_and_progress_fields() {
        let project = Project {
            id: "project-1".into(),
            user_id: "user-1".into(),
            name: "毕业设计".into(),
            goal: Some("按期完成并答辩".into()),
            description: None,
            status: "active".into(),
            start_date: Some("2026-09-01".into()),
            due: Some("2026-12-01".into()),
            next_action_task_id: Some("task-1".into()),
            created_at: "2026-09-01T00:00:00Z".into(),
            updated_at: "2026-09-16T08:00:00Z".into(),
            version: 3,
            deleted_at: None,
        };
        let milestone = Milestone {
            id: "milestone-1".into(),
            user_id: "user-1".into(),
            project_id: project.id.clone(),
            title: "完成开题".into(),
            due: Some("2026-10-01".into()),
            completed: false,
            completed_at: None,
            position: 1,
            created_at: "2026-09-01T00:00:00Z".into(),
            updated_at: "2026-09-16T08:00:00Z".into(),
            version: 1,
            deleted_at: None,
        };

        let project_json = serde_json::to_value(project).unwrap();
        let milestone_json = serde_json::to_value(milestone).unwrap();
        assert_eq!(project_json["nextActionTaskId"], "task-1");
        assert_eq!(milestone_json["projectId"], "project-1");
        assert_eq!(milestone_json["position"], 1);
    }

    #[test]
    fn calendar_event_has_an_interval_separate_from_task_deadline() {
        let event = CalendarEvent {
            id: "event-1".into(),
            user_id: "user-1".into(),
            title: "高等数学".into(),
            description: Some("第 3 教学楼".into()),
            location: Some("301".into()),
            start_at: "2026-09-17T08:00:00+08:00".into(),
            end_at: "2026-09-17T09:40:00+08:00".into(),
            all_day: false,
            reminder_minutes: Some(10),
            task_id: None,
            project_id: None,
            source: "oris".into(),
            external_id: None,
            created_at: "2026-09-16T08:00:00Z".into(),
            updated_at: "2026-09-16T08:00:00Z".into(),
            version: 1,
            deleted_at: None,
        };

        let json = serde_json::to_value(event).unwrap();
        assert_eq!(json["startAt"], "2026-09-17T08:00:00+08:00");
        assert_eq!(json["endAt"], "2026-09-17T09:40:00+08:00");
        assert_eq!(json["source"], "oris");
    }

    #[test]
    fn sync_event_represents_a_versioned_delete_tombstone() {
        let event = SyncEvent {
            id: "sync-1".into(),
            cursor: 124,
            user_id: "user-1".into(),
            entity_type: SyncEntityType::Task,
            entity_id: "task-1".into(),
            action: SyncAction::Deleted,
            entity_version: 4,
            created_at: "2026-09-16T08:00:00Z".into(),
        };

        let json = serde_json::to_value(event).unwrap();
        assert_eq!(json["cursor"], 124);
        assert_eq!(json["entityType"], "task");
        assert_eq!(json["entityVersion"], 4);
        assert_eq!(json["action"], "deleted");
    }
}
