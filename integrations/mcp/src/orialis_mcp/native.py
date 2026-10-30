"""RFC 8252 loopback OAuth grants become the native app's existing Orialis session."""

from datetime import datetime, timezone

import httpx
from mcp.server.auth.provider import TokenError
from starlette.responses import JSONResponse
from starlette.routing import Route


def routes(provider):
    async def exchange(request):
        headers = {"Cache-Control": "no-store", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff"}
        authorization = request.headers.get("authorization", "")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token:
            return JSONResponse({"error": "unauthorized"}, status_code=401, headers=headers)
        try:
            grant = await provider.consume_native_session(token)
        except TokenError:
            return JSONResponse({"error": "invalid_native_grant"}, status_code=401, headers=headers)
        try:
            auth = {"Authorization": "Session " + grant["session"]}
            if provider.http_client is not None:
                response = await provider.http_client.get(provider.api_url + "/api/v1/auth/session", headers=auth, follow_redirects=False)
            else:
                async with httpx.AsyncClient(timeout=15, follow_redirects=False, trust_env=False) as client:
                    response = await client.get(provider.api_url + "/api/v1/auth/session", headers=auth)
            response.raise_for_status()
            profile = response.json()
            if profile["userId"] != grant["subject"] or not isinstance(profile.get("username"), str):
                raise ValueError("Identity mismatch")
        except (httpx.HTTPError, ValueError, KeyError, TypeError):
            return JSONResponse({"error": "session_expired", "message": "Please sign in again"}, status_code=401, headers=headers)
        return JSONResponse({
            "userId": profile["userId"], "username": profile["username"],
            "accessToken": grant["session"],
            "expiresAt": datetime.fromtimestamp(grant["expires"], timezone.utc).isoformat(),
        }, headers=headers)

    return [Route("/api/v1/auth/native/session", exchange, methods=["GET"])]
