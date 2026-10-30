import json
from pathlib import Path

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import ValidationError

from orialis_mcp.config import Settings, validate_url
from orialis_mcp.models import EventUpdate, ProjectUpdate, TaskUpdate
from orialis_mcp.server import create_server
from orialis_mcp.tools import Gateway, item_path


def settings(**kwargs):
    return Settings(
        api_url="https://orialis.example.com", public_url="https://mcp.example.com",
        database_path=Path("unused.sqlite"), session_token="account-session",
        **kwargs,
    )


async def test_tool_schemas_and_upstream_contract():
    received = []

    def handler(request):
        received.append(request)
        if request.method == "DELETE":
            return httpx.Response(204)
        return httpx.Response(200, json={"id": "task-1", "version": 2})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:read", "orialis:write")), transport="stdio", client=client)
        tools = {t.name: t for t in await mcp.list_tools()}
        assert len(tools) == 19
        assert tools["list_tasks"].annotations.readOnlyHint
        assert tools["delete_project"].annotations.destructiveHint
        assert not tools["update_task"].annotations.readOnlyHint
        assert "base_version" not in tools["delete_project"].inputSchema["properties"]

        await mcp.call_tool("list_tasks", {"limit": 3, "after": "cursor+/?="})
        assert received[-1].url.params["after"] == "cursor+/?="
        await mcp.call_tool("update_task", {"task_id": "task-1", "data": {"baseVersion": 1, "notes": None, "completed": True}})
        assert json.loads(received[-1].content) == {"baseVersion": 1, "notes": None, "completed": True}
        assert received[-1].headers["authorization"] == "Session account-session"
        assert "title" not in json.loads(received[-1].content)
        await mcp.call_tool("create_project", {"data": {"name": "项目", "startDate": "2026-10-30"}})
        assert json.loads(received[-1].content)["startDate"] == "2026-10-30"
        await mcp.call_tool("list_calendar_events", {"from_time": "2026-10-30T00:00:00+08:00"})
        assert received[-1].url.params["from"] == "2026-10-30T00:00:00+08:00"
        await mcp.call_tool("delete_task", {"task_id": "task-1", "base_version": 2})
        assert json.loads(received[-1].content) == {"baseVersion": 2}
        await mcp.call_tool("delete_project", {"project_id": "project-1"})
        assert not received[-1].content


async def test_read_only_scope_blocks_every_write_before_network():
    def handler(request):
        pytest.fail("Unauthorized write reached API")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(), transport="stdio", client=client)
        for tool, arguments in [
            ("create_task", {"data": {"title": "no"}}),
            ("update_task", {"task_id": "id", "data": {"baseVersion": 1, "completed": True}}),
            ("delete_project", {"project_id": "id"}),
        ]:
            with pytest.raises(ToolError, match="orialis:write"):
                await mcp.call_tool(tool, arguments)


@pytest.mark.parametrize("status,message", [(409, "Version conflict"), (401, "reconnect"), (403, "reconnect"), (404, "not accessible"), (500, "HTTP 500"), (302, "HTTP 302")])
async def test_errors_never_leak_upstream_content(status, message):
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(status, text="private-token-and-data"))) as client:
        gateway = Gateway(settings(), client=client)
        with pytest.raises(ToolError, match=message) as error:
            await gateway.request("GET", "tasks")
        assert "private-token" not in str(error.value)


async def test_network_error_is_not_retried():
    attempts = 0

    def handler(request):
        nonlocal attempts
        attempts += 1
        raise httpx.ReadTimeout("secret request detail")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(ToolError, match="not automatically retried"):
            await Gateway(settings(scopes=("orialis:write",)), client=client).request("POST", "tasks", data={"title": "x"})
    assert attempts == 1


@pytest.mark.parametrize("value", ["..", "../auth", "x/y", "x?y", "%2e%2e", "x\\y", ""])
def test_ids_cannot_change_destination(value):
    with pytest.raises(ToolError):
        item_path("tasks", value)


def test_patch_contract_and_configuration():
    assert TaskUpdate(baseVersion=1, notes=None).model_dump(by_alias=True, exclude_unset=True) == {"baseVersion": 1, "notes": None}
    with pytest.raises(ValidationError):
        TaskUpdate(baseVersion=1, userId="other-user")
    with pytest.raises(ValidationError):
        TaskUpdate(baseVersion=0)
    for value in ["http://public.example", "https://x/path", "https://user:pass@x", "https://x?token=secret"]:
        with pytest.raises(ValueError):
            validate_url(value, "test")
    assert validate_url("http://127.0.0.1:1234", "test") == "http://127.0.0.1:1234"


@pytest.mark.parametrize("model,field", [(TaskUpdate, "title"), (TaskUpdate, "completed"), (ProjectUpdate, "name"), (ProjectUpdate, "status"), (EventUpdate, "title"), (EventUpdate, "startAt"), (EventUpdate, "endAt"), (EventUpdate, "allDay"), (EventUpdate, "important")])
def test_required_patch_fields_can_be_omitted_but_not_cleared(model, field):
    assert model(baseVersion=1).model_dump(by_alias=True, exclude_unset=True) == {"baseVersion": 1}
    with pytest.raises(ValidationError):
        model.model_validate({"baseVersion": 1, field: None})


async def test_schema_validation_limits_and_unknown_fields():
    mcp, _ = create_server(settings(), transport="stdio")
    for args in [{"limit": 101}, {"limit": 0}, {"limit": 3, "user_id": "another"}]:
        with pytest.raises(ToolError):
            await mcp.call_tool("list_tasks", args)


@pytest.mark.parametrize("description", [
    "【逐日摄影行程】\n11/4（周三）：09:49杭州南抵达→良渚古城。\n11/5（周四）：清晨西湖→中午校园参观。\n11/6（周五）：横一村→太子湾。",
    "11月4日：参观古城；11月5日：拍摄日出",
    "2026-11-04: 古城摄影\n2026-11-05: 校园参观",
    "上午：西湖摄影；下午：校园参观",
    "08:00 电路理论基础\n10:10 高等数学",
    "09:00—10:00 西湖摄影；12:00—14:00 校园参观",
])
@pytest.mark.parametrize("tool", ["create_calendar_event", "update_calendar_event"])
async def test_agendas_must_be_split_before_any_network_write(description, tool):
    def handler(request):
        pytest.fail("Merged itinerary reached API")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:read", "orialis:write")), transport="stdio", client=client)
        if tool == "create_calendar_event":
            arguments = {"data": {"title": "杭州摄影行", "description": description,
                "startAt": "2026-11-03T20:30:00+08:00", "endAt": "2026-11-09T05:36:00+08:00"}}
        else:
            arguments = {"event_id": "existing-event", "data": {"baseVersion": 1, "description": description}}
        with pytest.raises(ToolError, match="split_required"):
            await mcp.call_tool(tool, arguments)


async def test_single_overnight_train_and_plain_notes_are_preserved():
    received = []

    def handler(request):
        received.append(json.loads(request.content))
        return httpx.Response(200, json={"id": "night-train", "version": 1})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:read", "orialis:write")), transport="stdio", client=client)
        data = {"title": "D170 广州白云→杭州南", "description": "11/3 20:30 广州白云出发，11/4 09:49 杭州南抵达。家人接站。",
            "startAt": "2026-11-03T20:30:00+08:00", "endAt": "2026-11-04T09:49:00+08:00"}
        await mcp.call_tool("create_calendar_event", {"data": data})
        assert received == [data]
        await mcp.call_tool("update_calendar_event", {"event_id": "night-train", "data": {"baseVersion": 1, "description": None}})
        assert received[-1] == {"baseVersion": 1, "description": None}


async def test_splitting_rules_are_published_to_clients():
    mcp, _ = create_server(settings(), transport="stdio")
    tools = {tool.name: tool for tool in await mcp.list_tools()}
    assert "each date/time slot" in mcp.instructions
    for name in ("create_calendar_event", "update_calendar_event"):
        tool = tools[name]
        assert "same day" in tool.description
        assert "never invented" in tool.description
        fields = tool.inputSchema["$defs"]["EventCreate" if name == "create_calendar_event" else "EventUpdate"]["properties"]
        assert "separate events" in fields["description"]["description"]
