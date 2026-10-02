"""Client primitives for the proposed multidevice-v1 Node/Control contract.

Callers may inject transport/auth details or use the SDK's HTTP transport and
CLI. Node requests fail closed unless the service advertises multidevice.v1.
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
    """Node v1 SDK over an injected transport; HTTP credentials remain host-owned."""

    protocol_version = "1"

    def __init__(self, transport: Transport, *, base_path: str = "/api/v1") -> None:
        if not callable(transport):
            raise TypeError("transport must be callable")
        self._transport = transport
        self._base_path = "/" + base_path.strip("/")
        self._server_support_checked = False

    def _request(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        if path != "/capabilities" and (path.startswith("/nodes") or path.startswith("/events")):
            if not self._server_support_checked:
                self.require_server_support()
                self._server_support_checked = True
        return self._transport(method, f"{self._base_path}{path}", body)

    def require_server_support(self) -> Mapping[str, Any]:
        """Require advertised multidevice.v1 before calling Node routes."""
        result = _object(self._request("GET", "/capabilities"), "capabilities")
        raw = result.get("capabilities", result.get("items", []))
        if not isinstance(raw, list):
            raise ContractError("server capabilities response has no capability list")
        for capability in raw:
            if capability == "multidevice.v1":
                self._server_support_checked = True
                return {"name": "multidevice.v1", "available": True}
            if isinstance(capability, Mapping) and capability.get("name") == "multidevice.v1":
                if capability.get("available") is True:
                    self._server_support_checked = True
                    return capability
                break
        raise ContractError("server does not advertise available multidevice.v1")

    def start_pairing(self, identity: Mapping[str, Any]) -> Mapping[str, Any]:
        _validate_identity(identity)
        body = {"nodeIdentity": dict(identity), "protocolVersion": self.protocol_version}
        result = _object(self._request("POST", "/nodes/pairings", body), "pairings.start")
        _require_fields(result, ("pairingId", "pairingSecret", "confirmationCode", "targetNode", "expiresAt"), "pairings.start")
        if result.get("protocolVersion") != self.protocol_version:
            raise ContractError("pairings.start returned an unsupported protocolVersion")
        if not isinstance(result.get("pairingSecret"), str) or not 32 <= len(result["pairingSecret"]) <= 512:
            raise ContractError("pairings.start returned an invalid pairingSecret")
        if not isinstance(result.get("confirmationCode"), str) or len(result["confirmationCode"]) != 6 or not result["confirmationCode"].isdigit():
            raise ContractError("pairings.start returned an invalid confirmationCode")
        if result.get("targetNode") != dict(identity):
            raise ContractError("pairings.start target identity differs from this node")
        return result

    def confirm_pairing(self, pairing_id: str, confirmation_code: str, decision: str) -> Mapping[str, Any]:
        if decision not in {"confirm", "reject"}:
            raise ContractError("pairing decision must be confirm or reject")
        if not isinstance(confirmation_code, str) or len(confirmation_code) != 6 or not confirmation_code.isdigit():
            raise ContractError("confirmation code must be six digits")
        result = _object(
            self._request("POST", f"/nodes/pairings/{_segment(pairing_id)}/confirm", {
                "confirmationCode": confirmation_code, "decision": decision,
            }), "pairings.confirm",
        )
        if (result.get("protocolVersion") != self.protocol_version
                or result.get("pairingId") != pairing_id
                or result.get("status") != ("confirmed" if decision == "confirm" else "rejected")):
            raise ContractError("pairings.confirm response does not match requested transition")
        return result

    def complete_pairing(self, pairing_id: str, secret: str, identity: Mapping[str, Any]) -> Mapping[str, Any]:
        _validate_identity(identity)
        if not isinstance(secret, str) or not 32 <= len(secret) <= 512:
            raise ContractError("pairingSecret must be between 32 and 512 characters")
        result = _object(self._request(
            "POST", f"/nodes/pairings/{_segment(pairing_id)}/complete", {
                "pairingSecret": secret, "nodeIdentity": dict(identity),
            }), "pairings.complete")
        _require_fields(result, ("deviceId", "deviceCredential", "accountId"), "pairings.complete")
        if result.get("protocolVersion") != self.protocol_version:
            raise ContractError("pairings.complete returned an unsupported protocolVersion")
        if not isinstance(result.get("deviceCredential"), str) or not 32 <= len(result["deviceCredential"]) <= 512:
            raise ContractError("pairings.complete returned an invalid deviceCredential")
        return result

    def heartbeat(self, device_id: str) -> Mapping[str, Any]:
        result = _object(self._request("POST", self._device_path(device_id, "/heartbeat"), {}), "nodes.heartbeat")
        if result.get("deviceId") != device_id or result.get("protocolVersion") != self.protocol_version:
            raise ContractError("heartbeat response identity or protocolVersion does not match this node")
        return result

    def events(self, *, after: str | None = None, limit: int | None = None) -> Mapping[str, Any]:
        from urllib.parse import urlencode
        _validate_limit(limit)
        params = {}
        if after is not None:
            params["after"] = after
        if limit is not None:
            params["limit"] = limit
        query = "" if not params else "?" + urlencode(params)
        result = _object(self._request("GET", "/events" + query), "events.list")
        if (result.get("protocolVersion") != self.protocol_version
                or not isinstance(result.get("events"), list)
                or not _valid_cursor(result.get("nextCursor"))):
            raise ContractError("events.list response does not match the v1 envelope")
        return result

    @staticmethod
    def _device_path(device_id: str, suffix: str = "") -> str:
        if not isinstance(device_id, str) or not device_id.strip():
            raise ContractError("deviceId is required")
        if any(part in {".", ".."} for part in device_id.replace("\\", "/").split("/")):
            raise ContractError("deviceId cannot contain dot path segments")
        # Opaque IDs occupy exactly one path segment. Quoting prevents path injection.
        return f"/nodes/{quote(device_id, safe='')}{suffix}"

    def list_devices(self, *, cursor: str | None = None, limit: int | None = None) -> Mapping[str, Any]:
        # Cursor syntax is opaque; encode it as a query parameter without interpretation.
        from urllib.parse import urlencode
        _validate_limit(limit)

        params = {}
        if cursor is not None:
            params["cursor"] = cursor
        if limit is not None:
            params["limit"] = limit
        query = "" if not params else "?" + urlencode(params)
        result = _object(self._request("GET", "/nodes" + query), "devices.list")
        if (result.get("protocolVersion") != self.protocol_version
                or not isinstance(result.get("nodes"), list)
                or not _valid_cursor(result.get("nextCursor"))):
            raise ContractError("devices.list response does not match the v1 envelope")
        return result

    def get_device(self, device_id: str) -> Mapping[str, Any]:
        result = _object(self._request("GET", self._device_path(device_id)), "devices.get")
        if result.get("deviceId") != device_id or result.get("protocolVersion") != self.protocol_version:
            raise ContractError("devices.get response deviceId does not match requested deviceId")
        return result

    def get_capabilities(self, device_id: str) -> Mapping[str, Any]:
        result = _object(
            self._request("GET", self._device_path(device_id, "/capabilities")),
            "capabilities.get",
        )
        if result.get("deviceId") != device_id or result.get("protocolVersion") != self.protocol_version or not isinstance(result.get("capabilities"), list):
            raise ContractError(
                "capabilities.get response deviceId is missing or does not match requested deviceId"
            )
        return result

    def revoke_device(self, device_id: str) -> Mapping[str, Any]:
        result = _object(self._request("DELETE", self._device_path(device_id)), "devices.revoke")
        version = result.get("revocationVersion")
        if (result.get("deviceId") != device_id
                or result.get("protocolVersion") != self.protocol_version
                or result.get("status") != "revoked"
                or isinstance(version, bool)
                or not isinstance(version, int)
                or version < 1):
            raise ContractError("devices.revoke response does not show a valid revoked Device")
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


def _segment(value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError("identifier is required")
    if any(part in {".", ".."} for part in value.replace("\\", "/").split("/")):
        raise ContractError("identifier cannot contain dot path segments")
    return quote(value, safe="")


def _require_fields(value: Mapping[str, Any], fields: tuple[str, ...], label: str) -> None:
    missing = [field for field in fields if not value.get(field)]
    if missing:
        raise ContractError(f"{label} response is missing required fields: {', '.join(missing)}")


def _validate_identity(identity: Mapping[str, Any]) -> None:
    if set(identity) != {"displayName", "platform", "nodeVersion"}:
        raise ContractError("node identity must contain only displayName, platform, and nodeVersion")
    for key, max_length in (("displayName", 128), ("platform", 64), ("nodeVersion", 64)):
        value = identity.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > max_length:
            raise ContractError(f"node identity {key} is required and must be at most {max_length} characters")


def _validate_limit(limit: int | None) -> None:
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100):
        raise ContractError("limit must be an integer between 1 and 100")


def _valid_cursor(value: Any) -> bool:
    return value is None or isinstance(value, str)


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
