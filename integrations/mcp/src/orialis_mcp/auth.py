"""SQLite backing for the MCP SDK OAuth server; session_for_token is async.

Mount routes() alongside the SDK auth routes. The parent oauth_compat token route
validates resource while parsing its bounded request body; no middleware is needed.
Only fixed Orialis auth endpoints are called; upstream sessions never leave DB.
"""

from hashlib import sha256
from html import escape
from importlib.resources import files
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
from urllib.parse import urlencode, urlsplit

import httpx
from mcp.server.auth.provider import (
    AccessToken, AuthorizationCode, AuthorizationParams, AuthorizeError,
    OAuthAuthorizationServerProvider, RefreshToken, RegistrationError, TokenError,
    construct_redirect_uri,
)
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from starlette.routing import Route

SCOPES = {"orialis:read": "Read Orialis tasks, projects, and calendar",
          "orialis:write": "Write Orialis tasks, projects, and calendar",
          "orialis:memory:read": "读取 Orialis 屏幕记忆摘要与详情（不包含原始截图或录屏）",
          "orialis:memory:write": "更新 Orialis 现有屏幕记忆的可编辑内容（不修改原始截图或录屏）",
          "orialis:session": "登录 Orialis 手机或桌面客户端，访问你的账号并同步数据"}
_COOKIE = "orialis_consent"


def _hash(value: str) -> str:
    return sha256(value.encode()).hexdigest()


def _safe_url(value: str) -> bool:
    p = urlsplit(value)
    return bool(p.hostname and not p.username and not p.password and not p.fragment and (
        p.scheme == "https" or (p.scheme == "http" and p.hostname in {"localhost", "127.0.0.1", "::1"})
    ))


class _Connection(sqlite3.Connection):
    def __exit__(self, *args):
        # Generator context managers cannot propagate SDK's frozen error dataclasses.
        try:
            return super().__exit__(*args)
        finally:
            self.close()


class Provider(OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]):
    def __init__(self, api_url: str, public_url: str, database_path: Path,
                 http_client: httpx.AsyncClient | None = None):
        self.api_url = api_url.rstrip("/")
        self.public_url = public_url.rstrip("/")
        if not _safe_url(self.public_url) or urlsplit(self.public_url).query:
            raise ValueError("public_url must be HTTPS or loopback HTTP without query/fragment")
        api = urlsplit(self.api_url)
        if api.scheme not in {"http", "https"} or not api.hostname or api.username or api.password or api.query or api.fragment:
            raise ValueError("api_url must be an HTTP(S) base URL")
        self.resource = self.public_url + "/mcp"
        self.origin = f"{urlsplit(self.public_url).scheme}://{urlsplit(self.public_url).netloc}"
        self.login_path = urlsplit(self.public_url).path + "/login"
        self.database_path = Path(database_path)
        self.http_client = http_client
        # Protect newly created ancestors as well as the dedicated database directory.
        missing = []
        parent = self.database_path.parent
        while not parent.exists():
            missing.append(parent)
            parent = parent.parent
        for directory in reversed(missing):
            directory.mkdir(mode=0o700)
        fd = os.open(self.database_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        with self._db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pending (
                    id TEXT PRIMARY KEY, client TEXT NOT NULL, params TEXT NOT NULL,
                    expires REAL NOT NULL, csrf TEXT);
                CREATE TABLE IF NOT EXISTS grants (
                    id TEXT PRIMARY KEY, client TEXT NOT NULL, subject TEXT NOT NULL,
                    session TEXT NOT NULL, expires INTEGER NOT NULL, resource TEXT NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS codes (
                    hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS tokens (
                    hash TEXT PRIMARY KEY, kind TEXT NOT NULL, grant_id TEXT NOT NULL,
                    scopes TEXT NOT NULL, expires INTEGER NOT NULL, active INTEGER NOT NULL);
            """)

    def _db(self):
        db = sqlite3.connect(self.database_path, timeout=10, factory=_Connection)
        db.row_factory = sqlite3.Row
        return db

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        with self._db() as db:
            row = db.execute("SELECT data FROM clients WHERE id=?", (client_id,)).fetchone()
        return OAuthClientInformationFull.model_validate_json(row["data"]) if row else None

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        if not client_info.redirect_uris or any(not _safe_url(str(u)) for u in client_info.redirect_uris):
            raise RegistrationError("invalid_redirect_uri", "Use HTTPS or loopback HTTP redirect URIs")
        method = client_info.token_endpoint_auth_method
        scopes = set((client_info.scope or "orialis:read").split())
        if "orialis:session" in scopes:
            if scopes != {"orialis:session"} or method != "none" or any(
                urlsplit(str(uri)).scheme != "http"
                or urlsplit(str(uri)).hostname != "127.0.0.1"
                or not urlsplit(str(uri)).port
                or urlsplit(str(uri)).path != "/callback"
                or urlsplit(str(uri)).query
                for uri in client_info.redirect_uris
            ):
                raise RegistrationError("invalid_client_metadata", "Native sessions require a public client with an exact IPv4 loopback callback")
        if (not client_info.client_id or method not in {"none", "client_secret_post", "client_secret_basic"}
                or (method == "none" and client_info.client_secret)
                or (method != "none" and not client_info.client_secret)
                or set((client_info.scope or "orialis:read").split()) - SCOPES.keys()
                or "authorization_code" not in client_info.grant_types
                or set(client_info.grant_types) - {"authorization_code", "refresh_token"}
                or client_info.response_types != ["code"]):
            raise RegistrationError("invalid_client_metadata", "Invalid client metadata")
        try:
            with self._db() as db:
                db.execute("INSERT INTO clients VALUES (?,?)", (client_info.client_id, client_info.model_dump_json()))
        except sqlite3.IntegrityError:
            raise RegistrationError("invalid_client_metadata", "Client already registered") from None

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        stored = await self.get_client(client.client_id or "")
        if not stored:
            raise AuthorizeError("unauthorized_client", "Unknown client")
        try:
            stored.validate_redirect_uri(params.redirect_uri)
        except Exception:
            raise AuthorizeError("invalid_request", "Invalid redirect URI") from None
        if not _safe_url(str(params.redirect_uri)) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", params.code_challenge):
            raise AuthorizeError("invalid_request", "A safe redirect URI and S256 PKCE are required")
        scopes = params.scopes if params.scopes is not None else ["orialis:read"]
        if set(scopes) - SCOPES.keys() or set(scopes) - set((stored.scope or "orialis:read").split()):
            raise AuthorizeError("invalid_scope", "Invalid scopes")
        if params.resource is not None and params.resource != self.resource:
            raise AuthorizeError("invalid_request", "Invalid resource")
        params = params.model_copy(update={"scopes": scopes, "resource": self.resource})
        pending = secrets.token_urlsafe(32)
        with self._db() as db:
            db.execute("DELETE FROM pending WHERE expires<=?", (time.time(),))
            db.execute("INSERT INTO pending VALUES (?,?,?,?,NULL)",
                       (_hash(pending), stored.client_id, params.model_dump_json(), time.time() + 600))
        return self.public_url + "/login?" + urlencode({"pending": pending})

    def routes(self) -> list[Route]:
        return [Route("/login", self._login, methods=["GET", "POST"]),
                Route("/mcp-login.js", self._login_script, methods=["GET"])]

    async def _login_script(self, request: Request):
        return Response(files("orialis_mcp").joinpath("login.js").read_text(encoding="utf-8"),
                        media_type="application/javascript",
                        headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})

    def _page(self, row, pending: str, error: str = "", status: int = 200):
        params = AuthorizationParams.model_validate_json(row["params"])
        with self._db() as db:
            client = OAuthClientInformationFull.model_validate_json(
                db.execute("SELECT data FROM clients WHERE id=?", (row["client"],)).fetchone()["data"])
        scopes = "".join(f"<li>{escape(scope)} — {escape(SCOPES[scope])}</li>" for scope in params.scopes or [])
        return HTMLResponse(f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>授权访问 Orialis</title>
<style>body{{margin:0;background:#f4f6f9;color:#202938;font:16px/1.65 system-ui,sans-serif}}
main{{max-width:520px;margin:8vh auto;padding:32px;background:white;border-radius:20px}}
h1{{font-size:26px}}p,li{{overflow-wrap:anywhere}}button,input{{font:inherit;box-sizing:border-box}}
button{{padding:11px 18px;border:1px solid #ccd3df;border-radius:10px;cursor:pointer;background:#fff}}
.primary{{background:#294fbd;color:white;border-color:#294fbd}}label{{display:block;margin:12px 0}}
input{{display:block;width:100%;padding:9px;border:1px solid #ccd3df;border-radius:8px}}
#login-error{{color:#a32b2b}}details{{margin:24px 0}}small{{color:#626d7d}}</style>
<main><small>ORIALIS · MCP 连接授权</small><h1>连接你的 Orialis</h1>
<p><strong>{escape(client.client_name or "MCP 客户端")}</strong> 请求以下权限：</p><ul>{scopes}</ul>
<p>点击下方账号授权按钮，即表示同意将以上权限授予此客户端。</p>
<p id="login-error" role="alert">{escape(error)}</p>
<form id="mcp-consent" method="post" action="{escape(self.login_path, quote=True)}">
<input type="hidden" name="pending" value="{escape(pending, quote=True)}">
<button type="button" class="primary" id="oidc-login">使用统一账号登录并授权</button>
<p><button type="button" id="current-login">使用当前已登录账号并授权</button></p>
<input type="hidden" name="session_token" autocomplete="off">
<button id="allow" name="consent" value="allow" hidden>确认授权</button>
<button name="consent" value="deny" formnovalidate>拒绝授权</button></form></main>
<script src="{escape(urlsplit(self.public_url).path + '/mcp-login.js', quote=True)}" defer></script></html>''',
            status_code=status, headers={"Cache-Control": "no-store", "Pragma": "no-cache",
                "Referrer-Policy": "same-origin", "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"})

    async def _login(self, request: Request):
        form = await request.form() if request.method == "POST" else request.query_params
        pending = form.get("pending", "")
        if not isinstance(pending, str):
            pending = ""
        with self._db() as db:
            row = db.execute("SELECT * FROM pending WHERE id=? AND expires>?", (_hash(pending), time.time())).fetchone()
        if row is None:
            response = HTMLResponse("Invalid or expired consent request", status_code=400, headers={"Cache-Control": "no-store"})
            if request.method == "GET":
                response.delete_cookie("orialis_mcp_return", path="/")
            return response
        cookie = request.cookies.get(_COOKIE, "")
        if request.method == "GET":
            csrf = secrets.token_urlsafe(32)
            with self._db() as db:
                # Each rendered page is bound to this browser, never just the URL.
                db.execute("UPDATE pending SET csrf=? WHERE id=?", (_hash(csrf), row["id"]))
            response = self._page(row, pending)
            response.delete_cookie("orialis_mcp_return", path="/")
            response.set_cookie(_COOKIE, csrf, max_age=600, httponly=True, samesite="strict",
                                secure=urlsplit(self.public_url).scheme == "https", path=self.login_path)
            return response
        if (request.headers.get("origin") != self.origin or not cookie or not row["csrf"]
                or not secrets.compare_digest(row["csrf"], _hash(cookie))):
            return HTMLResponse("Invalid consent request", status_code=403, headers={"Cache-Control": "no-store"})
        params = AuthorizationParams.model_validate_json(row["params"])
        if form.get("consent") == "deny":
            with self._db() as db:
                db.execute("DELETE FROM pending WHERE id=? AND csrf=?", (row["id"], row["csrf"]))
            response = RedirectResponse(construct_redirect_uri(str(params.redirect_uri), error="access_denied",
                                                        state=params.state, iss=self.public_url), status_code=302)
        elif form.get("consent") == "allow":
            username, password = form.get("username"), form.get("password")
            pasted = form.get("session_token", "")
            if (username or password or not isinstance(pasted, str)
                    or not re.fullmatch(r"[\x21-\x7e]+", pasted)):
                return self._page(row, pending, "请使用统一账号登录并授权", 400)
            try:
                kwargs = {"headers": {"Authorization": "Session " + pasted}}
                if self.http_client is None:
                    async with httpx.AsyncClient(timeout=15, follow_redirects=False, trust_env=False) as client:
                        result = await client.get(self.api_url + "/api/v1/auth/session", **kwargs)
                else:
                    result = await self.http_client.get(self.api_url + "/api/v1/auth/session", **kwargs,
                                                        follow_redirects=False, timeout=15)
                result.raise_for_status()
                data = result.json()
                session, subject = pasted, data["userId"]
                if (not isinstance(session, str) or not re.fullmatch(r"[\x21-\x7e]+", session)
                        or not isinstance(subject, str) or not subject):
                    raise ValueError("Invalid upstream session")
                # Session inspection omits expiry; API calls enforce real revocation/expiry.
                expires = int(time.time()) + 86400
                if expires <= time.time():
                    raise ValueError("Expired upstream session")
            except (httpx.HTTPError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
                return self._page(row, pending, "登录会话无效或已过期，请重新使用统一账号登录", 401)
            code, grant = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            auth_code = AuthorizationCode(code=code, client_id=row["client"], scopes=params.scopes or [],
                expires_at=min(time.time() + 300, expires), code_challenge=params.code_challenge,
                redirect_uri=params.redirect_uri, redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
                resource=self.resource, subject=subject)
            with self._db() as db:
                db.execute("BEGIN IMMEDIATE")
                consumed = db.execute("DELETE FROM pending WHERE id=? AND csrf=? AND expires>?",
                                      (row["id"], row["csrf"], time.time())).rowcount
                if consumed != 1:
                    return HTMLResponse("Invalid or expired consent request", status_code=400)
                db.execute("INSERT INTO grants VALUES (?,?,?,?,?,?,0)",
                           (grant, row["client"], subject, session, expires, self.resource))
                db.execute("INSERT INTO codes VALUES (?,?,?)",
                           (_hash(code), grant, auth_code.model_dump_json(exclude={"code"})))
            callback = construct_redirect_uri(str(params.redirect_uri), code=code,
                                             state=params.state, iss=self.public_url)
            response = (JSONResponse({"redirect": callback})
                        if "application/json" in request.headers.get("accept", "")
                        else RedirectResponse(callback, status_code=302))
        else:
            return self._page(row, pending, "Explicit consent is required", 400)
        response.headers["Cache-Control"] = "no-store"
        response.delete_cookie(_COOKIE, path=self.login_path)
        return response

    async def load_authorization_code(self, client: OAuthClientInformationFull, authorization_code: str) -> AuthorizationCode | None:
        with self._db() as db:
            row = db.execute("SELECT c.data FROM codes c JOIN grants g ON g.id=c.grant_id "
                "WHERE c.hash=? AND g.client=? AND g.revoked=0 AND g.expires>? AND g.resource=?",
                (_hash(authorization_code), client.client_id, time.time(), self.resource)).fetchone()
        if row:
            code = AuthorizationCode(code=authorization_code, **json.loads(row["data"]))
            if code.expires_at > time.time():
                return code
        return None

    def _issue(self, db, grant, scopes: list[str], allow_refresh: bool = True) -> OAuthToken:
        now = int(time.time())
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        expires = min(now + 3600, grant["expires"])
        for token, kind, expiry in [(access, "access", expires), (refresh, "refresh", grant["expires"])]:
            if kind == "refresh" and not allow_refresh:
                continue
            db.execute("INSERT INTO tokens VALUES (?,?,?,?,?,1)",
                       (_hash(token), kind, grant["id"], json.dumps(scopes), expiry))
        return OAuthToken(access_token=access, token_type="Bearer", expires_in=expires - now,
                          refresh_token=refresh if allow_refresh else None, scope=" ".join(scopes))

    async def exchange_authorization_code(self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode) -> OAuthToken:
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT c.data,g.* FROM codes c JOIN grants g ON g.id=c.grant_id "
                             "WHERE c.hash=?", (_hash(authorization_code.code),)).fetchone()
            if (not row or row["client"] != client.client_id or row["revoked"] or row["expires"] <= time.time()
                    or row["resource"] != self.resource):
                raise TokenError("invalid_grant", "Invalid authorization code")
            code = AuthorizationCode(code=authorization_code.code, **json.loads(row["data"]))
            if code.expires_at <= time.time() or code != authorization_code:
                raise TokenError("invalid_grant", "Invalid authorization code")
            db.execute("DELETE FROM codes WHERE hash=?", (_hash(code.code),))
            return self._issue(db, row, code.scopes, "refresh_token" in client.grant_types)

    def _load_token(self, token: str, kind: str, client_id: str | None = None):
        with self._db() as db:
            row = db.execute("SELECT t.*,g.client,g.subject,g.session,g.resource,g.expires AS upstream_expires "
                "FROM tokens t JOIN grants g ON g.id=t.grant_id WHERE t.hash=? AND t.kind=? "
                "AND t.active=1 AND g.revoked=0 AND t.expires>? AND g.expires>? AND g.resource=?",
                (_hash(token), kind, time.time(), time.time(), self.resource)).fetchone()
        if row and (client_id is None or row["client"] == client_id):
            return row
        return None

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        row = self._load_token(refresh_token, "refresh", client.client_id or "")
        return RefreshToken(token=refresh_token, client_id=row["client"], scopes=json.loads(row["scopes"]),
            expires_at=row["expires"], resource=row["resource"], subject=row["subject"]) if row else None

    async def exchange_refresh_token(self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]) -> OAuthToken:
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT t.scopes,t.expires AS token_expires,t.active,g.* "
                "FROM tokens t JOIN grants g ON g.id=t.grant_id WHERE t.hash=? AND t.kind='refresh'",
                (_hash(refresh_token.token),)).fetchone()
            if (not row or row["client"] != client.client_id or row["revoked"] or not row["active"]
                    or row["expires"] <= time.time() or row["token_expires"] <= time.time()
                    or row["resource"] != self.resource or refresh_token.resource != self.resource
                    or refresh_token.client_id != client.client_id):
                raise TokenError("invalid_grant", "Invalid refresh token")
            if set(scopes) - set(json.loads(row["scopes"])):
                raise TokenError("invalid_scope", "Scope escalation is not allowed")
            db.execute("UPDATE tokens SET active=0 WHERE grant_id=?", (row["id"],))
            return self._issue(db, row, scopes)

    async def load_access_token(self, token: str) -> AccessToken | None:
        row = self._load_token(token, "access")
        return AccessToken(token=token, client_id=row["client"], scopes=json.loads(row["scopes"]),
            expires_at=row["expires"], resource=row["resource"], subject=row["subject"]) if row else None

    async def session_for_token(self, token: str) -> str:
        """Re-check persisted access validity; return the raw upstream session token.

        Call immediately before each upstream tool request, including after the SDK
        bearer middleware has accepted the token. Raises SDK TokenError if invalid.
        """
        row = self._load_token(token, "access")
        if not row:
            raise TokenError("invalid_grant", "Invalid access token")
        return row["session"]

    async def consume_native_session(self, token: str):
        """Consume only a native-scoped OAuth grant; ordinary MCP grants cannot export sessions."""
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT t.scopes,g.id,g.subject,g.session,g.expires FROM tokens t JOIN grants g ON g.id=t.grant_id "
                "WHERE t.hash=? AND t.kind='access' AND t.active=1 AND g.revoked=0 "
                "AND t.expires>? AND g.expires>? AND g.resource=?",
                (_hash(token), time.time(), time.time(), self.resource),
            ).fetchone()
            if row is None or set(json.loads(row["scopes"])) != {"orialis:session"}:
                raise TokenError("invalid_grant", "A native sign-in grant is required")
            db.execute("UPDATE grants SET revoked=1,session='' WHERE id=?", (row["id"],))
            return dict(row)

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        with self._db() as db:
            db.execute("UPDATE grants SET revoked=1,session='' WHERE id IN "
                       "(SELECT grant_id FROM tokens WHERE hash=?) AND client=?",
                       (_hash(token.token), token.client_id))
