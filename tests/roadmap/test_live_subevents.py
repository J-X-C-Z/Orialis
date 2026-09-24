from __future__ import annotations

import unittest

from .support import LiveServerMixin, json_request, session_headers, unique_id


class LiveSubeventContractTests(LiveServerMixin, unittest.TestCase):
    """Black-box coverage for child tasks and Schedule importance."""

    def setUp(self) -> None:
        self.token, _ = self.shared_session()
        self.headers = session_headers(self.token)

    def create_task(self, title: str, **fields):
        result = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": title, **fields},
            headers=self.headers,
        )
        self.assertEqual(result.status, 201, result.body)
        return result.json()

    def create_schedule(self, title: str, **fields):
        result = json_request(
            "POST",
            "/api/v1/schedules",
            {
                "title": title,
                "startAt": "2026-10-01T09:00:00+08:00",
                "endAt": "2026-10-01T10:00:00+08:00",
                **fields,
            },
            headers=self.headers,
        )
        self.assertEqual(result.status, 201, result.body)
        return result.json()

    def test_child_task_crud_and_task_association(self) -> None:
        parent = self.create_task("Roadmap parent", due="2026-10-10", important=True)
        child = self.create_task(
            "Roadmap child",
            parentTaskId=parent["id"],
            due="2026-10-11",
            important=False,
            urgent=True,
        )
        self.assertEqual(child["parentTaskId"], parent["id"])
        self.assertIsNone(child["scheduleId"])
        self.assertEqual(child["due"], "2026-10-11")
        self.assertFalse(child["important"])
        self.assertTrue(child["urgent"])

        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        listed = {task["id"]: task for task in page.json()["items"]}
        self.assertEqual(listed[child["id"]]["parentTaskId"], parent["id"])

        changed = json_request(
            "PATCH",
            f"/api/v1/tasks/{child['id']}",
            {"notes": "changed independently", "completed": True, "baseVersion": child["version"]},
            headers=self.headers,
        )
        self.assertEqual(changed.status, 200, changed.body)
        child = changed.json()
        self.assertEqual(child["parentTaskId"], parent["id"])
        self.assertTrue(child["completed"])

        # Completing a parent completes its direct children. Reopening a child
        # reopens the parent, while reopening the parent alone leaves children
        # complete.
        sibling = self.create_task("Uncompleted child", parentTaskId=parent["id"])
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        parent = next(task for task in page.json()["items"] if task["id"] == parent["id"])
        completed_parent = json_request(
            "PATCH",
            f"/api/v1/tasks/{parent['id']}",
            {"completed": True, "baseVersion": parent["version"]},
            headers=self.headers,
        )
        self.assertEqual(completed_parent.status, 200, completed_parent.body)
        parent = completed_parent.json()
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        tasks = {task["id"]: task for task in page.json()["items"]}
        child = tasks[child["id"]]
        self.assertTrue(tasks[child["id"]]["completed"])
        self.assertTrue(tasks[sibling["id"]]["completed"])

        reopened_child = json_request(
            "PATCH",
            f"/api/v1/tasks/{sibling['id']}",
            {"completed": False, "baseVersion": tasks[sibling["id"]]["version"]},
            headers=self.headers,
        )
        self.assertEqual(reopened_child.status, 200, reopened_child.body)
        self.assertFalse(reopened_child.json()["completed"])
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        tasks = {task["id"]: task for task in page.json()["items"]}
        self.assertFalse(tasks[parent["id"]]["completed"])

        completed_sibling = json_request(
            "PATCH",
            f"/api/v1/tasks/{sibling['id']}",
            {"completed": True, "baseVersion": reopened_child.json()["version"]},
            headers=self.headers,
        )
        self.assertEqual(completed_sibling.status, 200, completed_sibling.body)
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        tasks = {task["id"]: task for task in page.json()["items"]}
        self.assertTrue(tasks[parent["id"]]["completed"])

        reopened_parent = json_request(
            "PATCH",
            f"/api/v1/tasks/{parent['id']}",
            {"completed": False, "baseVersion": tasks[parent["id"]]["version"]},
            headers=self.headers,
        )
        self.assertEqual(reopened_parent.status, 200, reopened_parent.body)
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        tasks = {task["id"]: task for task in page.json()["items"]}
        self.assertFalse(tasks[parent["id"]]["completed"])
        self.assertTrue(tasks[child["id"]]["completed"])
        self.assertTrue(tasks[sibling["id"]]["completed"])

        deleted = json_request(
            "DELETE",
            f"/api/v1/tasks/{child['id']}",
            {"baseVersion": child["version"]},
            headers=self.headers,
        )
        self.assertEqual(deleted.status, 204, deleted.body)
        remaining = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(remaining.status, 200, remaining.body)
        self.assertNotIn(child["id"], {task["id"] for task in remaining.json()["items"]})

    def test_creating_incomplete_child_reopens_completed_parent(self) -> None:
        parent = self.create_task("Completed before child exists", completed=True)
        self.assertTrue(parent["completed"])

        child = self.create_task("New incomplete child", parentTaskId=parent["id"])
        self.assertFalse(child["completed"])
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        tasks = {task["id"]: task for task in page.json()["items"]}
        self.assertFalse(
            tasks[parent["id"]]["completed"],
            "creating an incomplete child must reopen its completed parent",
        )

    def test_deleting_parent_task_soft_deletes_direct_children(self) -> None:
        parent = self.create_task("Cascade delete parent")
        children = [
            self.create_task(f"Cascade delete child {index}", parentTaskId=parent["id"])
            for index in range(2)
        ]
        before = json_request("GET", "/api/v1/sync/events", headers=self.headers)
        self.assertEqual(before.status, 200, before.body)
        deleted = json_request(
            "DELETE",
            f"/api/v1/tasks/{parent['id']}",
            {"baseVersion": parent["version"]},
            headers=self.headers,
        )
        self.assertEqual(deleted.status, 204, deleted.body)
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        remaining_ids = {task["id"] for task in page.json()["items"]}
        self.assertNotIn(parent["id"], remaining_ids)
        for child in children:
            self.assertNotIn(child["id"], remaining_ids)
        events = json_request(
            "GET",
            f"/api/v1/sync/events?after={before.json()['nextCursor']}",
            headers=self.headers,
        )
        self.assertEqual(events.status, 200, events.body)
        tombstones = {event["entityId"]: event for event in events.json()["events"]}
        self.assertIn(parent["id"], tombstones)
        self.assertEqual(tombstones[parent["id"]]["operation"], "delete")
        self.assertTrue(tombstones[parent["id"]]["tombstone"])
        for child in children:
            self.assertIn(child["id"], tombstones)
            self.assertEqual(tombstones[child["id"]]["operation"], "delete")
            self.assertTrue(tombstones[child["id"]]["tombstone"])

    def test_schedule_child_and_important_round_trip_with_legacy_default(self) -> None:
        legacy = self.create_schedule("Legacy schedule without importance")
        self.assertIs(legacy["important"], False)

        schedule = self.create_schedule("Important schedule", important=True)
        self.assertIs(schedule["important"], True)
        child = self.create_task("Scheduled child", scheduleId=schedule["id"])
        self.assertEqual(child["scheduleId"], schedule["id"])
        self.assertIsNone(child["parentTaskId"])

        # An older client's patch has no `important` key and must preserve the value.
        changed = json_request(
            "PATCH",
            f"/api/v1/calendar-events/{schedule['id']}",
            {"title": "Renamed important schedule", "baseVersion": schedule["version"]},
            headers=self.headers,
        )
        self.assertEqual(changed.status, 200, changed.body)
        self.assertIs(changed.json()["important"], True)

        cleared = json_request(
            "PATCH",
            f"/api/v1/calendar-events/{schedule['id']}",
            {"important": False, "baseVersion": changed.json()["version"]},
            headers=self.headers,
        )
        self.assertEqual(cleared.status, 200, cleared.body)
        self.assertIs(cleared.json()["important"], False)

        deleted = json_request(
            "DELETE",
            f"/api/v1/calendar-events/{schedule['id']}",
            {"baseVersion": cleared.json()["version"]},
            headers=self.headers,
        )
        self.assertEqual(deleted.status, 204, deleted.body)
        events = json_request("GET", "/api/v1/sync/events", headers=self.headers)
        self.assertEqual(events.status, 200, events.body)
        child_tombstones = [
            event
            for event in events.json()["events"]
            if event["entityId"] == child["id"] and event["operation"] == "delete"
        ]
        self.assertTrue(child_tombstones)
        self.assertTrue(child_tombstones[-1]["tombstone"])
        page = json_request("GET", "/api/v1/tasks", headers=self.headers)
        self.assertEqual(page.status, 200, page.body)
        self.assertNotIn(child["id"], {task["id"] for task in page.json()["items"]})

    def test_omitted_and_explicit_null_task_relations_have_patch_semantics(self) -> None:
        parent = self.create_task("Patch parent")
        child = self.create_task("Patch child", parentTaskId=parent["id"])

        omitted = json_request(
            "PATCH",
            f"/api/v1/tasks/{child['id']}",
            {"notes": "keep relation", "baseVersion": child["version"]},
            headers=self.headers,
        )
        self.assertEqual(omitted.status, 200, omitted.body)
        self.assertEqual(omitted.json()["parentTaskId"], parent["id"])

        cleared = json_request(
            "PATCH",
            f"/api/v1/tasks/{child['id']}",
            {"parentTaskId": None, "baseVersion": omitted.json()["version"]},
            headers=self.headers,
        )
        self.assertEqual(cleared.status, 200, cleared.body)
        self.assertIsNone(cleared.json()["parentTaskId"])

    def test_snake_case_relation_aliases_are_accepted_but_responses_stay_camel_case(self) -> None:
        first_parent = self.create_task("Camel response parent one")
        second_parent = self.create_task("Camel response parent two")
        created = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Snake input child", "parent_task_id": first_parent["id"]},
            headers=self.headers,
        )
        self.assertEqual(created.status, 201, created.body)
        child = created.json()
        self.assertEqual(child["parentTaskId"], first_parent["id"])
        self.assertIsNone(child["scheduleId"])
        self.assertNotIn("parent_task_id", child)
        self.assertNotIn("schedule_id", child)

        moved = json_request(
            "PATCH",
            f"/api/v1/tasks/{child['id']}",
            {"parent_task_id": second_parent["id"], "baseVersion": child["version"]},
            headers=self.headers,
        )
        self.assertEqual(moved.status, 200, moved.body)
        child = moved.json()
        self.assertEqual(child["parentTaskId"], second_parent["id"])
        self.assertNotIn("parent_task_id", child)

        schedule = self.create_schedule("Snake alias schedule")
        scheduled = json_request(
            "PATCH",
            f"/api/v1/tasks/{child['id']}",
            {"parent_task_id": None, "schedule_id": schedule["id"], "baseVersion": child["version"]},
            headers=self.headers,
        )
        self.assertEqual(scheduled.status, 200, scheduled.body)
        child = scheduled.json()
        self.assertIsNone(child["parentTaskId"])
        self.assertEqual(child["scheduleId"], schedule["id"])
        self.assertNotIn("schedule_id", child)

        created_schedule_child = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Snake create schedule child", "schedule_id": schedule["id"]},
            headers=self.headers,
        )
        self.assertEqual(created_schedule_child.status, 201, created_schedule_child.body)
        created_child = created_schedule_child.json()
        self.assertEqual(created_child["scheduleId"], schedule["id"])
        self.assertNotIn("schedule_id", created_child)

    def test_rejects_self_nesting_cross_user_and_dual_association(self) -> None:
        root = self.create_task("Validation root")
        child = self.create_task("Validation child", parentTaskId=root["id"])

        self_reference = json_request(
            "PATCH",
            f"/api/v1/tasks/{root['id']}",
            {"parentTaskId": root["id"], "baseVersion": root["version"]},
            headers=self.headers,
        )
        self.assertEqual(self_reference.status, 400, self_reference.body)

        nested = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Nested grandchild", "parentTaskId": child["id"]},
            headers=self.headers,
        )
        self.assertEqual(nested.status, 400, nested.body)

        schedule = self.create_schedule("Dual association schedule")
        dual = json_request(
            "POST",
            "/api/v1/tasks",
            {
                "title": "Two parents",
                "parentTaskId": root["id"],
                "scheduleId": schedule["id"],
            },
            headers=self.headers,
        )
        self.assertEqual(dual.status, 400, dual.body)

        other_username = unique_id("rs")
        other = json_request(
            "POST",
            "/api/v1/auth/register",
            {"username": other_username, "password": f"Roadmap-{unique_id('pw')}"},
        )
        self.assertEqual(other.status, 201, other.body)
        other_token = other.json()["accessToken"]
        other_headers = session_headers(other_token)
        other_parent = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Other user's task"},
            headers=other_headers,
        )
        self.assertEqual(other_parent.status, 201, other_parent.body)
        other_schedule = json_request(
            "POST",
            "/api/v1/schedules",
            {
                "title": "Other user's schedule",
                "startAt": "2026-10-02T09:00:00+08:00",
                "endAt": "2026-10-02T10:00:00+08:00",
            },
            headers=other_headers,
        )
        self.assertEqual(other_schedule.status, 201, other_schedule.body)
        foreign_parent = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Foreign task child", "parentTaskId": other_parent.json()["id"]},
            headers=self.headers,
        )
        self.assertIn(foreign_parent.status, (400, 404), foreign_parent.body)
        foreign_schedule = json_request(
            "POST",
            "/api/v1/tasks",
            {"title": "Foreign schedule child", "scheduleId": other_schedule.json()["id"]},
            headers=self.headers,
        )
        self.assertIn(foreign_schedule.status, (400, 404), foreign_schedule.body)
