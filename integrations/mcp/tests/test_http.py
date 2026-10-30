"""Real HTTP OAuth and official MCP client acceptance; uses isolated Orialis API."""

import asyncio
import base64
import hashlib
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from orialis_mcp.config import Settings
from orialis_mcp.server import create_app
from test_live_api import call, free_port, live_api  # noqa: F401 (pytest fixture)


async def test_http_oauth_pkce_and_real_tools(live_api, tmp_path):
    api_url, _, (alice, _) = live_api
    port = free_port()
    origin = f"http://127.0.0.1:{port}"
    settings = Settings(api_url=api_url, public_url=origin, database_path=tmp_path / "oauth" / "mcp.sqlite", port=port)
    app = create_app(settings)
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error", access_log=False))
    running = asyncio.create_task(server.serve())
    try:
        for _ in range(100):
            if server.started:
                break
            if running.done():
                await running
            await asyncio.sleep(0.05)
        assert server.started
        async with httpx.AsyncClient(base_url=origin, trust_env=False, timeout=60) as browser:
            unauthorized = await browser.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
            assert unauthorized.status_code == 401
            assert "resource_metadata=" in unauthorized.headers["www-authenticate"]
            discovery = (await browser.get("/.well-known/oauth-protected-resource/mcp")).json()
            assert discovery["resource"] == origin + "/mcp"
            assert "orialis:write" in discovery["scopes_supported"]
            auth_metadata = (await browser.get("/.well-known/oauth-authorization-server")).json()
            assert "S256" in auth_metadata["code_challenge_methods_supported"]
            assert "none" in auth_metadata["token_endpoint_auth_methods_supported"]
            registered = await browser.post("/register", json={
                "client_name": "Generic MCP acceptance client", "redirect_uris": ["https://client.example.com/callback"],
                "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"], "scope": "orialis:read orialis:write orialis:memory:read orialis:memory:write",
            })
            assert registered.status_code == 201, registered.text
            client_id = registered.json()["client_id"]

            async def authorize(scope):
                verifier = "v" * 64
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
                authorized = await browser.get("/authorize", params={
                    "client_id": client_id, "redirect_uri": "https://client.example.com/callback",
                    "response_type": "code", "scope": scope, "state": "bound-state",
                    "code_challenge": challenge, "code_challenge_method": "S256", "resource": origin + "/mcp",
                })
                assert authorized.status_code == 302, authorized.text
                login_url = authorized.headers["location"]
                pending = parse_qs(urlsplit(login_url).query)["pending"][0]
                assert (await browser.get(login_url)).status_code == 200
                form = {"pending": pending, "session_token": alice["accessToken"], "consent": "allow"}
                assert (await browser.post("/login", data=form, headers={"Origin": "https://evil.example"})).status_code == 403
                logged_in = await browser.post("/login", data=form, headers={"Origin": origin})
                assert logged_in.status_code == 302, logged_in.text
                callback = parse_qs(urlsplit(logged_in.headers["location"]).query)
                assert callback["state"] == ["bound-state"] and callback["iss"] == [origin]
                exchange = {"grant_type": "authorization_code", "client_id": client_id, "code": callback["code"][0],
                            "redirect_uri": "https://client.example.com/callback", "code_verifier": verifier, "resource": origin + "/mcp"}
                bad_pkce = await browser.post("/token", data={**exchange, "code_verifier": "wrong"})
                assert bad_pkce.status_code == 400
                bad_resource = await browser.post("/token", data={**exchange, "resource": "https://foreign.example/mcp"})
                assert bad_resource.status_code == 400
                tokens = await browser.post("/token", data=exchange)
                assert tokens.status_code == 200, tokens.text
                assert (await browser.post("/token", data=exchange)).status_code == 400
                return tokens.json()

            tokens = await authorize("orialis:read orialis:write")
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + tokens["access_token"]}, trust_env=False) as http:
                async with streamable_http_client(origin + "/mcp", http_client=http) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        assert len((await session.list_tools()).tools) == 19
                        assert (await call(session, "get_profile", {}))["userId"] == alice["userId"]
                        task = await call(session, "create_task", {"data": {"title": "HTTP真实写入"}})
                        task = await call(session, "update_task", {"task_id": task["id"], "data": {"baseVersion": task["version"], "completed": True}})
                        assert task["completed"]
                        assert (await call(session, "list_tasks", {}))["items"][0]["id"] == task["id"]
            memory_tokens = await authorize("orialis:read orialis:memory:read orialis:memory:write")
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + memory_tokens["access_token"]}, trust_env=False) as http:
                async with streamable_http_client(origin + "/mcp", http_client=http) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        assert (await call(session, "list_screen_memories", {}))["items"] == []
                        assert (await session.call_tool("create_task", {"data": {"title": "memory scopes are not task write"}})).isError
            refresh = {"grant_type": "refresh_token", "client_id": client_id, "refresh_token": tokens["refresh_token"], "resource": origin + "/mcp"}
            rotated = await browser.post("/token", data=refresh)
            assert rotated.status_code == 200, rotated.text
            assert (await browser.post("/token", data=refresh)).status_code == 400
            old = await browser.post("/mcp", headers={"Authorization": "Bearer " + tokens["access_token"]}, json={})
            assert old.status_code == 401
            revoked = await browser.post("/revoke", data={"client_id": client_id, "token": rotated.json()["refresh_token"]})
            assert revoked.status_code == 200, revoked.text
            assert (await browser.post("/mcp", headers={"Authorization": "Bearer " + rotated.json()["access_token"]}, json={})).status_code == 401

            readonly = await authorize("orialis:read")
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + readonly["access_token"]}, trust_env=False) as http:
                async with streamable_http_client(origin + "/mcp", http_client=http) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        assert (await call(session, "get_profile", {}))["userId"] == alice["userId"]
                        denied = await session.call_tool("create_task", {"data": {"title": "denied"}})
                        assert denied.isError and "orialis:write" in str(denied.content)
    finally:
        server.should_exit = True
        await asyncio.wait_for(running, timeout=10)
