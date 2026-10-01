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
        if path.startswith("/api/v1/nodes?") or path == "/api/v1/nodes":
            return json.loads((FIXTURES / "nodes-list-v1.json").read_text())
        if method == "DELETE":
            return {"deviceId": "device_A", "status": "revoked", "revocationVersion": 2}
        if path == "/api/v1/nodes/device_A":
            return json.loads((FIXTURES / "device-v1.json").read_text())
        if path.endswith("/capabilities"):
            return json.loads((FIXTURES / "capabilities-v1.json").read_text())
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
        escaped_client = MultiDeviceClient(
            lambda method, path, body=None: (
                escaped_transport.calls.append((method, path, body))
                or {"deviceId": "device/B"}
            )
        )
        escaped_client.get_device("device/B")
        self.assertEqual(escaped_transport.calls[-1][1], "/api/v1/nodes/device%2FB")
        self.assertEqual(self.client.get_device("device_A")["deviceId"], "device_A")
        self.assertEqual(self.transport.calls[-1][1], "/api/v1/nodes/device_A")

    def test_list_uses_opaque_cursor_and_routes_to_contract_path(self):
        self.client.list_devices(cursor="opaque+/cursor")
        self.assertEqual(
            self.transport.calls[-1][1], "/api/v1/nodes?cursor=opaque%2B%2Fcursor"
        )

    def test_capability_must_be_available_and_explicitly_allowed(self):
        caps = self.client.get_capabilities("device_A")["capabilities"]
        self.assertEqual(self.client.require_capability(caps, "files.read")["grant"], "allow")
        for grant in ("deny", "ask", "unconfigured", None):
            altered = [dict(caps[0], grant=grant)]
            with self.subTest(grant=grant), self.assertRaises(ContractError):
                self.client.require_capability(altered, "files.read")
        with self.assertRaises(ContractError):
            self.client.require_capability([dict(caps[0], available=False)], "files.read")

    def test_mcp_adapter_only_exposes_contract_read_methods(self):
        adapter = MultiDeviceMcpAdapter(self.client)
        self.assertEqual(
            [tool.name for tool in adapter.tools],
            ["devices.list", "devices.get", "capabilities.get"],
        )
        self.assertEqual(adapter.call("devices.get", {"deviceId": "device_A"})["deviceId"], "device_A")
        with self.assertRaises(ContractError):
            adapter.call("agents.run", {"deviceId": "device_A"})

    def test_revoke_targets_only_explicit_device(self):
        result = self.client.revoke_device("device_A")
        self.assertEqual(result["status"], "revoked")
        self.assertEqual(self.transport.calls[-1][:2], ("DELETE", "/api/v1/nodes/device_A"))


if __name__ == "__main__":
    unittest.main()
