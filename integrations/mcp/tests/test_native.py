import asyncio

import httpx
import pytest
from mcp.server.auth.provider import RegistrationError
from mcp.shared.auth import OAuthClientInformationFull
from starlette.applications import Starlette

from orialis_mcp.native import routes
from test_auth import env, consent, make_client  # noqa: F401


def native_client():
    return OAuthClientInformationFull(
        client_id="native-test", client_name="Orialis 手机或桌面客户端",
        redirect_uris=["http://127.0.0.1:4321/callback"],
        token_endpoint_auth_method="none", scope="orialis:session",
    )


async def native_tokens(provider, browser, client):
    from test_auth import AuthorizationParams, CHALLENGE, REDIRECT, PUBLIC
    from urllib.parse import parse_qs, urlsplit
    url = await provider.authorize(client, AuthorizationParams(
        state="native-state", scopes=["orialis:session"], code_challenge=CHALLENGE,
        redirect_uri=REDIRECT, redirect_uri_provided_explicitly=True, resource=provider.resource,
    ))
    await browser.get(url)
    pending = parse_qs(urlsplit(url).query)["pending"][0]
    response = await browser.post("/login", data={"pending": pending, "consent": "allow", "session_token": "pasted-session"}, headers={"Origin": PUBLIC})
    assert response.status_code == 302
    code = parse_qs(urlsplit(response.headers["location"]).query)["code"][0]
    code = await provider.load_authorization_code(client, code)
    return await provider.exchange_authorization_code(client, code)


async def test_native_session_single_use_and_identity(env):
    provider, browser, _, _ = env
    client = native_client()
    await provider.register_client(client)
    token = await native_tokens(provider, browser, client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(Starlette(routes=routes(provider))), base_url="https://gateway.test") as app:
        headers = {"Authorization": "Bearer " + token.access_token}
        responses = await asyncio.gather(*(app.get("/api/v1/auth/native/session", headers=headers) for _ in range(2)))
        assert sorted(r.status_code for r in responses) == [200, 401]
        result = next(r for r in responses if r.status_code == 200)
        assert result.json()["userId"] == "user-1" and result.json()["username"] == "alice"
        assert result.json()["accessToken"] == "pasted-session"
        assert result.headers["cache-control"] == "no-store"
        assert await provider.load_access_token(token.access_token) is None
        assert await provider.load_refresh_token(client, token.refresh_token) is None


async def test_mcp_token_cannot_export_user_session(env):
    provider, browser, _, _ = env
    client = make_client()
    await provider.register_client(client)
    code, _ = await consent(provider, browser, client)
    token = await provider.exchange_authorization_code(client, code)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(Starlette(routes=routes(provider))), base_url="https://gateway.test") as app:
        r = await app.get("/api/v1/auth/native/session", headers={"Authorization": "Bearer " + token.access_token})
        assert r.status_code == 401 and "pasted-session" not in r.text
    assert await provider.load_access_token(token.access_token) is not None


@pytest.mark.parametrize("changes", [
    {"redirect_uris": ["https://evil.example/callback"]},
    {"redirect_uris": ["http://localhost:4321/callback"]},
    {"redirect_uris": ["http://127.0.0.1:4321/other"]},
    {"scope": "orialis:session orialis:read"},
    {"scope": "orialis:session orialis:memory:read"},
    {"scope": "orialis:session orialis:memory:write"},
    {"token_endpoint_auth_method": "client_secret_post", "client_secret": "secret"},
])
async def test_native_scope_restricts_registration(env, changes):
    with pytest.raises(RegistrationError):
        await env[0].register_client(native_client().model_copy(update=changes))
