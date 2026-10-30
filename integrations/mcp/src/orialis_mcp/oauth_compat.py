"""SDK 1.30 compatibility: public revocation and Basic auth without body client_id."""

import base64
import binascii
from urllib.parse import parse_qsl, unquote, urlencode

from mcp.server.auth.handlers.revoke import RevocationHandler
from mcp.server.auth.handlers.token import TokenHandler
from mcp.server.auth.middleware.client_auth import ClientAuthenticator
from starlette.requests import Request
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse
from starlette.routing import Route, request_response


def routes(provider):
    authenticator = ClientAuthenticator(provider)
    token = TokenHandler(provider, authenticator)
    revoke = RevocationHandler(provider, authenticator)

    async def handle(request):
        # Keep the SDK's PKCE, client-secret, code, expiry, and refresh validation.
        if request.headers.get("content-type", "").split(";")[0] != "application/x-www-form-urlencoded":
            return JSONResponse({"error": "invalid_request"}, status_code=400)
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > 65536:
                return JSONResponse({"error": "invalid_request"}, status_code=413)
        try:
            fields = parse_qsl(body.decode("utf-8"), keep_blank_values=True, max_num_fields=100)
        except (ValueError, UnicodeDecodeError):
            return JSONResponse({"error": "invalid_request"}, status_code=400)
        names = {k for k, v in fields}
        resources = [v for k, v in fields if k == "resource"]
        if request.url.path == "/token" and resources and resources != [provider.resource]:
            return JSONResponse({"error": "invalid_request", "error_description": "Invalid resource"}, status_code=400)
        auth = request.headers.get("authorization", "")
        if "client_id" not in names and auth.startswith("Basic "):
            try:
                credentials = base64.b64decode(auth[6:], validate=True).decode("utf-8")
                client_id, _ = credentials.split(":", 1)
                fields.append(("client_id", unquote(client_id)))
            except (ValueError, UnicodeDecodeError, binascii.Error):
                return JSONResponse({"error": "invalid_client"}, status_code=401)
        if request.url.path == "/revoke" and "client_secret" not in names:
            fields.append(("client_secret", ""))
        adapted_body = urlencode(fields).encode()
        scope = dict(request.scope)
        scope["headers"] = [(k, v) for k, v in scope["headers"] if k.lower() != b"content-length"]
        scope["headers"].append((b"content-length", str(len(adapted_body)).encode()))

        async def receive():
            return {"type": "http.request", "body": adapted_body, "more_body": False}

        adapted = Request(scope, receive)
        return await (token if request.url.path == "/token" else revoke).handle(adapted)

    endpoint = CORSMiddleware(request_response(handle), allow_origins=["*"], allow_methods=["POST", "OPTIONS"], allow_headers=["*"])
    return [Route("/token", endpoint, methods=["POST", "OPTIONS"]), Route("/revoke", endpoint, methods=["POST", "OPTIONS"])]
