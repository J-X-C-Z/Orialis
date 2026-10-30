"""Explicit writable fields; omitted patch values stay untouched, null clears them."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .schedule_policy import validate_event_description


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class Recurrence(Input):
    rule: str
    until: str


class TaskFields(Input):
    title: str | None = Field(default=None, min_length=1)
    notes: str | None = None
    important: bool | None = None
    urgent: bool | None = None
    completed: bool | None = None
    due: str | None = Field(default=None, description="Due date, YYYY-MM-DD")
    due_time: str | None = Field(default=None, alias="dueTime", description="Local time, HH:MM")
    reminder_minutes: int | None = Field(default=None, alias="reminderMinutes", ge=0)
    project_id: str | None = Field(default=None, alias="projectId")
    parent_task_id: str | None = Field(default=None, alias="parentTaskId")
    schedule_id: str | None = Field(default=None, alias="scheduleId")
    recurrence: Recurrence | None = None


class TaskCreate(TaskFields):
    title: str = Field(min_length=1)


class TaskUpdate(TaskFields):
    # Defaults mark omitted patch fields; supplied values must satisfy their types.
    title: str = Field(default=None, min_length=1)
    completed: bool = Field(default=None)
    base_version: int = Field(alias="baseVersion", ge=1, description="Version from the latest read; conflicts require re-reading")


class ProjectFields(Input):
    name: str | None = Field(default=None, min_length=1)
    goal: str | None = None
    description: str | None = None
    color: str | None = None
    status: Literal["active", "completed", "archived"] | None = None
    start_date: str | None = Field(default=None, alias="startDate")
    due: str | None = None
    next_action_task_id: str | None = Field(default=None, alias="nextActionTaskId")


class ProjectCreate(ProjectFields):
    name: str = Field(min_length=1)


class ProjectUpdate(ProjectFields):
    name: str = Field(default=None, min_length=1)
    status: Literal["active", "completed", "archived"] = Field(default=None)
    base_version: int = Field(alias="baseVersion", ge=1)


class EventFields(Input):
    title: str | None = Field(default=None, min_length=1, description="One activity in one date/time slot; never an entire itinerary")
    description: str | None = Field(default=None, description="Details for this event only; multiple date/time agenda entries require separate events")

    _single_event_description = field_validator("description")(validate_event_description)
    location: str | None = None
    start_at: str | None = Field(default=None, alias="startAt", description="RFC 3339 timestamp with UTC offset")
    end_at: str | None = Field(default=None, alias="endAt", description="RFC 3339 timestamp with UTC offset")
    all_day: bool | None = Field(default=None, alias="allDay")
    important: bool | None = None
    reminder_minutes: int | None = Field(default=None, alias="reminderMinutes", ge=0)


class EventCreate(EventFields):
    title: str = Field(min_length=1, description="One activity in one date/time slot; never an entire itinerary")
    start_at: str = Field(alias="startAt", description="Start of this activity only, RFC 3339 with UTC offset; never the first date of a multi-activity plan")
    end_at: str = Field(alias="endAt", description="End of this activity only, RFC 3339 with UTC offset; never the final date of a multi-activity plan")


class EventUpdate(EventFields):
    title: str = Field(default=None, min_length=1, description="One activity in one date/time slot; never an entire itinerary")
    start_at: str = Field(default=None, alias="startAt", description="Start of this activity only, RFC 3339 with UTC offset")
    end_at: str = Field(default=None, alias="endAt", description="End of this activity only, RFC 3339 with UTC offset")
    all_day: bool = Field(default=None, alias="allDay")
    important: bool = Field(default=None)
    base_version: int = Field(alias="baseVersion", ge=1)


class MemoryUpdate(Input):
    """Only editable interpretation fields; captured evidence remains immutable."""
    title: str = Field(default=None, min_length=1, max_length=80)
    summary: str | None = Field(default=None, max_length=100_000)
    notes: str = Field(default=None, max_length=100_000)
    category: Literal["ai", "other"] | None = None
    base_version: int = Field(alias="baseVersion", ge=1)
    change_reason: str = Field(alias="changeReason", min_length=1, max_length=2000,
                               description="User-requested correction and its evidence; stored in the audit trail")

    @field_validator("title", "change_reason")
    @classmethod
    def not_blank(cls, value):
        if not value.strip():
            raise ValueError("must not be blank")
        return value

    @field_validator("summary", "notes", "change_reason")
    @classmethod
    def byte_limit(cls, value, info):
        limit = 2000 if info.field_name == "change_reason" else 100_000
        if value is not None and len(value.encode("utf-8")) > limit:
            raise ValueError(f"must not exceed {limit} UTF-8 bytes")
        return value
