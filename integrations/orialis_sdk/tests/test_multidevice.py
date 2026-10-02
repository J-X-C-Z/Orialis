import json
import unittest
from pathlib import Path

from integrations.orialis_sdk import ContractError, MultiDeviceClient, MultiDeviceMcpAdapter


FIXTURES = Path(__file__).with_name("fixtures")


class FixtureTransport:
    """Isolated local fixture transport; it never calls an Orialis service."""

    def __init__(self):
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path == "/api/v1/capabilities":
            return {"capabilities": ["multidevice.v1"]}
        if path.startswith("/api/v1/nodes?") or path == "/api/v1/nodes":
            return json.loads((FIXTURES / "nodes-list-v1.json").read_text())
        if method == "DELETE" and path == "/api/v1/nodes/device_A":
            result = json.loads((FIXTURES / "device-v1.json").read_text())
            result["status"] = "revoked"
            result["revocationVersion"] += 1
            return result
        if path == "/api/v1/nodes/device_A":
            return json.loads((FIXTURES / "device-v1.json").read_text())
        if path.endswith("/capabilities"):
            if path.endswith("/device_A/capabilities"):
                return json.loads((FIXTURES / "capabilities-v1.json").read_text())
            if path.endswith("/device_B/capabilities"):
                return json.loads((FIXTURES / "capabilities-device-b-v1.json").read_text())
        raise AssertionError(f"unexpected fixture route: {method} {path}")


class MultiDeviceClientTests(unittest.TestCase):
    def setUp(self):
        self.transport = FixtureTransport()
        self.client = MultiDeviceClient(self.transport)

    def test_device_selection_is_explicit_and_path_segment_is_escaped(self):
        with self.assertRaises(ContractError):
            self.client.get_device("")
        with self.assertRaises(ContractError):
            self.client.get_device("../device_A")
        # Even unusual opaque IDs cannot escape the selected resource segment.
        escaped_transport = FixtureTransport()
        def escaped_call(method, path, body=None):
            escaped_transport.calls.append((method, path, body))
            if path == "/api/v1/capabilities":
                return {"capabilities": ["multidevice.v1"]}
            return {"protocolVersion": "1", "deviceId": "device/B"}
        escaped_client = MultiDeviceClient(escaped_call)
        escaped_client.get_device("device/B")
        self.assertEqual(escaped_transport.calls[-1][1], "/api/v1/nodes/device%2FB")
        self.assertEqual(self.client.get_device("device_A")["deviceId"], "device_A")
        self.assertEqual(self.transport.calls[-1][1], "/api/v1/nodes/device_A")

    def test_list_uses_opaque_cursor_and_routes_to_contract_path(self):
        self.client.list_devices(cursor="opaque+/cursor")
        self.assertEqual(
            self.transport.calls[-1][1], "/api/v1/nodes?cursor=opaque%2B%2Fcursor"
        )

    def test_list_and_events_reject_non_string_next_cursor(self):
        for response in (
            {"protocolVersion": "1", "nodes": [], "nextCursor": 42},
            {"protocolVersion": "1", "events": [], "nextCursor": {"cursor": "x"}},
        ):
            def transport(method, path, body=None, value=response):
                if path == "/api/v1/capabilities":
                    return {"capabilities": ["multidevice.v1"]}
                return value
            client = MultiDeviceClient(transport)
            with self.subTest(response=response), self.assertRaises(ContractError):
                (client.list_devices() if "nodes" in response else client.events())

    def test_confirm_pairing_rejects_unsupported_protocol_version(self):
        def transport(method, path, body=None):
            if path == "/api/v1/capabilities":
                return {"capabilities": ["multidevice.v1"]}
            return {"protocolVersion": "2", "pairingId": "pair-1", "status": "confirmed"}
        client = MultiDeviceClient(transport)
        with self.assertRaises(ContractError):
            client.confirm_pairing("pair-1", "123456", "confirm")

    def test_capability_must_be_available_and_explicitly_allowed(self):
        caps = self.client.get_capabilities("device_A")["capabilities"]
        self.assertEqual(self.client.require_capability(caps, "files.read")["grant"], "allow")
        for grant in ("deny", "ask", "unconfigured", None):
            altered = [dict(caps[0], grant=grant)]
            with self.subTest(grant=grant), self.assertRaises(ContractError):
                self.client.require_capability(altered, "files.read")
        with self.assertRaises(ContractError):
            self.client.require_capability([dict(caps[0], available=False)], "files.read")

    def test_capabilities_remain_bound_when_alternating_devices(self):
        a = self.client.get_capabilities("device_A")
        b = self.client.get_capabilities("device_B")
        a_again = self.client.get_capabilities("device_A")
        self.assertEqual(a["deviceId"], "device_A")
        self.assertEqual(b["deviceId"], "device_B")
        self.assertEqual(a_again["deviceId"], "device_A")
        self.assertEqual(a["capabilities"][0]["grant"], "allow")
        self.assertEqual(b["capabilities"][0]["grant"], "deny")
        with self.assertRaises(ContractError):
            self.client.require_capability(b["capabilities"], "files.read")

    def test_capabilities_fail_closed_on_missing_or_mismatched_device_binding(self):
        for response in (
            {"protocolVersion": "1", "capabilities": [{"name": "files.read", "available": True, "grant": "allow"}]},
            {"protocolVersion": "1", "deviceId": "device_B", "capabilities": [{"name": "files.read", "available": True, "grant": "allow"}]},
        ):
            client = MultiDeviceClient(lambda *_args, value=response: value)
            with self.subTest(response=response), self.assertRaises(ContractError):
                client.get_capabilities("device_A")

    def test_get_device_fails_closed_on_mismatched_device_binding(self):
        client = MultiDeviceClient(lambda *_args: {"protocolVersion": "1", "deviceId": "device_B"})
        with self.assertRaises(ContractError):
            client.get_device("device_A")

    def test_mcp_adapter_only_exposes_contract_read_methods(self):
        adapter = MultiDeviceMcpAdapter(self.client)
        self.assertEqual(
            [tool.name for tool in adapter.tools],
            ["devices.list", "devices.get", "capabilities.get"],
        )
        self.assertEqual(adapter.call("devices.get", {"deviceId": "device_A"})["deviceId"], "device_A")
        with self.assertRaises(ContractError):
            adapter.call("agents.run", {"deviceId": "device_A"})

    def test_revoke_uses_authorized_node_route(self):
        result = self.client.revoke_device("device_A")
        self.assertEqual(result["deviceId"], "device_A")
        self.assertEqual(result["status"], "revoked")
        self.assertEqual(self.transport.calls[-1][0:2], ("DELETE", "/api/v1/nodes/device_A"))

    def test_revoke_fails_when_server_does_not_return_revoked_device(self):
        def transport(method, path, body=None):
            if path == "/api/v1/capabilities":
                return {"capabilities": ["multidevice.v1"]}
            return {"protocolVersion": "1", "deviceId": "device_A", "status": "online",
                    "revocationVersion": 0}
        client = MultiDeviceClient(transport)
        with self.assertRaises(ContractError):
            client.revoke_device("device_A")


if __name__ == "__main__":
    unittest.main()
