import asyncio
import json
import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from .. import tools
from ..tools import (
    CAPABILITY_SCHEMA,
    DOMAIN_CONTRACTS,
    PLUGIN_OPERATIONS,
    _display_server_url,
    _http_capabilities_url,
    handle_capabilities,
    register_tools,
)


class CapabilityToolTests(unittest.TestCase):
    def test_domain_contract_metadata_does_not_create_task_or_schedule_tools(self):
        self.assertEqual(DOMAIN_CONTRACTS["task"]["domain"], "Task")
        self.assertEqual(DOMAIN_CONTRACTS["task"]["resource"], "/api/v1/tasks")
        self.assertEqual(DOMAIN_CONTRACTS["task"]["deleted_at_field"], "deletedAt")
        self.assertIn("important", DOMAIN_CONTRACTS["task"]["fields"])
        self.assertIn("recurrence", DOMAIN_CONTRACTS["task"]["nullable_fields"])
        self.assertFalse(DOMAIN_CONTRACTS["task"]["callable"])
        self.assertEqual(DOMAIN_CONTRACTS["schedule"]["domain"], "Schedule")
        self.assertEqual(
            DOMAIN_CONTRACTS["schedule"]["resource"],
            "/api/v1/schedules",
        )
        self.assertEqual(DOMAIN_CONTRACTS["schedule"]["compatibility_resource"], "/api/v1/calendar-events")
        self.assertEqual(DOMAIN_CONTRACTS["schedule"]["wire_entity_type"], "calendar_event")
        self.assertIn("deletedAt", DOMAIN_CONTRACTS["schedule"]["fields"])
        self.assertIn("location", DOMAIN_CONTRACTS["schedule"]["nullable_fields"])
        self.assertFalse(DOMAIN_CONTRACTS["schedule"]["callable"])
        self.assertEqual(
            {item["protocol"] for item in PLUGIN_OPERATIONS},
            {"message.send", "message.reply", "message.ack"},
        )

    def test_capability_url_is_derived_from_agent_gateway_url(self):
        self.assertEqual(
            _http_capabilities_url(
                "wss://orialis.example.test/api/v1/agent/ws"
            ),
            "https://orialis.example.test/api/v1/capabilities",
        )

    def test_capability_url_rejects_relative_urls(self):
        with self.assertRaisesRegex(ValueError, "absolute"):
            _http_capabilities_url("/api/v1/agent/ws")

    def test_display_url_drops_query_and_fragment(self):
        self.assertEqual(
            _display_server_url("wss://orialis.example.test/api/v1/agent/ws?token=secret#x"),
            "wss://orialis.example.test/api/v1/agent/ws",
        )

    def test_capabilities_tool_returns_server_payload_and_plugin_operations(self):
        with patch.dict(
            os.environ,
            {"ORIALIS_SERVER_URL": "wss://orialis.example.test/api/v1/agent/ws"},
            clear=False,
        ), patch.object(
            tools,
            "_fetch_server_capabilities",
            return_value={
                "ok": True,
                "payload": {"api_version": "v1", "capabilities": ["tasks", "messages"]},
            },
        ):
            result = json.loads(asyncio.run(tools.handle_capabilities({})))

        self.assertTrue(result["ok"])
        self.assertEqual(result["server"]["api_version"], "v1")
        self.assertEqual(result["server"]["capabilities"], ["tasks", "messages"])
        self.assertEqual(result["plugin"]["tools"], ["orialis_capabilities"])
        self.assertEqual(
            {item["name"] for item in result["plugin"]["operations"]},
            {"receive_message", "send_reply", "acknowledge_message"},
        )

    def test_capabilities_tool_degrades_when_server_is_unreachable(self):
        with patch.dict(
            os.environ,
            {"ORIALIS_SERVER_URL": "wss://orialis.example.test/api/v1/agent/ws"},
            clear=False,
        ), patch.object(
            tools,
            "_fetch_server_capabilities",
            return_value={"ok": False, "error": "offline"},
        ):
            result = json.loads(asyncio.run(tools.handle_capabilities({})))

        self.assertTrue(result["ok"])
        self.assertEqual(result["server"]["discovery"], {"ok": False, "error": "offline"})
        self.assertNotIn("capabilities", result["server"])

    def test_register_tools_uses_async_discovery_tool(self):
        calls = []
        register_tools(SimpleNamespace(register_tool=lambda **kwargs: calls.append(kwargs)))

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["name"], "orialis_capabilities")
        self.assertEqual(calls[0]["toolset"], "orialis")
        self.assertEqual(calls[0]["schema"], CAPABILITY_SCHEMA)
        self.assertTrue(calls[0]["is_async"])
