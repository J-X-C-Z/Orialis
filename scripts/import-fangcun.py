#!/usr/bin/env python3
"""Import a Fangcun JSON document into an Orialis SQLite database.

The importer is deliberately a batch boundary: it uses a durable source-ID
map, keeps tasks separate from calendar events, and does not create sync_events
for historical rows. Run with --dry-run first; a successful import is one
SQLite transaction and can be run again safely.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


MAX_MILESTONES = 100
OFFSET_RE = re.compile(r"^[+-](?:0\d|1[0-4]):[0-5]\d$")


class ImportFailure(Exception):
    pass


def array(document: dict[str, Any], key: str) -> list[dict[str, Any]]:
    value = document.get(key, [])
    if value is None:
        return []
    if not isinstance(value, list):
        raise ImportFailure(f"{key} must be an array")
    return [item for item in value if isinstance(item, dict)]


def text(value: Any) -> str:
    return str(value).strip() if value is not None else ""


def nullable_date(value: Any, report: dict[str, Any], field: str) -> str | None:
    raw = text(value)
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date().isoformat()
    except ValueError:
        report["corrected"] += 1
        report["warnings"].append(f"{field}: invalid date {raw!r}; imported as null")
        return None


def timestamp(value: Any, fallback: str, report: dict[str, Any], field: str) -> str:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            report["corrected"] += 1
            report["warnings"].append(f"{field}: invalid millisecond timestamp; used import time")
    raw = text(value)
    if raw:
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        except ValueError:
            report["corrected"] += 1
            report["warnings"].append(f"{field}: invalid timestamp; used import time")
    return fallback


def new_id() -> str:
    uuid7 = getattr(uuid, "uuid7", None)
    return str(uuid7() if uuid7 else uuid.uuid4())


def source_id(item: dict[str, Any], fallback: str) -> str:
    return text(item.get("id")) or fallback


def target_id(conn: sqlite3.Connection, user_id: str, kind: str, source: str) -> str:
    row = conn.execute(
        "SELECT target_id FROM fangcun_id_map WHERE user_id=? AND source_kind=? AND source_id=?",
        (user_id, kind, source),
    ).fetchone()
    if row:
        return row[0]
    value = new_id()
    conn.execute(
        "INSERT INTO fangcun_id_map(user_id,source_kind,source_id,target_id) VALUES (?,?,?,?)",
        (user_id, kind, source, value),
    )
    return value


def count_value(conn: sqlite3.Connection, table: str, user_id: str) -> int:
    return int(conn.execute(f"SELECT COUNT(*) FROM {table} WHERE user_id=?", (user_id,)).fetchone()[0])


def import_document(conn: sqlite3.Connection, user_id: str, document: dict[str, Any], offset: str) -> dict[str, Any]:
    imported_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    report: dict[str, Any] = {
        "status": "completed",
        "importedAt": imported_at,
        "counts": {"projects": 0, "tasks": 0, "milestones": 0, "calendarEvents": 0, "skipped": 0},
        "duplicates": 0,
        "corrected": 0,
        "warnings": [],
    }

    projects = array(document, "projects")
    tasks = array(document, "tasks")
    seen_projects: set[str] = set()
    project_map: dict[str, str] = {}
    for index, item in enumerate(projects):
        old_id = source_id(item, f"project-{index}")
        if old_id in seen_projects:
            report["duplicates"] += 1
            report["counts"]["skipped"] += 1
            report["warnings"].append(f"projects[{index}]: duplicate id {old_id!r}; skipped")
            continue
        seen_projects.add(old_id)
        new_project_id = target_id(conn, user_id, "project", old_id)
        project_map[old_id] = new_project_id
        status = text(item.get("status")) or "active"
        if status not in {"active", "completed", "archived"}:
            report["corrected"] += 1
            report["warnings"].append(f"project {old_id}: unsupported status {status!r}; used active")
            status = "active"
        created = timestamp(item.get("createdAt"), imported_at, report, f"project {old_id}.createdAt")
        updated = timestamp(item.get("updatedAt"), created, report, f"project {old_id}.updatedAt")
        conn.execute(
            """INSERT OR IGNORE INTO projects
             (id,user_id,name,goal,description,color,status,start_date,due,next_action_task_id,created_at,updated_at,version)
             VALUES (?,?,?,?,?,?,?,?,?,?,?, ?,1)""",
            (
                new_project_id, user_id, text(item.get("name")) or "未命名项目",
                text(item.get("goal")) or None, text(item.get("description")) or None,
                text(item.get("color")) or None, status,
                nullable_date(item.get("startDate"), report, f"project {old_id}.startDate"),
                nullable_date(item.get("due"), report, f"project {old_id}.due"), None,
                created, updated,
            ),
        )
        report["counts"]["projects"] += 1

    task_map: dict[str, str] = {}
    seen_tasks: set[str] = set()
    for index, item in enumerate(tasks):
        old_id = source_id(item, f"task-{index}")
        if old_id in seen_tasks:
            report["duplicates"] += 1
            report["counts"]["skipped"] += 1
            report["warnings"].append(f"tasks[{index}]: duplicate id {old_id!r}; skipped")
            continue
        seen_tasks.add(old_id)
        new_task_id = target_id(conn, user_id, "task", old_id)
        task_map[old_id] = new_task_id
        old_project = text(item.get("projectId"))
        project_id = project_map.get(old_project) if old_project else None
        if old_project and project_id is None:
            report["corrected"] += 1
            report["warnings"].append(f"task {old_id}: parent project {old_project!r} missing; association cleared")
        completed = item.get("completed") is True
        created = timestamp(item.get("createdAt"), imported_at, report, f"task {old_id}.createdAt")
        updated = timestamp(item.get("updatedAt"), created, report, f"task {old_id}.updatedAt")
        completed_at = timestamp(item.get("completedAt"), imported_at, report, f"task {old_id}.completedAt") if completed else None
        task_type = text(item.get("taskType")) or text(item.get("type")) or "task"
        if task_type not in {"assignment", "project", "daily", "task"}:
            task_type = "task"
        recurrence = item.get("recurrence", item.get("repeat"))
        conn.execute(
            """INSERT OR IGNORE INTO tasks
             (id,user_id,project_id,title,notes,task_type,important,urgent,completed,completed_at,due,due_time,recurrence_rule,source,created_at,updated_at,version)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)""",
            (
                new_task_id, user_id, project_id, text(item.get("title")) or "未命名任务",
                text(item.get("notes")) or None, task_type,
                int(item.get("important") is True), int(item.get("urgent") is True), int(completed), completed_at,
                nullable_date(item.get("due"), report, f"task {old_id}.due"), text(item.get("dueTime")) or None,
                json.dumps(recurrence, ensure_ascii=False) if recurrence is not None else None,
                "fangcun", created, updated,
            ),
        )
        report["counts"]["tasks"] += 1

    for old_project, new_project in project_map.items():
        project = next((item for item in projects if source_id(item, "") == old_project), {})
        next_old = text(project.get("nextActionTaskId"))
        if next_old in task_map:
            conn.execute("UPDATE projects SET next_action_task_id=? WHERE id=? AND user_id=?", (task_map[next_old], new_project, user_id))

        milestones = project.get("milestones", [])
        if milestones is None:
            milestones = []
        if not isinstance(milestones, list):
            raise ImportFailure(f"project {old_project}: milestones must be an array")
        if len(milestones) > MAX_MILESTONES:
            raise ImportFailure(f"project {old_project}: milestones exceed {MAX_MILESTONES}; nothing was committed")
        seen_milestones: set[str] = set()
        for position, item in enumerate(milestones):
            if not isinstance(item, dict):
                report["counts"]["skipped"] += 1
                report["warnings"].append(f"project {old_project}.milestones[{position}]: invalid item; skipped")
                continue
            old_milestone = source_id(item, f"{old_project}-milestone-{position}")
            if old_milestone in seen_milestones:
                report["duplicates"] += 1
                report["counts"]["skipped"] += 1
                report["warnings"].append(f"project {old_project}: duplicate milestone {old_milestone!r}; skipped")
                continue
            seen_milestones.add(old_milestone)
            new_milestone = target_id(conn, user_id, "milestone", f"{old_project}:{old_milestone}")
            completed = item.get("completed") is True
            completed_at = timestamp(item.get("completedAt"), imported_at, report, f"milestone {old_milestone}.completedAt") if completed else None
            created = timestamp(item.get("createdAt"), imported_at, report, f"milestone {old_milestone}.createdAt")
            updated = timestamp(item.get("updatedAt"), created, report, f"milestone {old_milestone}.updatedAt")
            conn.execute(
                """INSERT OR IGNORE INTO project_milestones
                 (id,project_id,title,due,completed,completed_at,position,created_at,updated_at,version)
                 VALUES (?,?,?,?,?,?,?,?,?,1)""",
                (new_milestone, new_project, text(item.get("title")) or "未命名里程碑",
                 nullable_date(item.get("due"), report, f"milestone {old_milestone}.due"), int(completed), completed_at,
                 position, created, updated),
            )
            report["counts"]["milestones"] += 1

    semester = document.get("semester") if isinstance(document.get("semester"), dict) else {}
    semester_start_raw = text(semester.get("startDate"))
    try:
        semester_start = datetime.strptime(semester_start_raw, "%Y-%m-%d").date()
    except ValueError:
        semester_start = None
    slots = {int(item.get("number")): (text(item.get("startTime")), text(item.get("endTime")))
             for item in array(document, "timeSlots") if str(item.get("number", "")).isdigit()}
    exceptions = array(document, "courseExceptions")
    holidays = {text(item.get("date")) for item in array(document, "calendarRules") if text(item.get("type")) == "holiday"}
    if semester_start is not None and slots:
        for index, course in enumerate(array(document, "courses")):
            course_id = source_id(course, f"course-{index}")
            weeks = course.get("weeks", [])
            if not isinstance(weeks, list):
                report["warnings"].append(f"course {course_id}: weeks is not an array; skipped")
                continue
            for week in weeks:
                if not isinstance(week, int) or not 1 <= week <= 60:
                    report["corrected"] += 1
                    continue
                day = course.get("day")
                if not isinstance(day, int) or not 1 <= day <= 7:
                    report["counts"]["skipped"] += 1
                    continue
                original_date = semester_start + timedelta(days=(week - 1) * 7 + day - 1)
                original = original_date.isoformat()
                exception = next((item for item in exceptions if text(item.get("courseId")) == course_id and text(item.get("date")) == original), None)
                if exception and text(exception.get("type")) == "cancel":
                    report["counts"]["skipped"] += 1
                    continue
                target = text(exception.get("targetDate")) if exception else ""
                target = target or original
                if target in holidays:
                    report["counts"]["skipped"] += 1
                    continue
                start_number = exception.get("startSection", course.get("startSection")) if exception else course.get("startSection")
                end_number = exception.get("endSection", course.get("endSection")) if exception else course.get("endSection")
                start = slots.get(start_number)
                end = slots.get(end_number)
                if not start or not end or not start[0] or not end[1]:
                    report["counts"]["skipped"] += 1
                    report["warnings"].append(f"course {course_id} {original}: missing time slot; skipped")
                    continue
                event_key = f"{course_id}:{original}"
                event_id = target_id(conn, user_id, "course_occurrence", event_key)
                description = " · ".join(filter(None, [text(course.get("code")), text(course.get("teacher")), text(course.get("notes"))])) or None
                location = " · ".join(filter(None, [text(course.get("campus")), text(course.get("location")), text(course.get("position"))])) or None
                conn.execute(
                    """INSERT OR IGNORE INTO calendar_events
                     (id,user_id,title,description,location,start_at,end_at,all_day,reminder_minutes,source,created_at,updated_at,version)
                     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1)""",
                    (event_id, user_id, text(course.get("name")) or "课程", description, location,
                     f"{target}T{start[0]}:00{offset}", f"{target}T{end[1]}:00{offset}", 0,
                     course.get("reminderMinutes") if isinstance(course.get("reminderMinutes"), int) else None,
                     "fangcun", imported_at, imported_at),
                )
                report["counts"]["calendarEvents"] += 1
    elif array(document, "courses"):
        report["counts"]["skipped"] += len(array(document, "courses"))
        report["warnings"].append("courses: semester.startDate or timeSlots missing; courses were not converted to calendar events")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Fangcun JSON document")
    parser.add_argument("--database", required=True, type=Path, help="Orialis SQLite database")
    parser.add_argument("--user-id", required=True, help="Existing Orialis user UUID")
    parser.add_argument("--timezone-offset", default="+08:00", help="Legacy course timezone, e.g. +08:00")
    parser.add_argument("--dry-run", action="store_true", help="Validate and report, then roll back")
    args = parser.parse_args()
    if not OFFSET_RE.fullmatch(args.timezone_offset):
        parser.error("--timezone-offset must look like +08:00")
    try:
        document = json.loads(args.input.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ImportFailure("top-level Fangcun document must be an object")
        conn = sqlite3.connect(args.database)
        conn.execute("PRAGMA foreign_keys=ON")
        if conn.execute("SELECT 1 FROM users WHERE id=?", (args.user_id,)).fetchone() is None:
            raise ImportFailure(f"Orialis user does not exist: {args.user_id}")
        conn.execute("BEGIN")
        report = import_document(conn, args.user_id, document, args.timezone_offset)
        batch_id = new_id()
        report["status"] = "dry_run" if args.dry_run else "completed"
        conn.execute(
            "INSERT INTO migration_batches(id,user_id,source,status,report_json) VALUES (?,?,?,?,?)",
            (batch_id, args.user_id, args.input.name, report["status"], json.dumps(report, ensure_ascii=False)),
        )
        if args.dry_run:
            conn.rollback()
        else:
            conn.commit()
        report["batchId"] = batch_id
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, sqlite3.Error, ImportFailure) as error:
        if "conn" in locals():
            conn.rollback()
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    finally:
        if "conn" in locals():
            conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
