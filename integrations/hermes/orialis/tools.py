"""Validated, authenticated Orialis HTTP tools for Hermes."""
from __future__ import annotations

import asyncio
from datetime import datetime
import json
import logging
import os
from typing import Any, Dict, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen
from uuid import uuid4

logger = logging.getLogger(__name__)
CAPABILITIES_PATH = "/api/v1/capabilities"
MAX_RESPONSE_BYTES = 64 * 1024
HTTP_TIMEOUT_SECONDS = 10

PLUGIN_OPERATIONS = (
    {"name": "receive_message", "direction": "server_to_hermes", "protocol": "message.send", "description": "Receive an Orialis conversation message."},
    {"name": "send_reply", "direction": "hermes_to_server", "protocol": "message.reply", "description": "Send the Hermes response."},
    {"name": "acknowledge_message", "direction": "hermes_to_server", "protocol": "message.ack", "description": "Acknowledge receipt of an Orialis message."},
)

DOMAIN_CONTRACTS = {
    "task": {"domain":"Task", "resource":"/api/v1/tasks", "fields":["id","title","notes","important","urgent","completed","completedAt","due","dueTime","reminderMinutes","projectId","parentTaskId","scheduleId","recurrence","createdAt","updatedAt","version","deletedAt"], "callable":True, "tools":["list_tasks","create_task","update_task","delete_task"]},
    "project": {"domain":"Project", "resource":"/api/v1/projects", "fields":["id","name","goal","description","color","status","startDate","due","nextActionTaskId","manualPosition","createdAt","updatedAt","version"], "callable":True, "tools":["list_projects","create_project","update_project","delete_project","get_project_summary"]},
    "milestone": {"domain":"Milestone", "resource":"/api/v1/projects/{projectId}/milestones", "fields":["id","projectId","title","due","completed","completedAt","position","createdAt","updatedAt","version","deletedAt"], "callable":True, "tools":["list_milestones","create_milestone","get_milestone","update_milestone","delete_milestone"]},
    "schedule": {"domain":"Schedule", "resource":"/api/v1/schedules", "compatibility_resource":"/api/v1/calendar-events", "wire_entity_type":"calendar_event", "fields":["id","title","description","location","startAt","endAt","allDay","important","reminderMinutes","createdAt","updatedAt","version","deletedAt"], "callable":True, "tools":["list_schedules","create_schedule","get_schedule","update_schedule","delete_schedule","list_calendar_events","create_calendar_event","get_calendar_event","update_calendar_event","delete_calendar_event"]},
    "conversation": {"domain":"Conversation", "resource":"/api/v1/conversations", "fields":["id","title","pinned","manualPosition","isDefault","type","createdAt","updatedAt","version"], "callable":True, "tools":["list_conversations","create_conversation","update_conversation","delete_conversation"]},
    "message": {"domain":"Message", "resource":"/api/v1/conversations/{conversationId}/messages", "fields":["id","conversationId","role","content","createdAt","version","attachments","replyToMessageId","replyQuote","replyRole"], "callable":True, "tools":["list_messages","create_message"]},
}


def _schema(name: str, description: str, properties: Mapping[str, Any], required=()) -> Dict[str, Any]:
    return {"name": name, "description": description, "parameters": {"type":"object", "properties":dict(properties), "required":list(required), "additionalProperties":False}}

TEXT = {"type":"string", "minLength":1}
ID = {"type":"string", "minLength":1}
BASE = {"type":"integer", "minimum":1}
PAGE = {"after": {"type":["string","null"]}, "limit":{"type":"integer","minimum":1,"maximum":500}}

def _props(fields, *, nullable=()):
    result = {}
    for field, spec in fields.items():
        result[field] = {"type":[spec, "null"]} if field in nullable else {"type":spec}
    return result

TASK_FIELDS = {"title":"string","notes":"string","important":"boolean","urgent":"boolean","completed":"boolean","completedAt":"string","due":"string","dueTime":"string","reminderMinutes":"integer","projectId":"string","parentTaskId":"string","scheduleId":"string","recurrence":"object","manualPosition":"integer"}
PROJECT_FIELDS = {"name":"string","goal":"string","description":"string","color":"string","status":"string","startDate":"string","due":"string","nextActionTaskId":"string","manualPosition":"integer"}
SCHEDULE_FIELDS = {"title":"string","description":"string","location":"string","startAt":"string","endAt":"string","allDay":"boolean","important":"boolean","reminderMinutes":"integer"}
MILESTONE_FIELDS = {"title":"string","due":"string","completed":"boolean","position":"integer"}

CREATE_TASK_SCHEMA = _schema("create_task", "Create a task in Orialis.", _props(TASK_FIELDS, nullable=("notes","important","urgent","completedAt","due","dueTime","reminderMinutes","projectId","parentTaskId","scheduleId","recurrence")), ("title",))
CREATE_PROJECT_SCHEMA = _schema("create_project", "Create a project in Orialis.", _props(PROJECT_FIELDS, nullable=("goal","description","color","status","startDate","due","nextActionTaskId")), ("name",))
CREATE_SCHEDULE_SCHEMA = _schema("create_schedule", "Create a Schedule in the user's Orialis calendar.", _props(SCHEDULE_FIELDS, nullable=("description","location","reminderMinutes")), ("title","startAt","endAt"))
CREATE_MILESTONE_SCHEMA = _schema("create_milestone", "Create a project milestone.", _props(MILESTONE_FIELDS, nullable=("due","completed","position")), ("projectId","title"))
CREATE_CONVERSATION_SCHEMA = _schema("create_conversation", "Create a conversation.", {"title":TEXT,"id":ID,"pinned":{"type":"boolean"},"manualPosition":{"type":"integer"}}, ("title",))
CREATE_MESSAGE_SCHEMA = _schema("create_message", "Create a user message in a conversation.", {"conversationId":ID,"content":{"type":"string"},"id":ID,"replyToMessageId":ID,"attachments":{"type":"array"}}, ("conversationId","content"))
CAPABILITY_SCHEMA = _schema("orialis_capabilities", "Read Orialis server and plugin capabilities.", {})


def _http_url(server_url: str, path: str, query: Mapping[str, Any] | None = None) -> str:
    parsed = urlsplit(server_url.strip())
    if parsed.scheme not in {"ws","wss","http","https"} or not parsed.netloc:
        raise ValueError("ORIALIS_SERVER_URL must be an absolute ws:// or wss:// URL")
    scheme = {"ws":"http","wss":"https"}.get(parsed.scheme, parsed.scheme)
    query_string = urlencode([(k, str(v)) for k,v in (query or {}).items() if v is not None])
    return urlunsplit((scheme, parsed.netloc, path, query_string, ""))

def _http_capabilities_url(server_url: str) -> str: return _http_url(server_url, CAPABILITIES_PATH)
def _http_schedules_url(server_url: str) -> str: return _http_url(server_url, "/api/v1/schedules")
def _display_server_url(server_url: str) -> str | None:
    if not server_url: return None
    try:
        p=urlsplit(server_url); return urlunsplit((p.scheme,p.netloc,p.path,"",""))
    except ValueError: return "[invalid URL]"

def _timestamp(value: Any, field: str) -> None:
    if not isinstance(value, str): raise ValueError(f"{field} must be an RFC 3339 timestamp")
    try: parsed=datetime.fromisoformat(value.replace("Z","+00:00"))
    except ValueError as exc: raise ValueError(f"{field} must be an RFC 3339 timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None: raise ValueError(f"{field} must include a timezone")

def _validate_args(args: Any, allowed: set[str], required=()) -> dict[str, Any]:
    if not isinstance(args, dict) or set(args)-allowed: raise ValueError("arguments contain unsupported fields")
    for field in required:
        if field not in args or not isinstance(args[field], str) or not args[field].strip(): raise ValueError(f"{field} is required")
    return dict(args)

def _validate_schedule_args(args: Dict[str, Any]) -> Dict[str, Any]:
    out=_validate_args(args,set(SCHEDULE_FIELDS)|{"id"},{"title","startAt","endAt"})
    out["title"]=out["title"].strip(); _timestamp(out["startAt"],"startAt"); _timestamp(out["endAt"],"endAt")
    if datetime.fromisoformat(out["startAt"].replace("Z","+00:00")) >= datetime.fromisoformat(out["endAt"].replace("Z","+00:00")): raise ValueError("startAt must be earlier than endAt")
    for f in ("allDay","important"):
        if f in out and not isinstance(out[f],bool): raise ValueError(f"{f} must be a boolean")
    if "reminderMinutes" in out and (out["reminderMinutes"] is not None and (isinstance(out["reminderMinutes"],bool) or not isinstance(out["reminderMinutes"],int) or out["reminderMinutes"]<0)): raise ValueError("reminderMinutes must be a non-negative integer or null")
    out.setdefault("id",str(uuid4())); return out

def _validate_payload(kind: str, args: Any, *, patch=False, delete=False, project_id=False, conversation_id=False) -> dict[str,Any]:
    fields={"task":TASK_FIELDS,"project":PROJECT_FIELDS,"schedule":SCHEDULE_FIELDS,"milestone":MILESTONE_FIELDS,"conversation":{"title":"string","pinned":"boolean","manualPosition":"integer"},"message":{"content":"string","id":"string","replyToMessageId":"string","attachments":"array"}}[kind]
    allowed=set(fields)|({"baseVersion"} if patch or delete else set())|({"id"} if kind in {"task","project","schedule","conversation","message"} and not patch and not delete else set())
    out=_validate_args(args,allowed)
    if (patch or delete) and "baseVersion" not in out: raise ValueError("baseVersion is required")
    if "baseVersion" in out and (isinstance(out["baseVersion"],bool) or not isinstance(out["baseVersion"],int) or out["baseVersion"]<1): raise ValueError("baseVersion must be a positive integer")
    required_create={"task":("title",),"project":("name",),"milestone":("title",),"conversation":("title",),"message":()}.get(kind,())
    if not patch and not delete:
        for field in required_create:
            if field not in out or not isinstance(out[field],str) or not out[field].strip(): raise ValueError(f"{field} is required")
    for f in ("title","name","content"):
        if f in out and (not isinstance(out[f],str) or not out[f].strip()): raise ValueError(f"{f} must be a non-empty string")
    for f in ("startAt","endAt"):
        if f in out: _timestamp(out[f],f)
    if "startAt" in out and "endAt" in out and datetime.fromisoformat(out["startAt"].replace("Z","+00:00"))>=datetime.fromisoformat(out["endAt"].replace("Z","+00:00")): raise ValueError("startAt must be earlier than endAt")
    return out

def _request(server_url: str, token: str, method: str, path: str, *, payload=None, query=None) -> dict[str,Any]:
    body=None if payload is None else json.dumps(payload,ensure_ascii=False).encode()
    req=Request(_http_url(server_url,path,query), data=body, method=method, headers={"Accept":"application/json","Authorization":f"Bearer {token}","User-Agent":"orialis-hermes-plugin/0.2.0", **({"Content-Type":"application/json"} if body is not None else {})})
    try:
        with urlopen(req,timeout=HTTP_TIMEOUT_SECONDS) as response: raw=response.read(MAX_RESPONSE_BYTES+1); status=response.status
    except HTTPError as exc: return {"ok":False,"error":f"server returned HTTP {exc.code}"}
    except (URLError,TimeoutError,OSError) as exc: logger.warning("Orialis HTTP request failed: %s",exc); return {"ok":False,"error":"Orialis server request failed; the server could not be reached"}
    if len(raw)>MAX_RESPONSE_BYTES: return {"ok":False,"error":"server response is too large"}
    if status==204 or not raw: return {"ok":True,"status":status}
    try: data=json.loads(raw.decode())
    except (UnicodeDecodeError,json.JSONDecodeError): return {"ok":False,"error":"server returned invalid JSON"}
    return {"ok":status<300,"status":status,"data":data} if status<300 else {"ok":False,"status":status,"error":data.get("message","server request failed") if isinstance(data,dict) else "server request failed"}

def _post_schedule(server_url: str, token: str, payload: Dict[str, Any]) -> dict[str, Any]:
    result = _request(server_url, token, "POST", "/api/v1/schedules", payload=payload)
    return {"ok": True, "schedule": result.get("data")} if result.get("ok") else result

def _fetch_server_capabilities(server_url: str) -> dict[str, Any]:
    return _request(server_url, os.getenv("ORIALIS_DEVICE_TOKEN", "").strip(), "GET", CAPABILITIES_PATH)

def _env() -> tuple[str,str] | tuple[None,None]:
    server=os.getenv("ORIALIS_SERVER_URL","").strip(); token=os.getenv("ORIALIS_DEVICE_TOKEN","").strip()
    return (server,token) if server and token else (None,None)

async def _handle_request(args, method, path, *, kind=None, payload=True, query=None):
    try:
        server,token=_env()
        if not server: return {"ok":False,"error":"ORIALIS_SERVER_URL and ORIALIS_DEVICE_TOKEN are required"}
        if kind: args=_validate_payload(kind,args,patch=method=="PATCH",delete=method=="DELETE")
        result=await asyncio.to_thread(_request,server,token,method,path,payload=args if payload and method not in {"GET","DELETE"} else (args if method=="DELETE" else None),query=query or (args if method=="GET" else None))
        if result.get("ok") and "data" in result: result["result"]=result.pop("data")
        return result
    except (ValueError,KeyError) as exc: return {"ok":False,"error":str(exc)}

async def handle_create_schedule(args, **_kwargs):
    try: payload=_validate_schedule_args(args)
    except ValueError as exc: return json.dumps({"ok":False,"error":str(exc)})
    server,token=_env()
    if not server or not token: return json.dumps({"ok":False,"error":"ORIALIS_DEVICE_TOKEN is required to create a Schedule"})
    result=await asyncio.to_thread(_post_schedule,server,token,payload)
    return json.dumps(result,ensure_ascii=False,separators=(",",":"))

async def handle_capabilities(args, **_kwargs):
    del args; server=os.getenv("ORIALIS_SERVER_URL","").strip()
    discovery=await asyncio.to_thread(_fetch_server_capabilities,server) if server else {"ok":False,"error":"ORIALIS_SERVER_URL is not configured"}
    result={"ok":True,"plugin":{"name":"orialis-hermes","version":"0.2.0","operations":list(PLUGIN_OPERATIONS),"tools":TOOL_NAMES,"domain_contracts":DOMAIN_CONTRACTS},"server":{"url":_display_server_url(server),"discovery":discovery}}
    if discovery.get("ok"):
        payload=discovery.get("payload", discovery.get("data", {}))
        result["server"]["capabilities"]=payload.get("capabilities",[]); result["server"]["api_version"]=payload.get("api_version")
    return json.dumps(result,ensure_ascii=False,separators=(",",":"))

async def _tool(args, method, path, **kwargs): return json.dumps(await _handle_request(args,method,path,**kwargs),ensure_ascii=False,separators=(",",":"))

def _make(name, method, path, kind=None, transform=None):
    async def handler(args, **_kwargs):
        if transform: path_value=transform(args); return await _tool(args,method,path_value,kind=kind)
        path_value=path
        if isinstance(args, dict):
            path_fields = {field for field in ("id", "projectId", "conversationId") if "{"+field+"}" in path}
            for field in path_fields:
                value = args.get(field)
                if not isinstance(value, str) or not value.strip():
                    return json.dumps({"ok":False,"error":"resource identifier is required"})
                path_value=path_value.replace("{"+field+"}", quote(value, safe=""))
            clean={k:v for k,v in args.items() if k not in path_fields}
        else:
            clean=args
        if "{" in path_value: return json.dumps({"ok":False,"error":"resource identifier is required"})
        # GET list/query arguments are query parameters, not resource payloads.
        if method == "GET": return await _tool(clean, method, path_value, kind=None, query=clean)
        if method == "DELETE": clean={"baseVersion": args.get("baseVersion")} if isinstance(args,dict) else args
        return await _tool(clean,method,path_value,kind=kind)
    handler.__name__="handle_"+name; return handler

TOOL_NAMES=["orialis_capabilities"]
HANDLERS={"orialis_capabilities":(CAPABILITY_SCHEMA,handle_capabilities)}
def _add(name,schema,method,path,kind=None,transform=None): TOOL_NAMES.append(name); HANDLERS[name]=(schema,_make(name,method,path,kind,transform))

# List endpoints retain the server's pagination/filter query contract.
for name, path, kind, props in [("list_tasks","/api/v1/tasks","task",PAGE),("list_projects","/api/v1/projects","project",{**PAGE,"status":{"type":"string"}}),("list_schedules","/api/v1/schedules","schedule",{**PAGE,"from":{"type":"string"},"to":{"type":"string"}}),("list_calendar_events","/api/v1/calendar-events","schedule",{**PAGE,"from":{"type":"string"},"to":{"type":"string"}}),("list_conversations","/api/v1/conversations",None,{} )]:
    _add(name,_schema(name,"List Orialis resources.",props),"GET",path,kind)
_add("list_milestones",_schema("list_milestones","List milestones for a project.",{"projectId":ID,**PAGE},("projectId",)),"GET","/api/v1/projects/{projectId}/milestones","milestone")
# Resource-specific CRUD uses explicit path fields.
_add("create_task",CREATE_TASK_SCHEMA,"POST","/api/v1/tasks","task"); _add("update_task",_schema("update_task","Update a task using optimistic concurrency.",{**_props(TASK_FIELDS),"id":ID,"baseVersion":BASE},("id","baseVersion")),"PATCH","/api/v1/tasks/{id}","task"); _add("delete_task",_schema("delete_task","Delete a task using optimistic concurrency.",{"id":ID,"baseVersion":BASE},("id","baseVersion")),"DELETE","/api/v1/tasks/{id}","task")
_add("create_project",CREATE_PROJECT_SCHEMA,"POST","/api/v1/projects","project"); _add("update_project",_schema("update_project","Update a project.",{**_props(PROJECT_FIELDS),"id":ID,"baseVersion":BASE},("id","baseVersion")),"PATCH","/api/v1/projects/{id}","project"); _add("delete_project",_schema("delete_project","Delete a project.",{"id":ID,"baseVersion":BASE},("id","baseVersion")),"DELETE","/api/v1/projects/{id}","project"); _add("get_project_summary",_schema("get_project_summary","Read a project summary.",{"id":ID},("id",)),"GET","/api/v1/projects/{id}/summary")
_add("create_milestone",CREATE_MILESTONE_SCHEMA,"POST","/api/v1/projects/{projectId}/milestones","milestone"); _add("get_milestone",_schema("get_milestone","Read a milestone.",{"projectId":ID,"id":ID},("projectId","id")),"GET","/api/v1/projects/{projectId}/milestones/{id}","milestone"); _add("update_milestone",_schema("update_milestone","Update a milestone.",{**_props(MILESTONE_FIELDS),"projectId":ID,"id":ID,"baseVersion":BASE},("projectId","id","baseVersion")),"PATCH","/api/v1/projects/{projectId}/milestones/{id}","milestone"); _add("delete_milestone",_schema("delete_milestone","Delete a milestone.",{"projectId":ID,"id":ID,"baseVersion":BASE},("projectId","id","baseVersion")),"DELETE","/api/v1/projects/{projectId}/milestones/{id}","milestone")
for prefix in ("schedule","calendar_event"):
    root="/api/v1/schedules" if prefix=="schedule" else "/api/v1/calendar-events"; label="schedule" if prefix=="schedule" else "calendar event"
    _add("create_"+prefix,CREATE_SCHEDULE_SCHEMA,"POST",root,"schedule")
    _add("get_"+prefix,_schema("get_"+prefix,"Read a "+label+".",{"id":ID},("id",)),"GET",root+"/{id}","schedule")
    _add("update_"+prefix,_schema("update_"+prefix,"Update a "+label+".",{**_props(SCHEDULE_FIELDS),"id":ID,"baseVersion":BASE},("id","baseVersion")),"PATCH",root+"/{id}","schedule")
    _add("delete_"+prefix,_schema("delete_"+prefix,"Delete a "+label+".",{"id":ID,"baseVersion":BASE},("id","baseVersion")),"DELETE",root+"/{id}","schedule")
_add("create_conversation",CREATE_CONVERSATION_SCHEMA,"POST","/api/v1/conversations"); _add("update_conversation",_schema("update_conversation","Rename/update a conversation.",{"id":ID,"title":TEXT,"pinned":{"type":"boolean"},"manualPosition":{"type":"integer"},"baseVersion":BASE},("id","title","baseVersion")),"PATCH","/api/v1/conversations/{id}","conversation"); _add("delete_conversation",_schema("delete_conversation","Delete a conversation.",{"id":ID,"baseVersion":BASE},("id","baseVersion")),"DELETE","/api/v1/conversations/{id}","conversation")
_add("list_messages",_schema("list_messages","List messages in a conversation.",{"conversationId":ID,**PAGE},("conversationId",)),"GET","/api/v1/conversations/{conversationId}/messages"); _add("create_message",CREATE_MESSAGE_SCHEMA,"POST","/api/v1/conversations/{conversationId}/messages","message")

# Creation of schedules retains its stricter timestamp validation and legacy response shape.
HANDLERS["create_schedule"]=(CREATE_SCHEDULE_SCHEMA, handle_create_schedule)

def register_tools(ctx: Any) -> None:
    for name in TOOL_NAMES:
        schema,handler=HANDLERS[name]
        ctx.register_tool(name=name,toolset="orialis",schema=schema,handler=handler,is_async=True,emoji="🔗" if name=="orialis_capabilities" else "🗂️")
