"""Public Bilibili captions and sampled storyboard evidence, with bounded HTTPS reads.

Storyboard selection/cropping adapts the MIT dsh-bili-scroll reference at
5be5f6d57c47c7e79ad9bc4ce39457b68a160dfa, vendor/bilibili-mcp/mcp_server.py.
See THIRD_PARTY_LICENSES.md. Only a dedicated, explicitly authorized Bilibili
credential file may be read; no playback download or ASR is used.
"""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
import hashlib
import html
import http.client
from http.client import HTTPException
import io
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import time
import unicodedata
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit

BVID = re.compile(r"(?<![0-9A-Za-z])BV[0-9A-Za-z]{10}(?![0-9A-Za-z])")
_SOURCE_HOSTS = frozenset({"bilibili.com", "www.bilibili.com", "m.bilibili.com", "b23.tv"})
_API_HOSTS = frozenset({"api.bilibili.com"})
_CDN_SUFFIXES = (".hdslb.com", ".bilivideo.com")
_OTHER_VIDEO_DOMAINS = ("youtube.com", "youtu.be", "douyin.com", "iesdouyin.com", "kuaishou.com", "tiktok.com", "ixigua.com", "xiaohongshu.com", "xhslink.com")
BILI_CREDENTIAL_KEYS = frozenset({"SESSDATA", "bili_jct", "buvid3", "buvid4", "DedeUserID"})
_WBI_ORDER = (46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
              27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13)


class VideoUnavailable(ValueError):
    pass


def validate_bili_credentials(value):
    if not isinstance(value, dict) or set(value) - BILI_CREDENTIAL_KEYS:
        raise VideoUnavailable("B站专用凭据格式无效，请重新通过专用二维码授权")
    cookies = {}
    for key, item in value.items():
        if not isinstance(item, str) or len(item) > 8192 or not item.isascii() or any(ord(char) <= 32 or ord(char) == 127 or char in (';', ',', '"', '\\') for char in item):
            raise VideoUnavailable("B站专用凭据格式无效，请重新通过专用二维码授权")
        if item:
            cookies[key] = item
    if not cookies.get("SESSDATA"):
        raise VideoUnavailable("B站专用凭据缺少登录状态，请重新通过专用二维码授权")
    return cookies


def bili_credential_path():
    explicit = os.environ.get("ORIALIS_BILI_CREDENTIAL_FILE")
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    path = Path(explicit).expanduser() if explicit else home / "orialis-memory" / "bili_credential.json"
    if not path.is_absolute():
        raise VideoUnavailable("B站专用凭据路径必须是绝对路径")
    return path, bool(explicit)


def load_bili_credentials():
    path, explicit = bili_credential_path()
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except FileNotFoundError:
        if not explicit:
            return {}
        raise VideoUnavailable("指定的B站专用凭据文件不存在，请通过专用二维码授权") from None
    except OSError:
        raise VideoUnavailable("B站专用凭据文件无法读取，请检查权限并重新授权") from None
    try:
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
                raise VideoUnavailable("B站专用凭据必须是权限为600的普通文件")
            raw = source.read(65537)
        if len(raw) > 65536:
            raise ValueError("credential file too large")
        return validate_bili_credentials(json.loads(raw))
    except VideoUnavailable:
        raise
    except (OSError, ValueError, UnicodeError):
        raise VideoUnavailable("B站专用凭据无法读取，请重新通过专用二维码授权") from None


def web_url(value: str) -> bool:
    try:
        url = urlsplit(value)
        return (url.scheme in {"http", "https"} and bool(url.hostname)
                and not url.username and not url.password and url.port in {None, 80, 443}
                and len(value.encode("utf-8")) <= 8192)
    except (ValueError, AttributeError):
        return False


def is_bilibili_url(value: str) -> bool:
    return web_url(value) and urlsplit(value).hostname.lower() in _SOURCE_HOSTS


def _allowed_url(value: str, *, media: bool) -> tuple[str, str]:
    if value.startswith("//"):
        value = "https:" + value
    if not web_url(value):
        raise VideoUnavailable("视频地址不可用")
    url = urlsplit(value)
    host = url.hostname.lower()
    allowed = (host in _SOURCE_HOSTS or host in _API_HOSTS
               or (media and any(host.endswith(suffix) for suffix in _CDN_SUFFIXES)))
    if not allowed or url.port not in {None, 443}:
        raise VideoUnavailable("视频地址不属于受支持的平台")
    return urlunsplit(("https", host, url.path or "/", url.query, "")), host


class PublicBiliHTTP:
    """Connect to a verified public address; recheck every redirect before following it."""
    def __init__(self, seconds=65):
        self.deadline = time.monotonic() + seconds
        self.cookies = load_bili_credentials()

    def fetch(self, url, *, media=False, limit=1024 * 1024, resolve_only=False):
        for _ in range(4):
            url, host = _allowed_url(url, media=media)
            if resolve_only and host in _SOURCE_HOSTS - {"b23.tv"} and urlsplit(url).path.startswith("/video/"):
                return b"", url
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise VideoUnavailable("视频内容读取超时")
            addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
            ips = list(dict.fromkeys(item[4][0] for item in addresses))
            if not ips or any(not ipaddress.ip_address(ip).is_global for ip in ips):
                raise VideoUnavailable("视频地址未解析到公共网络")
            connection = http.client.HTTPSConnection(host, timeout=min(8, remaining))
            # Pin the checked address while retaining TLS hostname validation/SNI.
            connection._create_connection = lambda address, timeout, *args: socket.create_connection((ips[0], 443), timeout)
            try:
                parsed = urlsplit(url)
                headers = {
                    "User-Agent": "Mozilla/5.0 Orialis/1.0", "Referer": "https://www.bilibili.com/",
                    "Accept-Encoding": "identity",
                }
                if self.cookies and (host == "bilibili.com" or host.endswith(".bilibili.com")):
                    headers["Cookie"] = "; ".join(f"{key}={value}" for key, value in sorted(self.cookies.items()))
                connection.request("GET", urlunsplit(("", "", parsed.path, parsed.query, "")), headers=headers)
                response = connection.getresponse()
                if response.status in {301, 302, 303, 307, 308}:
                    location = response.getheader("Location")
                    if not location:
                        raise VideoUnavailable("视频短链接未返回有效目标")
                    url = urljoin(url, location)
                    continue
                if response.status != 200:
                    if response.status == 401:
                        raise VideoUnavailable("B站登录状态未被接受，请重新通过专用二维码授权")
                    if response.status in {403, 412}:
                        raise VideoUnavailable("B站仍限制当前服务器访问；专用登录授权不保证解除限制，请稍后重试")
                    raise VideoUnavailable("平台暂时无法提供视频内容")
                if int(response.getheader("Content-Length") or 0) > limit:
                    raise VideoUnavailable("视频证据超过读取大小限制")
                chunks, size = [], 0
                while True:
                    if time.monotonic() > self.deadline:
                        raise VideoUnavailable("视频内容读取超时")
                    chunk = response.read(min(65536, limit + 1 - size))
                    if not chunk:
                        return b"".join(chunks), url
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > limit:
                        raise VideoUnavailable("视频证据超过读取大小限制")
            finally:
                connection.close()
        raise VideoUnavailable("视频链接重定向次数过多")

    def resolve(self, url):
        return self.fetch(url, limit=512 * 1024, resolve_only=True)[1]

    def data(self, path, params):
        if path.startswith("/x/web-interface/wbi/"):
            nav = self.data("/x/web-interface/nav", {})
            images = nav.get("wbi_img", {})
            parts = [urlsplit(str(images.get(name) or "")).path.rsplit("/", 1)[-1].split(".")[0]
                     for name in ("img_url", "sub_url")]
            if any(not re.fullmatch(r"[0-9a-fA-F]{32}", part) for part in parts):
                raise VideoUnavailable("平台未提供有效的搜索签名，请稍后重试")
            material = "".join(parts)
            key = "".join(material[index] for index in _WBI_ORDER)
            params = {**params, "web_location": 1550101, "wts": int(time.time())}
            query = urlencode(sorted(params.items()))
            params["w_rid"] = hashlib.md5((query + key).encode(), usedforsecurity=False).hexdigest()
        raw, _ = self.fetch("https://api.bilibili.com" + path + "?" + urlencode(params))
        payload = json.loads(raw)
        if payload.get("code") != 0 or not isinstance(payload.get("data"), dict):
            if payload.get("code") in {-101, -111}:
                raise VideoUnavailable("B站登录状态缺失或失效，请重新通过专用二维码授权")
            if payload.get("code") in {-352, -412, -403}:
                raise VideoUnavailable("B站仍限制当前服务器访问；专用登录授权不保证解除限制，请稍后重试")
            raise VideoUnavailable("视频信息暂不可用，可能需要平台登录")
        return payload["data"]


def _visible_title(value):
    if not isinstance(value, str):
        return ""
    return html.unescape(re.sub(r"</?em(?:\s[^>]*)?>", "", value, flags=re.IGNORECASE)).strip()


def _identity(value, *, title=False):
    text = unicodedata.normalize("NFKC", _visible_title(value)).casefold()
    if title:
        return "".join(char for char in text if char.isalnum())
    return "".join(text.split()).lstrip("@")


def _title_matches(observed, actual):
    visible, candidate = _identity(observed, title=True), _identity(actual, title=True)
    if len(visible) < 4:
        return False
    if visible == candidate:
        return True
    # A visibly truncated title may match a prefix; short or fuzzy titles cannot.
    return len(visible) >= 12 and observed.rstrip().endswith(("…", "...")) and candidate.startswith(visible)


def _search_bvid(http, title, uploader):
    if not isinstance(title, str) or not isinstance(uploader, str) or not 4 <= len(title.strip()) <= 300 or not 1 <= len(uploader.strip()) <= 100:
        raise VideoUnavailable("未看清完整的视频标题和UP主，请分享原视频链接后重试")
    query = title.strip().rstrip(".… ") + " " + uploader.strip()
    data = http.data("/x/web-interface/wbi/search/type", {
        "keyword": query, "search_type": "video", "page": 1, "page_size": 20,
    })
    matches = {item["bvid"] for item in (data.get("result") or [])[:20]
               if isinstance(item, dict) and BVID.fullmatch(str(item.get("bvid") or ""))
               and _identity(item.get("author")) == _identity(uploader)
               and _title_matches(title, item.get("title"))}
    if not matches:
        raise VideoUnavailable("未找到标题与UP主同时匹配的视频；已保留截图，可分享原链接后重试")
    if len(matches) != 1:
        raise VideoUnavailable("有多个标题与UP主相符的视频，暂无法确定原视频；请分享原链接")
    return matches.pop()


@dataclass
class VideoEvidence:
    source_url: str | None = None
    status: str = "none"
    error: str | None = None
    metadata: dict = field(default_factory=dict)
    captions: str = ""
    frames: list = field(default_factory=list)

    def model_context(self):
        return {"status": self.status, "sourceUrl": self.source_url,
                "metadata": self.metadata, "captions": self.captions,
                "frameTimesSeconds": [frame[0] for frame in self.frames],
                "limitations": "字幕仅代表平台提供的文字；画面为故事板抽样帧，不代表完整观看或已理解音频。",
                "error": self.error}


def _entries(snapshot, duration):
    entries = []
    for index, item in enumerate((snapshot.get("index") or [])[:20000]):
        try:
            stamp = float(item.get("timestamp") if isinstance(item, dict) else item)
            if math.isfinite(stamp) and stamp >= 0:
                entries.append((stamp, index))
        except (ValueError, TypeError):
            continue
    scale = 1000 if entries and duration > 0 and max(stamp for stamp, _ in entries) > duration * 1.5 else 1
    return [(stamp / scale, index) for stamp, index in entries]


def _frames(http, bvid, cid, duration):
    from PIL import Image
    snapshot = http.data("/x/player/videoshot", {"bvid": bvid, "cid": cid, "index": 1})
    entries = _entries(snapshot, duration)
    if not entries and snapshot.get("pvdata"):
        raw, _ = http.fetch(snapshot["pvdata"], media=True, limit=40000)
        if raw and len(raw) % 2 == 0:
            entries = [(float(stamp), index) for index, stamp in enumerate(struct.unpack(f">{len(raw) // 2}H", raw))]
    sheets = snapshot.get("image") or []
    if not entries or not sheets:
        return []
    covered = min(duration, max(stamp for stamp, _ in entries)) if duration > 0 else max(stamp for stamp, _ in entries)
    selected = dict((index, stamp) for stamp, index in (
        min(entries, key=lambda entry: abs(entry[0] - covered * fraction)) for fraction in (.25, .5, .75)
    ))
    width, height = int(snapshot.get("img_x_size") or 480), int(snapshot.get("img_y_size") or 270)
    if not 0 < width <= 1920 or not 0 < height <= 1080:
        raise VideoUnavailable("故事板画面尺寸无效")
    cache = {}

    def sheet(number):
        if number not in cache:
            if number >= len(sheets):
                raise VideoUnavailable("故事板缺少选中的画面")
            raw, _ = http.fetch(sheets[number], media=True, limit=5 * 1024 * 1024)
            image = Image.open(io.BytesIO(raw))
            if image.width * image.height > 20_000_000:
                raise VideoUnavailable("故事板图片尺寸过大")
            cache[number] = image
        return cache[number]

    try:
        first = sheet(0)
        columns, rows = first.width // width, first.height // height
        if columns < 1 or rows < 1:
            return []
        frames = []
        for index, stamp in selected.items():
            number, tile = divmod(index, columns * rows)
            source = sheet(number)
            x, y = (tile % columns) * width, (tile // columns) * height
            if x + width > source.width or y + height > source.height:
                raise VideoUnavailable("故事板画面超出图片范围")
            with source.crop((x, y, x + width, y + height)).convert("RGB") as frame:
                frame.thumbnail((640, 360))
                output = io.BytesIO()
                frame.save(output, format="JPEG", quality=80)
                frames.append((round(stamp, 1), base64.b64encode(output.getvalue()).decode()))
        return frames
    finally:
        for image in cache.values():
            image.close()


def collect_video(source_urls, *, detected_bvid=None, search_title=None, search_uploader=None, http=None):
    """Verify an observed ID or a unique title/uploader match before reading media."""
    source = next((url for url in source_urls if is_bilibili_url(url)), None)
    result = VideoEvidence(source_url=source or next(iter(source_urls), None))
    search = source is None and not (detected_bvid and BVID.fullmatch(detected_bvid)) and search_title and search_uploader
    if source is None and not (detected_bvid and BVID.fullmatch(detected_bvid)):
        if any(web_url(url) and any(urlsplit(url).hostname.lower() == domain or urlsplit(url).hostname.lower().endswith("." + domain)
                                   for domain in _OTHER_VIDEO_DOMAINS) for url in source_urls):
            result.status = "unavailable"
            result.error = "当前仅支持哔哩哔哩视频内容理解；此平台的原始链接和截图摘要已保留"
            return result
        if not search:
            return result
    result.status = "unavailable"
    try:
        http = http or PublicBiliHTTP()
        page = 1
        if source:
            resolved = source
            if urlsplit(source).hostname.lower() == "b23.tv":
                resolved = http.resolve(source)
            if not is_bilibili_url(resolved):
                raise VideoUnavailable("短链接未指向哔哩哔哩视频")
            parsed = urlsplit(resolved)
            match = re.search(r"/video/(BV[0-9A-Za-z]{10}|av[0-9]+)(?:/|$)", parsed.path)
            if not match:
                raise VideoUnavailable("原始链接中没有可验证的视频编号")
            identifier = match.group(1)
            page = int(parse_qs(parsed.query).get("p", [1])[0])
        else:
            identifier = _search_bvid(http, search_title, search_uploader) if search else detected_bvid
        params = {"bvid": identifier} if identifier.startswith("BV") else {"aid": identifier[2:]}
        info = http.data("/x/web-interface/view", params)
        bvid = str(info.get("bvid") or "")
        if not BVID.fullmatch(bvid) or (identifier.startswith("BV") and bvid != identifier):
            raise VideoUnavailable("视频编号未通过平台核验")
        if identifier.startswith("av") and str(info.get("aid")) != identifier[2:]:
            raise VideoUnavailable("视频编号未通过平台核验")
        if search and (not _title_matches(search_title, info.get("title")) or
                       _identity(search_uploader) != _identity((info.get("owner") or {}).get("name"))):
            raise VideoUnavailable("搜索结果与原视频的标题或UP主不一致，未采用该视频")
        pages = info.get("pages") or [{"cid": info.get("cid"), "duration": info.get("duration")}]
        if not 1 <= page <= len(pages):
            raise VideoUnavailable("原始链接指定的视频分段不存在")
        part = pages[page - 1]
        cid = int(part.get("cid") or 0)
        duration = float(part.get("duration") or info.get("duration") or 0)
        if cid <= 0:
            raise VideoUnavailable("平台没有返回有效视频分段")
        result.source_url = source or f"https://www.bilibili.com/video/{bvid}"
        result.metadata = {"bvid": bvid, "title": str(info.get("title") or "")[:300],
                           "part": page, "parts": len(pages), "durationSeconds": duration}
        if search:
            result.metadata.update(matchedBy="visible_title_and_uploader", uploader=info["owner"]["name"])
        caption_error = None
        try:
            player = http.data("/x/player/v2", {"bvid": bvid, "cid": cid})
            if player.get("need_login_subtitle"):
                caption_error = "平台字幕需要有效的B站专用登录授权；截图和原始链接已保留"
            tracks = player.get("subtitle", {}).get("subtitles", [])
            tracks = sorted(tracks, key=lambda track: not str(track.get("lan", "")).startswith("zh"))
            if tracks and tracks[0].get("subtitle_url"):
                raw, _ = http.fetch(tracks[0]["subtitle_url"], media=True, limit=1024 * 1024)
                body = json.loads(raw).get("body", [])
                if not math.isfinite(duration) or duration <= 0:
                    raise VideoUnavailable("字幕时间无法与视频分段核验，已弃用该字幕轨")
                latest = duration + max(3, duration * 0.02)
                # Validate the whole track before truncating text; keeping only
                # in-range lines could retain content from the wrong video.
                for segment in body:
                    start = float(segment["from"])
                    end = float(segment.get("to", start))
                    if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end < start or end > latest:
                        raise VideoUnavailable("平台字幕时间与视频分段不一致，已弃用该字幕轨")
                lines = []
                size = 0
                for segment in body[:3000]:
                    text = str(segment.get("content") or "").strip()[:1000]
                    if not text:
                        continue
                    line = f"[{float(segment.get('from') or 0):.1f}s] {text}"
                    size += len(line.encode("utf-8"))
                    if size > 60000:
                        break
                    lines.append(line)
                if lines and all(re.fullmatch(r"[♪♫\s]*(?:音乐|music|BGM)[♪♫\s]*", line.partition("] ")[2], re.IGNORECASE) for line in lines):
                    lines = []
                    caption_error = "平台字幕仅包含音乐标记，改用视频抽样画面"
                result.captions = "\n".join(lines)
        except VideoUnavailable as error:
            caption_error = str(error)
        except (OSError, ValueError, KeyError, TypeError, HTTPException):
            pass
        if not result.captions:
            result.frames = _frames(http, bvid, cid, duration)
        if result.captions or result.frames:
            result.status = "analyzed"
        else:
            result.error = caption_error or "平台未提供可读取的字幕或故事板画面；已保留截图摘要和原始链接"
    except VideoUnavailable as error:
        result.error = str(error)
    except Exception:
        # Network/provider diagnostics may contain signed URLs; expose only a safe reason.
        result.error = "暂未取得可理解的视频内容，可能受平台登录、风控或内容权限限制；可重试"
    return result
