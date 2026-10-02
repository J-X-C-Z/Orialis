import asyncio
import json
import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from .. import tools


class ToolTests(unittest.TestCase):
    def test_all_domain_contracts_are_callable_and_registered(self):
        expected = {
            "task", "project", "milestone", "schedule", "conversation", "message"
        }
        self.assertEqual(set(tools.DOMAIN_CONTRACTS), expected)
        calls = []
        tools.register_tools(SimpleNamespace(register_tool=lambda **kw: calls.append(kw)))
        names = {call["name"] for call in calls}
        self.assertEqual(names, set(tools.TOOL_NAMES))
        self.assertEqual(len(calls), len(tools.TOOL_NAMES))
        self.assertTrue(all(call["is_async"] for call in calls))

    def test_urls_use_server_origin_and_exact_routes(self):
        self.assertEqual(
            tools._http_schedules_url("wss://example.test/api/v1/agent/ws"),
            "https://example.test/api/v1/schedules",
        )
        self.assertEqual(
            tools._http_url("ws://example.test/api/v1/agent/ws", "/api/v1/tasks", {"limit": 10}),
            "http://example.test/api/v1/tasks?limit=10",
        )
        with self.assertRaises(ValueError):
            tools._http_url("/relative", "/api/v1/tasks")

    def test_patch_and_delete_require_base_version(self):
        with patch.dict(os.environ, {"ORIALIS_SERVER_URL": "https://example.test", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_request") as request:
            result = json.loads(asyncio.run(tools.HANDLERS["update_task"][1]({"id": "t1", "title": "x"})))
        self.assertFalse(result["ok"])
        self.assertIn("baseVersion", result["error"])
        request.assert_not_called()

    def test_dynamic_resource_path_and_bearer_auth(self):
        response = {"ok": True, "status": 200, "data": {"id": "p1"}}
        with patch.dict(os.environ, {"ORIALIS_SERVER_URL": "wss://example.test/api/v1/agent/ws", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_request", return_value=response) as request:
            result = json.loads(asyncio.run(tools.HANDLERS["update_project"][1]({"id": "p1", "name": "Roadmap", "baseVersion": 2})))
        self.assertTrue(result["ok"])
        request.assert_called_once()
        self.assertEqual(request.call_args.args[2:4], ("PATCH", "/api/v1/projects/p1"))
        self.assertEqual(request.call_args.kwargs["payload"], {"name": "Roadmap", "baseVersion": 2})

    def test_creation_preserves_caller_ids_and_task_project(self):
        cases = (
            ("create_task", {"id": "t1", "title": "Task", "projectId": "p1"}, "/api/v1/tasks"),
            ("create_project", {"id": "p1", "name": "Project"}, "/api/v1/projects"),
            ("create_conversation", {"id": "c1", "title": "Chat"}, "/api/v1/conversations"),
            ("create_message", {"id": "m1", "conversationId": "c1", "content": "Hello"}, "/api/v1/conversations/c1/messages"),
        )
        for name, arguments, path in cases:
            with self.subTest(tool=name), patch.dict(os.environ, {"ORIALIS_SERVER_URL": "https://example.test", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_request", return_value={"ok": True, "data": {}}) as request:
                result = json.loads(asyncio.run(tools.HANDLERS[name][1](arguments)))
                self.assertTrue(result["ok"])
                self.assertEqual(request.call_args.args[3], path)
                expected = {key: value for key, value in arguments.items() if key != "conversationId"}
                self.assertEqual(request.call_args.kwargs["payload"], expected)

    def test_task_patch_preserves_project_assignment_and_clear(self):
        for project_id in ("p1", None):
            with self.subTest(project=project_id), patch.dict(os.environ, {"ORIALIS_SERVER_URL": "https://example.test", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_request", return_value={"ok": True, "data": {}}) as request:
                result = json.loads(asyncio.run(tools.HANDLERS["update_task"][1]({"id": "t1", "projectId": project_id, "baseVersion": 1})))
                self.assertTrue(result["ok"])
                self.assertEqual(request.call_args.kwargs["payload"], {"projectId": project_id, "baseVersion": 1})

    def test_resource_paths_escape_ids_and_reject_missing_ids(self):
        with patch.dict(os.environ, {"ORIALIS_SERVER_URL": "https://example.test", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_request", return_value={"ok": True, "data": {}}) as request:
            asyncio.run(tools.HANDLERS["get_project_summary"][1]({"id": "p/1?filter=x"}))
            self.assertEqual(request.call_args.args[3], "/api/v1/projects/p%2F1%3Ffilter%3Dx/summary")
            request.reset_mock()
            result = json.loads(asyncio.run(tools.HANDLERS["get_project_summary"][1]({})))
            self.assertFalse(result["ok"])
            request.assert_not_called()

    def test_schedule_validation_happens_before_http(self):
        with patch.dict(os.environ, {"ORIALIS_SERVER_URL": "https://example.test", "ORIALIS_DEVICE_TOKEN": "secret"}, clear=True), patch.object(tools, "_post_schedule") as post:
            result = json.loads(asyncio.run(tools.handle_create_schedule({"title": "x", "startAt": "2026-01-01T10:00:00", "endAt": "2026-01-01T11:00:00+00:00"})))
        self.assertFalse(result["ok"])
        self.assertIn("timezone", result["error"])
        post.assert_not_called()

    def test_capabilities_exposes_every_tool(self):
        with patch.dict(os.environ, {"ORIALIS_SERVER_URL": "wss://example.test/api/v1/agent/ws"}, clear=True), patch.object(tools, "_fetch_server_capabilities", return_value={"ok": True, "payload": {"api_version": "v1", "capabilities": ["tasks"]}}):
            result = json.loads(asyncio.run(tools.handle_capabilities({})))
        self.assertEqual(result["server"]["api_version"], "v1")
        self.assertEqual(set(result["plugin"]["tools"]), set(tools.TOOL_NAMES))


if __name__ == "__main__":
    unittest.main()
