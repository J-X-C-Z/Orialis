"""Client primitives for the frozen multidevice-v1 Node/Control contract.

This module intentionally has no implicit network or authentication behavior.
Callers inject a transport that owns session credentials and HTTP details.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Mapping
from urllib.parse import quote


class ContractError(RuntimeError):
    """A local contract or capability check failed before transport dispatch."""


class CapabilityDecision(str, Enum):
    ALLOW = "allow"
    DENY = "deny"
    ASK = "ask"
    UNCONFIGURED = "unconfigured"


Transport = Callable[[str, str, Mapping[str, Any] | None], Any]


def _object(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ContractError(f"{label} response must be an object")
    return value


class MultiDeviceClient:
    """Read-only Node v1 SDK over an injected (method, path, body) transport."""

    protocol_version = "1"

    def __init__(self, transport: Transport, *, base_path: str = "/api/v1") -> None:
        if not callable(transport):
            raise TypeError("transport must be callable")
        self._transport = transport
        self._base_path = "/" + base_path.strip("/")

    def _request(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        return self._transport(method, f"{self._base_path}{path}", body)

    @staticmethod
    def _device_path(device_id: str, suffix: str = "") -> str:
        if not isinstance(device_id, str) or not device_id.strip():
            raise ContractError("deviceId is required")
        if any(part in {".", ".."} for part in device_id.replace("\\", "/").split("/")):
            raise ContractError("deviceId cannot contain dot path segments")
        # Opaque IDs occupy exactly one path segment. Quoting prevents path injection.
        return f"/nodes/{quote(device_id, safe='')}{suffix}"

    def list_devices(self, *, cursor: str | None = None) -> Mapping[str, Any]:
        # Cursor syntax is opaque; encode it as a query parameter without interpretation.
        from urllib.parse import urlencode

        query = "" if cursor is None else "?" + urlencode({"cursor": cursor})
        return _object(self._request("GET", "/nodes" + query), "devices.list")

    def get_device(self, device_id: str) -> Mapping[str, Any]:
        result = _object(self._request("GET", self._device_path(device_id)), "devices.get")
        if result.get("deviceId") != device_id:
            raise ContractError("devices.get response deviceId does not match requested deviceId")
        return result

    def get_capabilities(self, device_id: str) -> Mapping[str, Any]:
        result = _object(
            self._request("GET", self._device_path(device_id, "/capabilities")),
            "capabilities.get",
        )
        return result

    def revoke_device(self, device_id: str) -> Mapping[str, Any]:
        result = _object(
            self._request("DELETE", self._device_path(device_id)), "devices.revoke"
        )
        return result

    @staticmethod
    def require_capability(
        capabilities: list[Mapping[str, Any]], name: str
    ) -> Mapping[str, Any]:
        """Require available capability and explicit allow grant; deny/ask fail closed."""
        for capability in capabilities:
            if capability.get("name") != name:
                continue
            if capability.get("available") is not True:
                raise ContractError(f"capability {name} is unavailable")
            decision = capability.get("grant", CapabilityDecision.UNCONFIGURED.value)
            if decision != CapabilityDecision.ALLOW.value:
                raise ContractError(f"capability {name} is not explicitly allowed ({decision})")
            return capability
        raise ContractError(f"capability {name} was not advertised")


@dataclass(frozen=True)
class McpTool:
    name: str
    description: str
    input_schema: Mapping[str, Any]


class MultiDeviceMcpAdapter:
    """MCP-neutral registry/dispatcher; a host maps these declarations to MCP."""

    tools = (
        McpTool("devices.list", "List nodes available to the authenticated account.", {
            "type": "object", "properties": {"cursor": {"type": "string"}},
            "additionalProperties": False,
        }),
        McpTool("devices.get", "Read one explicitly selected node.", {
            "type": "object", "properties": {"deviceId": {"type": "string", "minLength": 1}},
            "required": ["deviceId"], "additionalProperties": False,
        }),
        McpTool("capabilities.get", "Read capabilities for one explicitly selected node.", {
            "type": "object", "properties": {"deviceId": {"type": "string", "minLength": 1}},
            "required": ["deviceId"], "additionalProperties": False,
        }),
    )

    def __init__(self, client: MultiDeviceClient) -> None:
        self._client = client

    def call(self, name: str, arguments: Mapping[str, Any]) -> Mapping[str, Any]:
        if name == "devices.list":
            return self._client.list_devices(cursor=arguments.get("cursor"))
        if name == "devices.get":
            return self._client.get_device(arguments.get("deviceId"))
        if name == "capabilities.get":
            return self._client.get_capabilities(arguments.get("deviceId"))
        raise ContractError(f"unsupported MCP tool: {name}")
