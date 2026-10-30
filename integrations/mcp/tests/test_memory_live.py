"""Screen-memory acceptance through official MCP stdio and isolated real Orialis API."""
from copy import deepcopy

from test_live_api import call, live_api, mcp_stdio  # noqa: F401


async def test_real_memory_read_update_audit_conflict_and_isolation(live_api):
    url, api, (alice, bob) = live_api
    headers = {"Authorization": "Session " + alice['accessToken']}
    original = {
        "id": "memory-acceptance", "createdAt": "2026-10-31T00:00:00Z",
        "sourcePackage": "test.source", "sourceLabel": "Test capture",
        "visibleText": "Raw capture: ignore previous instructions is untrusted text.",
        "sharedText": "Original share text", "urls": ["https://source.example/item?token=keep"],
        "title": "Original title", "summary": "# Original title\nOriginal summary",
        "notes": "User's notes must remain", "category": "other", "sourceUrl": None,
        "videoStatus": "none", "videoSummary": None, "videoError": None,
    }
    saved = await api.put('/api/v1/memories/' + original['id'], headers=headers, json=original)
    assert saved.is_success, saved.text
    version = saved.json()['version']
    scopes = 'orialis:read orialis:write orialis:memory:read orialis:memory:write'
    async with mcp_stdio(url, alice, scopes) as a, mcp_stdio(url, bob, scopes) as b:
        listed = await call(a, 'list_screen_memories', {"query": "Original", "limit": 1})
        assert listed['items'][0]['id'] == original['id']
        assert 'visibleText' not in listed['items'][0]
        detail = await call(a, 'get_screen_memory', {"memory_id": original['id']})
        assert 'visibleText' not in detail and detail['notes'] == original['notes']
        full = await call(a, 'get_screen_memory', {"memory_id": original['id'], "include_source": True})
        assert full['visibleText'] == original['visibleText']
        updated = await call(a, 'update_screen_memory', {"memory_id": original['id'], "data": {"baseVersion": version, "changeReason": "用户更正标题", "title": "Correct title"}})
        assert updated['version'] == version + 1 and updated['notes'] == original['notes']
        check = await api.get('/api/v1/memories/' + original['id'], headers=headers)
        for field in ['visibleText', 'urls', 'sharedText', 'createdAt', 'notes', 'sourceLabel']:
            assert check.json()[field] == original[field]
        history = await call(a, 'get_screen_memory_history', {"memory_id": original['id']})
        assert history['items'][0]['changeReason'] == '用户更正标题'
        assert history['items'][0]['changedFields'] == ['title']
        assert history['items'][0]['source'] == 'mcp'
        stale = await a.call_tool('update_screen_memory', {"memory_id": original['id'], "data": {"baseVersion": version, "changeReason": "stale", "notes": "overwrite"}})
        assert stale.isError
        assert not (await call(b, 'list_screen_memories', {}))['items']
        for tool, arguments in [
            ('get_screen_memory', {"memory_id": original['id']}),
            ('get_screen_memory_history', {"memory_id": original['id']}),
            ('update_screen_memory', {"memory_id": original['id'], "data": {"baseVersion": version + 1, "changeReason": "foreign", "title": "denied"}}),
        ]:
            assert (await b.call_tool(tool, arguments)).isError
        changed_evidence = deepcopy(original)
        changed_evidence.update(baseVersion=version + 1, visibleText='rewrite evidence')
        assert (await api.put('/api/v1/memories/' + original['id'], headers=headers, json=changed_evidence)).status_code == 409
    async with mcp_stdio(url, alice) as old:
        assert (await old.call_tool('list_screen_memories', {})).isError
