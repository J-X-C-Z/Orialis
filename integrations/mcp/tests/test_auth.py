"""Provider backing-store tests plus real SDK OAuth routes (upstream HTTP mocked)."""
import asyncio
import base64
from hashlib import sha256
import sqlite3
from html.parser import HTMLParser
import time
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
import pytest_asyncio
from mcp.server.auth.provider import AuthorizationParams, AuthorizeError, RegistrationError, TokenError
from mcp.server.auth.routes import create_auth_routes
from mcp.server.auth.settings import ClientRegistrationOptions, RevocationOptions
from mcp.shared.auth import OAuthClientInformationFull
from pydantic import AnyHttpUrl
from starlette.applications import Starlette

from orialis_mcp.auth import Provider
from orialis_mcp.oauth_compat import routes as compat_routes
from orialis_mcp.server import create_app
from orialis_mcp.config import Settings

pytestmark = pytest.mark.asyncio
PUBLIC = "https://gateway.test"
RESOURCE = PUBLIC + "/mcp"
REDIRECT = "http://127.0.0.1:4321/callback"
VERIFIER = "v" * 64
CHALLENGE = base64.urlsafe_b64encode(sha256(VERIFIER.encode()).digest()).decode().rstrip("=")


class LoginHTML(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.elements = []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


@pytest_asyncio.fixture
async def env(tmp_path):
    calls = []
    state = {"fail": False}

    def upstream(request):
        calls.append(request)
        if state["fail"]:
            return httpx.Response(401, json={"secret": "MUST-NOT-LEAK"})
        assert str(request.url) == "http://orialis.test/api/v1/auth/session"
        assert request.method == "GET"
        assert request.headers["authorization"] == "Session pasted-session"
        return httpx.Response(200, json={"userId": "user-1", "username": "alice"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(upstream)) as client:
        provider = Provider("http://orialis.test", PUBLIC, tmp_path / "private" / "nested" / "oauth.db", client)
        routes = create_auth_routes(provider, AnyHttpUrl(PUBLIC),
            client_registration_options=ClientRegistrationOptions(enabled=True,
                valid_scopes=["orialis:read", "orialis:write"], default_scopes=["orialis:read"]),
            revocation_options=RevocationOptions(enabled=True))
        app = Starlette(routes=compat_routes(provider) + routes + provider.routes())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url=PUBLIC) as browser:
            yield provider, browser, state, calls


def make_client(id="public", **changes):
    data = dict(client_id=id, redirect_uris=[REDIRECT], token_endpoint_auth_method="none",
                scope="orialis:read orialis:write", client_name='<img src=x onerror="alert(1)">')
    data.update(changes)
    return OAuthClientInformationFull(**data)


async def start(provider, browser, client, *, scopes=None, resource=None):
    params = AuthorizationParams(state="state-1", scopes=scopes or ["orialis:read", "orialis:write"],
        code_challenge=CHALLENGE, redirect_uri=REDIRECT,
        redirect_uri_provided_explicitly=True, resource=resource)
    url = await provider.authorize(client, params)
    page = await browser.get(url)
    assert page.status_code == 200
    return parse_qs(urlsplit(url).query)["pending"][0], page


async def consent(provider, browser, client):
    pending, _ = await start(provider, browser, client)
    data = {"pending": pending, "consent": "allow", "session_token": "pasted-session"}
    response = await browser.post("/login", data=data, headers={"Origin": PUBLIC})
    assert response.status_code == 302, response.text
    query = parse_qs(urlsplit(response.headers["location"]).query)
    assert query["state"] == ["state-1"]
    assert query["iss"] == [PUBLIC]
    code = await provider.load_authorization_code(client, query["code"][0])
    assert code is not None
    return code, pending


async def test_lifecycle_persistence_rotation_and_revoke(env):
    provider, browser, state, _ = env
    client = make_client()
    await provider.register_client(client)
    before = int(time.time())
    code, pending = await consent(provider, browser, client)
    assert await provider.load_authorization_code(make_client("other"), code.code) is None
    other = Provider(provider.api_url, PUBLIC, provider.database_path, provider.http_client)
    assert (await other.get_client(client.client_id)) == client
    assert (await other.load_authorization_code(client, code.code)) == code
    tokens = await other.exchange_authorization_code(client, code)
    assert tokens.expires_in == 3600
    access = await provider.load_access_token(tokens.access_token)
    assert access.resource == RESOURCE and access.subject == "user-1"
    assert await provider.session_for_token(tokens.access_token) == "pasted-session"
    assert await provider.load_authorization_code(client, code.code) is None
    with pytest.raises(TokenError):
        await provider.exchange_authorization_code(client, code)
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    assert before + 86400 <= refresh.expires_at <= int(time.time()) + 86400
    assert await provider.load_refresh_token(make_client("other"), tokens.refresh_token) is None
    with pytest.raises(TokenError):
        await provider.exchange_refresh_token(make_client("other"), refresh, refresh.scopes)
    with pytest.raises(TokenError, match="invalid_scope"):
        await provider.exchange_refresh_token(client, refresh, ["admin"])
    rotated = await provider.exchange_refresh_token(client, refresh, ["orialis:read"])
    assert rotated.access_token != tokens.access_token and rotated.refresh_token != tokens.refresh_token
    assert rotated.scope == "orialis:read"
    assert await provider.load_access_token(tokens.access_token) is None
    assert await provider.load_refresh_token(client, tokens.refresh_token) is None
    with pytest.raises(TokenError):
        await provider.session_for_token(tokens.access_token)
    with pytest.raises(TokenError):
        await provider.exchange_refresh_token(client, refresh, refresh.scopes)
    # A previously loaded token still revokes its entire family after rotation.
    await provider.revoke_token(access)
    assert await provider.load_access_token(rotated.access_token) is None
    assert await provider.load_refresh_token(client, rotated.refresh_token) is None
    await provider.revoke_token(access)
    assert (await browser.get("/login", params={"pending": pending})).status_code == 400
    raw = provider.database_path.read_bytes()
    for secret in [code.code, tokens.access_token, tokens.refresh_token, rotated.access_token, "password-secret"]:
        assert secret.encode() not in raw
    assert provider.database_path.stat().st_mode & 0o777 == 0o600
    assert provider.database_path.parent.stat().st_mode & 0o777 == 0o700
    assert provider.database_path.parent.parent.stat().st_mode & 0o777 == 0o700


async def test_existing_directory_permissions_unchanged(tmp_path):
    tmp_path.chmod(0o755)
    db = tmp_path / "state.db"
    db.touch(mode=0o644)
    Provider("http://localhost:9000", PUBLIC, db)
    assert tmp_path.stat().st_mode & 0o777 == 0o755
    assert db.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("uri", ["http://evil.test/cb", "javascript:alert(1)",
    "https://user:secret@evil.test/cb", "https://evil.test/cb#fragment"])
async def test_unsafe_redirects(env, uri):
    with pytest.raises(RegistrationError):
        await env[0].register_client(make_client(redirect_uris=[uri]))


async def test_authorization_boundaries(env):
    provider, browser, _, _ = env
    client = make_client()
    await provider.register_client(client)
    params = AuthorizationParams(state=None, scopes=["orialis:read"], code_challenge=CHALLENGE,
        redirect_uri=REDIRECT, redirect_uri_provided_explicitly=True)
    for updates in [{"resource": "https://evil.test/mcp"}, {"resource": ""},
                    {"scopes": ["admin"]}, {"code_challenge": ""},
                    {"redirect_uri": "https://evil.test/callback"}]:
        with pytest.raises(AuthorizeError):
            await provider.authorize(client, params.model_copy(update=updates))
    with pytest.raises(AuthorizeError):
        await provider.authorize(make_client("missing"), params)
    pending, _ = await start(provider, browser, client, resource=RESOURCE)
    with sqlite3.connect(provider.database_path) as db:
        db.execute("UPDATE pending SET expires=0")
    assert (await browser.get("/login", params={"pending": pending})).status_code == 400


async def test_login_consent_csrf_errors_and_escaping(env):
    provider, browser, state, calls = env
    client = make_client()
    await provider.register_client(client)
    pending, page = await start(provider, browser, client)
    assert "<img" not in page.text and "&lt;img" in page.text
    assert "orialis:read" in page.text and "orialis:write" in page.text
    csrf_cookie = next(c for c in page.headers.get_list("set-cookie") if c.startswith("orialis_consent="))
    assert "HttpOnly" in csrf_cookie and "SameSite=strict" in csrf_cookie
    assert "Secure" in csrf_cookie
    data = {"pending": pending, "consent": "allow", "session_token": "pasted-session"}
    for headers in [{}, {"Origin": "https://evil.test"}, {"Origin": "null"}]:
        assert (await browser.post("/login", data=data, headers=headers)).status_code == 403
    saved = browser.cookies.get("orialis_consent")
    browser.cookies.clear()
    assert (await browser.post("/login", data=data, headers={"Origin": PUBLIC})).status_code == 403
    browser.cookies.set("orialis_consent", saved)
    assert not calls
    assert (await browser.post("/login", data={**data, "consent": ""}, headers={"Origin": PUBLIC})).status_code == 400
    assert not calls
    state["fail"] = True
    failed = await browser.post("/login", data=data, headers={"Origin": PUBLIC})
    assert failed.status_code == 401 and "MUST-NOT-LEAK" not in failed.text and "password-secret" not in failed.text
    state["fail"] = False
    denied = await browser.post("/login", data={"pending": pending, "consent": "deny"}, headers={"Origin": PUBLIC})
    assert denied.status_code == 302 and "access_denied" in denied.headers["location"]
    assert len(calls) == 1
    assert (await browser.post("/login", data=data, headers={"Origin": PUBLIC})).status_code == 400


async def test_sso_ui_script_and_return_cookie(env):
    provider, browser, _, calls = env
    client = make_client()
    await provider.register_client(client)
    browser.cookies.set("orialis_mcp_return", "old-pending", domain="gateway.test", path="/")
    _, page = await start(provider, browser, client)
    elements = LoginHTML(page.text).elements
    inputs = [attrs for tag, attrs in elements if tag == "input"]
    assert not any(attrs.get("name") in {"username", "password"} for attrs in inputs)
    assert not any(attrs.get("autocomplete") in {"username", "current-password", "new-password"} for attrs in inputs)
    assert [attrs.get("type") for attrs in inputs if attrs.get("name") == "session_token"] == ["hidden"]
    assert any(tag == "button" and attrs.get("id") == "oidc-login" for tag, attrs in elements)
    assert "使用统一账号登录并授权" in page.text
    assert any(tag == "script" and attrs.get("src") == "/mcp-login.js" for tag, attrs in elements)
    csp = page.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "connect-src 'self'" in csp
    assert "frame-ancestors 'none'" in csp
    assert any(c.startswith("orialis_mcp_return=") and "Max-Age=0" in c
               for c in page.headers.get_list("set-cookie"))
    assert browser.cookies.get("orialis_mcp_return") is None
    script = await browser.get("/mcp-login.js")
    assert script.status_code == 200
    assert script.headers["content-type"].startswith("application/javascript")
    assert script.headers["x-content-type-options"] == "nosniff"
    assert script.headers["cache-control"] == "no-store"
    assert "/api/v1/auth/oidc/start" in script.text
    assert "/api/v1/auth/oidc/exchange" in script.text
    browser.cookies.set("orialis_mcp_return", "old-pending", domain="gateway.test", path="/")
    invalid = await browser.get("/login", params={"pending": "invalid"})
    assert invalid.status_code == 400
    assert browser.cookies.get("orialis_mcp_return") is None
    assert not calls


@pytest.mark.parametrize("include_session", [False, True])
async def test_password_login_rejected_without_upstream_call(env, include_session):
    provider, browser, _, calls = env
    client = make_client()
    await provider.register_client(client)
    pending, _ = await start(provider, browser, client)
    data = {"pending": pending, "consent": "allow", "username": "alice", "password": "password-secret"}
    if include_session:
        data["session_token"] = "pasted-session"
    response = await browser.post("/login", data=data, headers={"Origin": PUBLIC})
    assert response.status_code == 400
    assert "password-secret" not in response.text
    assert not calls
    with sqlite3.connect(provider.database_path) as db:
        assert db.execute("SELECT count(*) FROM grants").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM codes").fetchone()[0] == 0


async def test_session_token_login(env):
    provider, browser, state, calls = env
    client = make_client()
    await provider.register_client(client)
    before = int(time.time())
    code, _ = await consent(provider, browser, client)
    tokens = await provider.exchange_authorization_code(client, code)
    assert await provider.session_for_token(tokens.access_token) == "pasted-session"
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    assert before + 86400 <= refresh.expires_at <= int(time.time()) + 86400
    assert len(calls) == 1
    state["fail"] = True
    pending, _ = await start(provider, browser, client)
    bad = await browser.post("/login", data={"pending": pending, "consent": "allow", "session_token": "pasted-session"}, headers={"Origin": PUBLIC})
    assert bad.status_code == 401


async def test_client_registration_without_scope_can_request_write_at_consent(tmp_path):
    settings = Settings(api_url="http://127.0.0.1:18443", public_url=PUBLIC, database_path=tmp_path / "oauth.db")
    app = create_app(settings)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url=PUBLIC) as browser:
        registration = await browser.post("/register", json={"redirect_uris": [REDIRECT], "token_endpoint_auth_method": "none"})
        assert registration.status_code == 201
        client = registration.json()
        assert set(client["scope"].split()) == {"orialis:read", "orialis:write", "orialis:memory:read", "orialis:memory:write"}
        authorization = await browser.get("/authorize", params={"client_id": client["client_id"], "redirect_uri": REDIRECT, "response_type": "code", "scope": "orialis:read orialis:write", "code_challenge": CHALLENGE, "code_challenge_method": "S256", "resource": PUBLIC + "/mcp"})
        assert authorization.status_code == 302
        assert authorization.headers["location"].startswith(PUBLIC + "/login?")
        # Registration and a pending authorization have not granted any account access.
        with sqlite3.connect(settings.database_path) as db:
            assert db.execute("SELECT count(*) FROM grants").fetchone()[0] == 0


async def test_browser_json_consent_returns_registered_callback(env):
    provider, browser, _, _ = env
    client = make_client()
    await provider.register_client(client)
    pending, page = await start(provider, browser, client)
    assert page.headers["referrer-policy"] == "same-origin"
    response = await browser.post("/login", data={"pending": pending, "consent": "allow", "session_token": "pasted-session"}, headers={"Origin": PUBLIC, "Accept": "application/json"})
    assert response.status_code == 200
    redirect = urlsplit(response.json()["redirect"])
    assert redirect.hostname == "127.0.0.1" and redirect.path == "/callback"
    query = parse_qs(redirect.query)
    assert query["state"] == ["state-1"]
    assert await provider.load_authorization_code(client, query["code"][0]) is not None


async def test_expiry_and_tampered_models(env, monkeypatch):
    provider, browser, state, _ = env
    client = make_client()
    await provider.register_client(client)
    code, _ = await consent(provider, browser, client)
    with pytest.raises(TokenError):
        await provider.exchange_authorization_code(client, code.model_copy(update={"resource": "https://evil.test"}))
    with sqlite3.connect(provider.database_path) as db:
        db.execute("UPDATE grants SET expires=?", (int(time.time()) + 120,))
    tokens = await provider.exchange_authorization_code(client, code)
    assert 0 < tokens.expires_in <= 120
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    with pytest.raises(TokenError):
        await provider.exchange_refresh_token(client, refresh.model_copy(update={"resource": "https://evil.test"}), refresh.scopes)
    real_now = time.time()
    monkeypatch.setattr("orialis_mcp.auth.time.time", lambda: real_now + 121)
    assert await provider.load_access_token(tokens.access_token) is None
    assert await provider.load_refresh_token(client, tokens.refresh_token) is None
    with pytest.raises(TokenError):
        await provider.exchange_refresh_token(client, refresh, refresh.scopes)
    with pytest.raises(TokenError):
        await provider.session_for_token(tokens.access_token)
    monkeypatch.setattr("orialis_mcp.auth.time.time", lambda: real_now)
    code, _ = await consent(provider, browser, client)
    monkeypatch.setattr("orialis_mcp.auth.time.time", lambda: real_now + 301)
    assert await provider.load_authorization_code(client, code.code) is None
    with pytest.raises(TokenError):
        await provider.exchange_authorization_code(client, code)


async def test_atomic_code_and_refresh_consumption(env):
    provider, browser, _, _ = env
    client = make_client()
    await provider.register_client(client)
    code, _ = await consent(provider, browser, client)

    async def race(factory):
        results = await asyncio.gather(*(asyncio.to_thread(lambda: asyncio.run(factory())) for _ in range(2)), return_exceptions=True)
        assert sum(isinstance(r, TokenError) for r in results) == 1
        return next(r for r in results if not isinstance(r, Exception))

    tokens = await race(lambda: provider.exchange_authorization_code(client, code))
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    tokens = await race(lambda: provider.exchange_refresh_token(client, refresh, refresh.scopes))
    access = await provider.load_access_token(tokens.access_token)
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    await provider.revoke_token(refresh)
    assert await provider.load_access_token(access.token) is None


@pytest.mark.parametrize("auth_method", [None, "none", "client_secret_basic"])
async def test_sdk_registration_and_pkce_flow(env, auth_method):
    provider, browser, _, _ = env
    metadata = {"redirect_uris": [REDIRECT], "scope": "orialis:read orialis:write"}
    if auth_method is not None:
        metadata["token_endpoint_auth_method"] = auth_method
    registered = await browser.post("/register", json=metadata)
    assert registered.status_code == 201, registered.text
    client = registered.json()
    assert client["token_endpoint_auth_method"] == (auth_method or "client_secret_post")
    authorize = {"client_id": client["client_id"], "redirect_uri": REDIRECT,
                 "response_type": "code", "scope": "orialis:read orialis:write", "state": "state-1"}
    missing = await browser.get("/authorize", params=authorize)
    assert "invalid_request" in missing.headers.get("location", missing.text)
    authorize.update(code_challenge=CHALLENGE, code_challenge_method="plain")
    plain = await browser.get("/authorize", params=authorize)
    assert "invalid_request" in plain.headers.get("location", plain.text)
    authorize["code_challenge_method"] = "S256"
    response = await browser.get("/authorize", params=authorize)
    assert response.status_code == 302
    pending = parse_qs(urlsplit(response.headers["location"]).query)["pending"][0]
    assert (await browser.get(response.headers["location"])).status_code == 200
    response = await browser.post("/login", data={"pending": pending, "consent": "allow", "session_token": "pasted-session"}, headers={"Origin": PUBLIC})
    code = parse_qs(urlsplit(response.headers["location"]).query)["code"][0]
    data = {"grant_type": "authorization_code", "client_id": client["client_id"], "code": code,
            "redirect_uri": REDIRECT, "code_verifier": VERIFIER}
    headers = {}
    if client.get("client_secret"):
        if auth_method == "client_secret_basic":
            headers["Authorization"] = "Basic " + base64.b64encode(f'{client["client_id"]}:{client["client_secret"]}'.encode()).decode()
            del data["client_id"]
        else:
            data["client_secret"] = client["client_secret"]
    assert (await browser.post("/token", data={**data, "resource": "https://evil.test"}, headers=headers)).status_code == 400
    assert (await browser.post("/token", data={**data, "code_verifier": "wrong"}, headers=headers)).json()["error"] == "invalid_grant"
    response = await browser.post("/token", data=data, headers=headers)
    assert response.status_code == 200, response.text
    tokens = response.json()
    assert await provider.session_for_token(tokens["access_token"]) == "pasted-session"
    assert (await browser.post("/token", data=data, headers=headers)).json()["error"] == "invalid_grant"
    refresh_data = {"grant_type": "refresh_token", "client_id": client["client_id"],
                    "refresh_token": tokens["refresh_token"], "scope": "orialis:read", "resource": RESOURCE}
    if "client_secret" in data:
        refresh_data["client_secret"] = data["client_secret"]
    assert (await browser.post("/token", data={**refresh_data, "resource": "https://evil.test"}, headers=headers)).status_code == 400
    response = await browser.post("/token", data=refresh_data, headers=headers)
    assert response.status_code == 200, response.text
    rotated = response.json()
    revoke = {"client_id": client["client_id"], "token": rotated["refresh_token"], "token_type_hint": "refresh_token"}
    if auth_method == "client_secret_basic":
        del revoke["client_id"]
    if "client_secret" in data:
        revoke["client_secret"] = data["client_secret"]
    response = await browser.post("/revoke", data=revoke, headers=headers)
    assert response.status_code == 200, response.text
    assert await provider.load_access_token(rotated["access_token"]) is None


async def test_memory_scopes_are_discoverable_and_default_registration_is_not_a_grant(tmp_path):
    settings = Settings(api_url="http://127.0.0.1:18443", public_url=PUBLIC, database_path=tmp_path / "memory-oauth.db")
    app = create_app(settings)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url=PUBLIC) as browser:
        for path in ("/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server"):
            scopes = (await browser.get(path)).json()["scopes_supported"]
            assert "orialis:memory:read" in scopes and "orialis:memory:write" in scopes
            assert "orialis:session" not in scopes
        metadata = {"redirect_uris": [REDIRECT], "token_endpoint_auth_method": "none"}
        registered = (await browser.post("/register", json=metadata)).json()
        assert set(registered["scope"].split()) == {"orialis:read", "orialis:write", "orialis:memory:read", "orialis:memory:write"}
        authorize = {
            "client_id": registered["client_id"], "redirect_uri": REDIRECT,
            "response_type": "code", "code_challenge": CHALLENGE, "code_challenge_method": "S256",
        }
        default = await browser.get("/authorize", params=authorize)
        assert default.status_code == 302
        with sqlite3.connect(settings.database_path) as db:
            pending = AuthorizationParams.model_validate_json(db.execute("SELECT params FROM pending").fetchone()[0])
            assert pending.scopes == ["orialis:read"]
            assert db.execute("SELECT count(*) FROM grants").fetchone()[0] == 0
        explicit = await browser.get("/authorize", params={**authorize, "scope": "orialis:read orialis:memory:read orialis:memory:write"})
        assert explicit.status_code == 302
        consent_page = await browser.get(explicit.headers["location"])
        assert "读取 Orialis 屏幕记忆" in consent_page.text and "更新 Orialis 现有屏幕记忆" in consent_page.text
        # Existing or explicitly narrow clients retain their registered ceiling.
        legacy = (await browser.post("/register", json={**metadata, "scope": "orialis:read orialis:write"})).json()
        denied = await browser.get("/authorize", params={**authorize, "client_id": legacy["client_id"], "scope": "orialis:read orialis:memory:read"})
        assert "invalid_scope" in denied.headers.get("location", denied.text)


async def test_memory_access_requires_explicit_consent_and_cannot_escalate_refresh(env):
    provider, browser, _, _ = env
    memory_scopes = ["orialis:read", "orialis:memory:read", "orialis:memory:write"]
    client = make_client(scope=" ".join(memory_scopes))
    await provider.register_client(client)
    pending, page = await start(provider, browser, client, scopes=memory_scopes)
    assert "读取 Orialis 屏幕记忆" in page.text and "更新 Orialis 现有屏幕记忆" in page.text
    response = await browser.post("/login", data={"pending": pending, "consent": "allow", "session_token": "pasted-session"}, headers={"Origin": PUBLIC})
    code = parse_qs(urlsplit(response.headers["location"]).query)["code"][0]
    code = await provider.load_authorization_code(client, code)
    tokens = await provider.exchange_authorization_code(client, code)
    assert (await provider.load_access_token(tokens.access_token)).scopes == memory_scopes
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    reduced = await provider.exchange_refresh_token(client, refresh, ["orialis:read", "orialis:memory:read"])
    reduced_refresh = await provider.load_refresh_token(client, reduced.refresh_token)
    with pytest.raises(TokenError, match="invalid_scope"):
        await provider.exchange_refresh_token(client, reduced_refresh, memory_scopes)
    assert "orialis:memory:write" not in (await provider.load_access_token(reduced.access_token)).scopes


async def test_stdio_accepts_explicit_memory_scopes_without_changing_default(tmp_path):
    values = dict(api_url="http://127.0.0.1:18443", public_url=PUBLIC, database_path=tmp_path / "unused")
    assert Settings(**values).scopes == ("orialis:read",)
    assert Settings(**values, scopes=("orialis:read", "orialis:memory:read", "orialis:memory:write")).scopes[-1] == "orialis:memory:write"
    with pytest.raises(ValueError):
        Settings(**values, scopes=("orialis:session",))


async def test_existing_legacy_grant_cannot_refresh_into_memory_scope(env):
    provider, browser, _, _ = env
    client = make_client()
    await provider.register_client(client)
    code, _ = await consent(provider, browser, client)
    tokens = await provider.exchange_authorization_code(client, code)
    refresh = await provider.load_refresh_token(client, tokens.refresh_token)
    with pytest.raises(TokenError, match="invalid_scope"):
        await provider.exchange_refresh_token(client, refresh, ["orialis:read", "orialis:memory:read"])
    assert (await provider.get_client(client.client_id)).scope == "orialis:read orialis:write"
    assert (await provider.load_access_token(tokens.access_token)).scopes == ["orialis:read", "orialis:write"]
