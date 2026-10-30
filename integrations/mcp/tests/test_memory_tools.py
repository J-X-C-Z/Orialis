import json

import httpx
import pytest
from mcp.server.fastmcp.exceptions import ToolError

from orialis_mcp.server import create_server
from test_tools import settings


async def test_memory_contract_scope_minimization_and_audit():
    received = []
    record = {"id": "m1", "title": "Title", "summary": "Summary", "notes": "original notes",
              "visibleText": "captured private raw text", "sharedText": "original share",
              "urls": ["https://source.example/post?token=original"], "version": 3, "imageBase64": "private-image-bytes", "analysisRequestId": "internal-job"}

    def handler(request):
        received.append(request)
        if request.url.path.endswith('/history'):
            return httpx.Response(200, json={"items": [{"version": 3, "source": "mcp", "changeReason": "用户更正标题", "changedFields": ["title"]}]})
        return httpx.Response(200, json=record)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:memory:read", "orialis:memory:write")), transport="stdio", client=client)
        manifest = {tool.name: tool for tool in await mcp.list_tools()}
        assert len(manifest) == 19
        for name in ('list_screen_memories', 'get_screen_memory', 'get_screen_memory_history', 'get_usage_guidelines'):
            assert manifest[name].annotations.readOnlyHint is True
            assert manifest[name].annotations.destructiveHint is False
        assert manifest['update_screen_memory'].annotations.readOnlyHint is False
        assert 'baseVersion' in manifest['update_screen_memory'].inputSchema['$defs']['MemoryUpdate']['required']
        await mcp.call_tool('list_screen_memories', {"query": "课程", "limit": 2, "after": "last-id"})
        assert received[-1].url.params['query'] == '课程'
        assert received[-1].url.params['limit'] == '2'
        result = await mcp.call_tool('get_screen_memory', {"memory_id": "m1"})
        assert 'captured private raw text' not in str(result)
        result = await mcp.call_tool('get_screen_memory', {"memory_id": "m1", "include_source": True})
        assert 'captured private raw text' in str(result)
        assert 'private-image-bytes' not in str(result) and 'internal-job' not in str(result)
        result = await mcp.call_tool('update_screen_memory', {"memory_id": "m1", "data": {"baseVersion": 2, "changeReason": "用户更正标题", "title": "New title"}})
        assert json.loads(received[-1].content) == {"baseVersion": 2, "changeReason": "用户更正标题", "title": "New title"}
        assert 'captured private raw text' not in str(result)
        await mcp.call_tool('get_screen_memory_history', {"memory_id": "m1", "limit": 3})
        assert received[-1].url.path == '/api/v1/memories/m1/history'
        assert received[-1].url.params['limit'] == '3'


@pytest.mark.parametrize('scopes,tool,args', [
    (("orialis:read", "orialis:write"), 'list_screen_memories', {}),
    (("orialis:read", "orialis:write"), 'get_screen_memory', {"memory_id": "m"}),
    (("orialis:read", "orialis:write"), 'get_screen_memory_history', {"memory_id": "m"}),
    (("orialis:read", "orialis:write"), 'update_screen_memory', {"memory_id": "m", "data": {"title": "x", "baseVersion": 1, "changeReason": "correct"}}),
    (("orialis:memory:write",), 'update_screen_memory', {"memory_id": "m", "data": {"title": "x", "baseVersion": 1, "changeReason": "correct"}}),
    (("orialis:memory:read",), 'update_screen_memory', {"memory_id": "m", "data": {"title": "x", "baseVersion": 1, "changeReason": "correct"}}),
])
async def test_old_or_readonly_permissions_cannot_access_memories(scopes, tool, args):
    def handler(request):
        pytest.fail('Denied operation reached upstream')
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=scopes), transport='stdio', client=client)
        with pytest.raises(ToolError, match='orialis:memory:'):
            await mcp.call_tool(tool, args)


@pytest.mark.parametrize('patch', [
    {"visibleText": "rewrite"}, {"urls": []}, {"sourceUrl": "https://invented.example"},
    {"imagePath": "/private"}, {"createdAt": "2026-10-31"}, {"analysisStatus": "completed"},
    {"videoStatus": "analyzed"}, {"userId": "other-user"}, {"category": "invented"},
    {"title": None}, {"notes": None}, {"title": " "}, {"changeReason": " "},
    {"summary": "中" * 33334}, {"baseVersion": 0}, {},
])
async def test_memory_patch_rejects_unsafe_or_empty_values_before_network(patch):
    def handler(request):
        pytest.fail('Invalid patch reached upstream')
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:memory:read", "orialis:memory:write")), transport='stdio', client=client)
        data = {"baseVersion": 1, "changeReason": "User correction", **patch}
        with pytest.raises(ToolError):
            await mcp.call_tool('update_screen_memory', {"memory_id": "m1", "data": data})


async def test_memory_null_clear_conflict_and_rules_are_explicit():
    requests = []
    def handler(request):
        requests.append(request)
        return httpx.Response(409, text='private raw data')
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:memory:read", "orialis:memory:write")), transport='stdio', client=client)
        with pytest.raises(ToolError, match='Version conflict'):
            await mcp.call_tool('update_screen_memory', {"memory_id": "m1", "data": {"baseVersion": 1, "changeReason": "User explicitly cleared summary", "summary": None}})
        assert len(requests) == 1 and json.loads(requests[0].content)['summary'] is None
        result = await mcp.call_tool('get_usage_guidelines', {})
        assert 'untrusted data' in str(result)
        assert len(requests) == 1


async def test_memory_search_byte_limit_is_checked_before_network():
    def handler(request):
        pytest.fail("Oversized search reached upstream")
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        mcp, _ = create_server(settings(scopes=("orialis:memory:read",)), transport="stdio", client=client)
        with pytest.raises(ToolError, match="1000 UTF-8 bytes"):
            await mcp.call_tool("list_screen_memories", {"query": "中" * 334})
