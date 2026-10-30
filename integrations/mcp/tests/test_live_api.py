"""Optional acceptance against a real Orialis binary and isolated SQLite database."""

import asyncio
import json
import os
import socket
import subprocess
import sys
from contextlib import asynccontextmanager

import httpx
import pytest
import pytest_asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest_asyncio.fixture
async def live_api(tmp_path):
    binary = os.environ.get("ORIALIS_TEST_SERVER_BINARY")
    if not binary:
        pytest.skip("Set ORIALIS_TEST_SERVER_BINARY to run real-backend acceptance")
    port = free_port()
    url = f"http://127.0.0.1:{port}"
    env = {**os.environ, "ORIALIS_HOST": "127.0.0.1", "ORIALIS_PORT": str(port),
           "ORIALIS_ENV": "production", "ORIALIS_DEV_DEVICE_AUTH": "false",
           "ORIALIS_DATABASE_URL": f"sqlite://{tmp_path / 'orialis.sqlite'}?mode=rwc",
           "ORIALIS_UPLOAD_DIR": str(tmp_path / "uploads"), "ORIALIS_PUBLIC_URL": url,
           "ORIALIS_AGENT_DEVICE_TOKEN": "", "ORIALIS_AGENT_USER_ID": ""}
    with open(tmp_path / "server.log", "w") as log:
        process = subprocess.Popen([binary], env=env, cwd=tmp_path, stdout=log, stderr=log)
        try:
            async with httpx.AsyncClient(base_url=url, timeout=60, trust_env=False) as client:
                for _ in range(100):
                    if process.poll() is not None:
                        raise RuntimeError("Test API exited before becoming ready")
                    try:
                        if (await client.get("/api/v1/health")).is_success:
                            break
                    except httpx.ConnectError:
                        pass
                    await asyncio.sleep(0.1)
                else:
                    raise RuntimeError("Test API did not become ready")
                accounts = []
                for name in ["mcp-test-alice", "mcp-test-bob"]:
                    response = await client.post("/api/v1/auth/register", json={"username": name, "password": "test-password-only-123"})
                    response.raise_for_status()
                    accounts.append(response.json())
                yield url, client, accounts
        finally:
            process.terminate()
            process.wait(timeout=10)


@asynccontextmanager
async def mcp_stdio(api_url, account, scopes="orialis:read orialis:write"):
    params = StdioServerParameters(
        command=sys.executable, args=["-m", "orialis_mcp.server", "--transport", "stdio"],
        env={**os.environ, "ORIALIS_API_URL": api_url,
             "ORIALIS_SESSION_TOKEN": account["accessToken"], "ORIALIS_MCP_SCOPES": scopes},
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session


async def call(session, name, arguments):
    result = await session.call_tool(name, arguments)
    assert not result.isError, result.content
    return result.structuredContent or json.loads(result.content[0].text)


async def test_real_stdio_write_read_conflict_isolation_and_revocation(live_api):
    url, api, (alice, bob) = live_api
    async with mcp_stdio(url, alice) as a, mcp_stdio(url, bob) as b:
        assert len((await a.list_tools()).tools) == 19
        assert (await call(a, "get_profile", {}))["userId"] == alice["userId"]
        project = await call(a, "create_project", {"data": {"name": "MCP验收", "goal": "读写闭环"}})
        task = await call(a, "create_task", {"data": {"title": "原始任务", "projectId": project["id"], "notes": "old"}})
        saved = await call(a, "update_task", {"task_id": task["id"], "data": {"baseVersion": task["version"], "title": "MCP已修改", "notes": None, "completed": True}})
        assert saved["title"] == "MCP已修改" and saved["completed"] and saved["notes"] is None
        tasks = await call(a, "list_tasks", {"limit": 1})
        assert tasks["items"][0]["id"] == task["id"]
        # Read back directly from the application API, independently of MCP serialization.
        response = await api.get("/api/v1/tasks", headers={"Authorization": f"Session {alice['accessToken']}"})
        assert response.json()["items"][0]["title"] == "MCP已修改"
        conflict = await a.call_tool("update_task", {"task_id": task["id"], "data": {"baseVersion": task["version"], "title": "stale"}})
        assert conflict.isError and "Version conflict" in str(conflict.content)
        assert not (await call(b, "list_tasks", {}))["items"]
        denied = await b.call_tool("update_task", {"task_id": task["id"], "data": {"baseVersion": saved["version"], "title": "foreign"}})
        assert denied.isError
        denied = await b.call_tool("delete_project", {"project_id": project["id"]})
        assert denied.isError
        event = await call(a, "create_calendar_event", {"data": {"title": "MCP日程", "startAt": "2026-10-30T10:00:00+08:00", "endAt": "2026-10-30T11:00:00+08:00"}})
        event = await call(a, "update_calendar_event", {"event_id": event["id"], "data": {"baseVersion": event["version"], "location": "图书馆"}})
        assert event["location"] == "图书馆"
        assert (await call(a, "list_calendar_events", {}))["items"][0]["id"] == event["id"]
        updated_project = await call(a, "update_project", {"project_id": project["id"], "data": {"baseVersion": project["version"], "description": "updated"}})
        assert updated_project["description"] == "updated"
        assert (await call(a, "get_project_summary", {"project_id": project["id"]}))["project"]["id"] == project["id"]
        await call(a, "delete_calendar_event", {"event_id": event["id"], "base_version": event["version"]})
        await call(a, "delete_task", {"task_id": task["id"], "base_version": saved["version"]})
        await call(a, "delete_project", {"project_id": project["id"]})
        assert not (await call(a, "list_tasks", {}))["items"]
        assert not (await call(a, "list_calendar_events", {}))["items"]
        assert not (await call(a, "list_projects", {}))["items"]
        await api.post("/api/v1/auth/logout", headers={"Authorization": f"Session {alice['accessToken']}"})
        assert (await a.call_tool("list_tasks", {})).isError


async def test_real_stdio_readonly_scope(live_api):
    url, _, (alice, _) = live_api
    async with mcp_stdio(url, alice, "orialis:read") as session:
        assert (await call(session, "get_profile", {}))["userId"] == alice["userId"]
        denied = await session.call_tool("create_task", {"data": {"title": "should not exist"}})
        assert denied.isError
        assert not (await call(session, "list_tasks", {}))["items"]
