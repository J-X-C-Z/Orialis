"""Explicit server-side Bilibili QR authorization; never starts a gateway.

Run in the isolated bilibili-api-python==17.4.1 environment, with absolute
--credential-file and --qr-file paths. No login runs on import or --help.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import io
import json
import logging
import os
from pathlib import Path
import stat
import tempfile
import time

if __package__:
    from .memory_video import BILI_CREDENTIAL_KEYS, VideoUnavailable, validate_bili_credentials
else:
    from memory_video import BILI_CREDENTIAL_KEYS, VideoUnavailable, validate_bili_credentials


def _absolute(path):
    path = Path(path).expanduser()
    if not path.is_absolute():
        raise VideoUnavailable("登录文件路径必须为绝对路径")
    return path


def _write_private(path, content):
    path = _absolute(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.is_symlink() or (path.exists() and not stat.S_ISREG(path.stat().st_mode)):
        raise VideoUnavailable("登录文件必须是普通文件，不能使用符号链接")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as target:
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_credentials(path, cookies):
    value = validate_bili_credentials(cookies)
    _write_private(path, json.dumps(value, separators=(",", ":")).encode())
    return sorted(value)


async def login(credential_file, qr_file, timeout=180):
    credential_file, qr_file = _absolute(credential_file), _absolute(qr_file)
    if credential_file == qr_file:
        raise VideoUnavailable("二维码图片与凭据必须保存为不同文件")
    qr_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout
    output = io.StringIO()

    def emit(event, **fields):
        print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)

    async def call(operation):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("QR authorization expired")
        return await asyncio.wait_for(operation, timeout=min(15, remaining))

    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        from bilibili_api import Credential, request_settings
        from bilibili_api.utils.network import get_client, get_buvid, HEADERS
        import qrcode
        request_settings.set_timeout(10)
        request_settings.set_wbi_retry_times(1)
        client = get_client()
        visitor = {}
        try:
            buvid3, buvid4 = await call(get_buvid())
            visitor = {"buvid3": buvid3, "buvid4": buvid4}
        except Exception:
            # Optional visitor bootstrap must not discard a later account login.
            pass

    async def request(path, params=None):
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            response = await call(client.request(
                method="GET", url="https://passport.bilibili.com" + path,
                params=params or {}, headers=HEADERS.copy(), cookies=visitor,
                allow_redirects=False,
            ))
        if response.code != 200:
            raise VideoUnavailable("B站登录接口暂不可用，请稍后重试")
        payload = response.json()
        if type(payload.get("code")) is not int or payload["code"] != 0 or not isinstance(payload.get("data"), dict):
            raise VideoUnavailable("B站登录接口未接受请求，请稍后重试")
        return response, payload["data"]

    try:
        _, generated = await request("/x/passport-login/web/qrcode/generate", {"source": "main-fe-header"})
        key, link = generated.get("qrcode_key"), generated.get("url")
        if not isinstance(key, str) or not key or not isinstance(link, str) or not link.startswith("https://"):
            raise VideoUnavailable("平台未返回有效二维码，请稍后重试")
        image = qrcode.make(link)
        picture = io.BytesIO()
        image.save(picture, format="PNG")
        _write_private(qr_file, picture.getvalue())
        emit("qr_ready", qr_file=str(qr_file), expires_seconds=max(0, int(deadline - time.monotonic())))
        previous = None
        while time.monotonic() < deadline:
            response, data = await request("/x/passport-login/web/qrcode/poll", {"qrcode_key": key, "source": "main-fe-header"})
            code = data.get("code")
            if type(code) is int and code == 0:
                emit("poll_response", code=code, response_fields=sorted(data), cookie_fields=sorted(response.cookies))
                # The current WEB endpoint delivers the session in Set-Cookie;
                # the old SDK check_state URL parser silently loses these fields.
                returned = {key: value for key, value in response.cookies.items() if key in BILI_CREDENTIAL_KEYS}
                merged = {**visitor, **returned}
                credential = Credential(
                    sessdata=merged.get("SESSDATA"), bili_jct=merged.get("bili_jct"),
                    buvid3=merged.get("buvid3"), buvid4=merged.get("buvid4"),
                    dedeuserid=merged.get("DedeUserID"),
                )
                cookies = {key: value for key, value in credential.get_cookies().items() if key in BILI_CREDENTIAL_KEYS}
                fields = write_credentials(credential_file, cookies)
                emit("authorized", credential_file=str(credential_file), fields=fields)
                return
            if code == 86038:
                raise TimeoutError("QR authorization expired")
            if code not in {86101, 86090}:
                emit("poll_response", code=code, response_fields=sorted(data), cookie_fields=sorted(response.cookies))
                raise VideoUnavailable("B站扫码返回未支持的状态，未保存新的凭据，请重试")
            event = "awaiting_confirmation" if code == 86090 else "awaiting_scan"
            if event != previous:
                emit(event)
                previous = event
            await asyncio.sleep(min(3, max(0, deadline - time.monotonic())))
        raise TimeoutError("QR authorization expired")
    finally:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), contextlib.suppress(Exception):
            await client.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credential-file", required=True, type=Path)
    parser.add_argument("--qr-file", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args(argv)
    if not 15 <= args.timeout <= 300:
        parser.error("--timeout must be between 15 and 300 seconds")
    logging.disable(logging.CRITICAL)
    try:
        asyncio.run(login(args.credential_file, args.qr_file, args.timeout))
        return 0
    except KeyboardInterrupt:
        reason = "登录已取消，未保存新的凭据"
    except TimeoutError:
        reason = "二维码已过期或授权等待超时，未保存新的凭据"
    except VideoUnavailable as error:
        reason = str(error)
    except Exception:
        reason = "登录未完成；请检查专用SDK环境或平台访问状态后重试，未保存新的凭据"
    print(json.dumps({"event": "failed", "reason": reason}, ensure_ascii=False), flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
