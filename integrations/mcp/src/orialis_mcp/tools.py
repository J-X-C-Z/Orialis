"""Tools call the existing user-scoped API, including its sync and conflict checks."""

from typing import Annotated, Literal
from urllib.parse import quote

import httpx
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import Field

from .config import Settings
from .models import EventCreate, EventUpdate, ProjectCreate, ProjectUpdate, TaskCreate, TaskUpdate, MemoryUpdate
from .schedule_policy import EVENT_GRANULARITY_RULES
from .memory_policy import MEMORY_RULES

READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
CREATE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
UPDATE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
DELETE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False)
Limit = Annotated[int, Field(ge=1, le=100)]
Version = Annotated[int, Field(ge=1)]


class Gateway:
    def __init__(self, settings: Settings, provider=None, client: httpx.AsyncClient | None = None):
        self.settings = settings
        self.provider = provider
        self.client = client

    async def request(self, method: str, path: str, *, params=None, data=None, required_scope=None):
        required = required_scope or ("orialis:read" if method == "GET" else "orialis:write")
        required = (required,) if isinstance(required, str) else required

        def require(scopes):
            missing = set(required) - set(scopes)
            if missing:
                raise ToolError("Missing permission: " + ", ".join(sorted(missing)))
        if self.provider is None:
            require(self.settings.scopes)
            session = self.settings.session_token
        else:
            access = get_access_token()
            require(access.scopes if access is not None else ())
            session = await self.provider.session_for_token(access.token)
        if not session:
            raise ToolError("Orialis account is disconnected; reconnect your account")
        headers = {"Authorization": f"Session {session}"}
        url = self.settings.api_url.rstrip("/") + "/api/v1/" + path
        params = {k: v for k, v in (params or {}).items() if v is not None}
        try:
            if self.client is not None:
                response = await self.client.request(method, url, headers=headers, params=params, json=data)
            else:
                async with httpx.AsyncClient(timeout=20, follow_redirects=False, trust_env=False) as client:
                    response = await client.request(method, url, headers=headers, params=params, json=data)
        except httpx.HTTPError:
            raise ToolError("Orialis could not be reached; the operation was not automatically retried") from None
        if response.status_code == 409:
            raise ToolError("Version conflict: re-read the item, review current values, and retry with its latest version")
        if response.status_code in {401, 403}:
            raise ToolError("Orialis authorization expired or was denied; reconnect your account")
        if response.status_code == 404:
            raise ToolError("Item does not exist or is not accessible to this account")
        if not 200 <= response.status_code < 300:
            # Upstream bodies can contain account data; do not include them in diagnostics.
            raise ToolError(f"Orialis rejected the operation (HTTP {response.status_code}); check field values")
        if response.status_code == 204:
            return {"deleted": True}
        try:
            return response.json()
        except ValueError:
            raise ToolError("Orialis returned an invalid response") from None


def item_path(collection: str, item_id: str) -> str:
    if not item_id or item_id in {".", ".."} or any(c in item_id for c in "/\\?#%"):
        raise ToolError("Invalid item ID")
    return collection + "/" + quote(item_id, safe="")


def memory_view(result: dict, include_source: bool = False) -> dict:
    fields = {"id", "createdAt", "sourcePackage", "sourceLabel", "urls", "title", "summary",
              "notes", "category", "sourceUrl", "videoStatus", "videoSummary", "videoError",
              "version", "updatedAt"}
    if include_source:
        fields.update({"visibleText", "sharedText"})
    return {key: value for key, value in result.items() if key in fields}


def register_tools(mcp: FastMCP, gateway: Gateway):
    @mcp.tool(annotations=READ)
    async def get_profile() -> dict:
        """Identify the connected Orialis account. All tools use this account only."""
        return await gateway.request("GET", "auth/session")

    @mcp.tool(annotations=READ)
    async def list_tasks(limit: Limit = 50, after: str | None = None) -> dict:
        """Read tasks with versions. Follow nextCursor while hasMore is true; a page is not the full task list."""
        return await gateway.request("GET", "tasks", params={"limit": limit, "after": after})

    @mcp.tool(annotations=CREATE)
    async def create_task(data: TaskCreate) -> dict:
        """Create a task. Dates are YYYY-MM-DD; dueTime is HH:MM. Returns the saved task and version."""
        return await gateway.request("POST", "tasks", data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=UPDATE)
    async def update_task(task_id: str, data: TaskUpdate) -> dict:
        """Change only supplied fields using baseVersion from the latest read. null clears nullable fields."""
        return await gateway.request("PATCH", item_path("tasks", task_id), data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=DELETE)
    async def delete_task(task_id: str, base_version: Version) -> dict:
        """Delete a task at its current version. Use only when the user requests deletion."""
        return await gateway.request("DELETE", item_path("tasks", task_id), data={"baseVersion": base_version})

    @mcp.tool(annotations=READ)
    async def list_projects(limit: Limit = 50, after: str | None = None, status: Literal["active", "completed", "archived"] | None = None) -> dict:
        """Read projects with versions and pagination. Optionally filter by status."""
        return await gateway.request("GET", "projects", params={"limit": limit, "after": after, "status": status})

    @mcp.tool(annotations=READ)
    async def get_project_summary(project_id: str) -> dict:
        """Read a project's details, progress, task/milestone counts, and next action."""
        return await gateway.request("GET", item_path("projects", project_id) + "/summary")

    @mcp.tool(annotations=CREATE)
    async def create_project(data: ProjectCreate) -> dict:
        """Create a project. status is active, completed, or archived; dates are YYYY-MM-DD."""
        return await gateway.request("POST", "projects", data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=UPDATE)
    async def update_project(project_id: str, data: ProjectUpdate) -> dict:
        """Change supplied project fields using its latest baseVersion. null clears nullable fields."""
        return await gateway.request("PATCH", item_path("projects", project_id), data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=DELETE)
    async def delete_project(project_id: str) -> dict:
        """Delete a project AND its milestones. The upstream API has no version guard for this operation. Use only when the user explicitly requests deletion."""
        return await gateway.request("DELETE", item_path("projects", project_id))

    @mcp.tool(annotations=READ)
    async def list_calendar_events(limit: Limit = 50, after: str | None = None, from_time: str | None = None, to_time: str | None = None) -> dict:
        """Read calendar events. Optional from_time (inclusive) and to_time (exclusive) are RFC 3339 timestamps with offsets. Follow nextCursor."""
        return await gateway.request("GET", "calendar-events", params={"limit": limit, "after": after, "from": from_time, "to": to_time})

    @mcp.tool(annotations=CREATE, description="Create one calendar event with timezone-aware startAt/endAt. " + EVENT_GRANULARITY_RULES)
    async def create_calendar_event(data: EventCreate) -> dict:
        """Create one activity; see the published tool description for splitting rules."""
        return await gateway.request("POST", "calendar-events", data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=UPDATE, description="Change supplied event fields at the latest baseVersion; null clears nullable fields. " + EVENT_GRANULARITY_RULES)
    async def update_calendar_event(event_id: str, data: EventUpdate) -> dict:
        """Change one activity; see the published tool description for splitting rules."""
        return await gateway.request("PATCH", item_path("calendar-events", event_id), data=data.model_dump(by_alias=True, exclude_unset=True))

    @mcp.tool(annotations=DELETE)
    async def delete_calendar_event(event_id: str, base_version: Version) -> dict:
        """Delete an event at its current version. Use only when the user requests deletion."""
        return await gateway.request("DELETE", item_path("calendar-events", event_id), data={"baseVersion": base_version})


    @mcp.tool(annotations=READ)
    async def get_usage_guidelines() -> dict:
        """Read Orialis usage rules before planning writes or accessing screen memories. Contains no personal data."""
        return {"screenMemory": MEMORY_RULES, "calendar": EVENT_GRANULARITY_RULES,
                "writes": "Read current versions, change only user-requested fields, and verify by reading back. Never automatically retry creates.",
                "memoryScopes": ["orialis:memory:read", "orialis:memory:write"]}

    @mcp.tool(annotations=READ)
    async def list_screen_memories(query: Annotated[str | None, Field(max_length=500)] = None,
                                   limit: Limit = 20, after: str | None = None) -> dict:
        """Search synced screen-memory text and return short previews, IDs, capture dates and versions. Requires memory:read. Follow nextCursor; unsynced device records are absent. Read get_usage_guidelines first. Use get_screen_memory for details."""
        if query is not None and len(query.encode("utf-8")) > 1000:
            raise ToolError("Memory query must not exceed 1000 UTF-8 bytes")
        return await gateway.request("GET", "memories", params={"query": query, "limit": limit, "after": after},
                                     required_scope="orialis:memory:read")

    @mcp.tool(annotations=READ, description="Read a screen memory by exact ID with its current version. Raw captured text is excluded unless include_source=true is necessary. Images are not returned. " + MEMORY_RULES)
    async def get_screen_memory(memory_id: str, include_source: bool = False) -> dict:
        result = await gateway.request("GET", item_path("memories", memory_id), required_scope="orialis:memory:read")
        return memory_view(result, include_source)

    @mcp.tool(annotations=UPDATE, description="Update only title, summary, notes or category of an existing screen memory with latest baseVersion and changeReason. Requires memory:read and memory:write. Original capture and source are immutable; no creation or deletion. " + MEMORY_RULES)
    async def update_screen_memory(memory_id: str, data: MemoryUpdate) -> dict:
        payload = data.model_dump(by_alias=True, exclude_unset=True)
        if not set(payload) & {"title", "summary", "notes", "category"}:
            raise ToolError("Supply at least one editable memory field")
        result = await gateway.request("PATCH", item_path("memories", memory_id), data=payload,
                                       required_scope=("orialis:memory:read", "orialis:memory:write"))
        return memory_view(result)

    @mcp.tool(annotations=READ)
    async def get_screen_memory_history(memory_id: str, limit: Limit = 20) -> dict:
        """Read screen-memory modification history: version, actor source, reason, changed fields and time. Requires memory:read. Does not expose historical raw capture. Use to verify updates."""
        return await gateway.request("GET", item_path("memories", memory_id) + "/history",
                                     params={"limit": limit}, required_scope="orialis:memory:read")
