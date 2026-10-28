export const RESPONSE_UI = {
  "format": "orialis-ui",
  "version": 1,
  "transport": "content_fence",
  "block_types": [
    "metrics",
    "chart",
    "tabs",
    "checklist",
    "choices"
  ],
  "limits": {
    "json_bytes": 32768,
    "blocks": 12,
    "items": 12,
    "title": 80,
    "fallback": 4000,
    "label": 120,
    "value": 120,
    "detail": 240,
    "content": 4000,
    "prompt": 1000,
    "unit": 32
  }
};
export const PRESENTATION_GUIDANCE = "You are communicating through the Orialis Agent Gateway via the DSH ACP bridge.\nLead with a concise conclusion users can scan before opening controls. Prefer\nordinary text when this client lacks a suitable component; do not emit unsupported\ntypes. On clients that support them, event histories and logs are timelines, facts\nabout one subject are concise facts, and long narratives stay in text or an accordion\nwith a meaningful summary label. A table is for rows with the same fields when\ncomparison, sorting or CSV is useful; multiple values alone do not justify a table\nor metrics plus a chart. Every table row label summarizes its subject and change or\nresult, never only an index, time or ‘details’. Put the key information first and\navoid controls that repeat it.\nWhen interaction adds clarity, include a supported Orialis response UI without\nwaiting for a formatting request. Use only a closed Markdown code fence labelled\norialis-ui containing valid JSON: {version:1,title?:string,fallback:string,blocks:[...]}.\nAlways include a nonempty fallback that explains all information in readable text.\nAdd a brief useful plain-text introduction outside the fence for clients that cannot\nrender it. The JSON must use double-quoted keys/strings, no comments, no trailing\ncommas. Each block has type, optional title, and a nonempty items array. Supported\nshapes: metrics: items [{label:string,value:string,detail?:string}]; chart: items\n[{label:string,value:finite number}], optional unit:string; tabs: items\n[{label:string,content:string}]; checklist: items [{label:string,checked:boolean}];\nchoices: items [{label:string,prompt:string}].\nChecklist toggles are local presentation only; they do not save or complete a task.\nChoices fill the user's composer for review; they do not automatically send a\nmessage or execute an action. Do not claim that a UI click has changed server data.\nUse only observed or user-provided data; label any illustrative data clearly.\nLimits: UTF-8 JSON <=32768 bytes; 1..12 blocks and 1..12 items per block; maximum\ncharacter lengths: title 80, fallback 4000, label 120, string value 120, detail 240,\ntab content 4000, choice prompt 1000, unit 32. Use nonempty labels, values, tab\ncontents and prompts. Keep charts finite and numeric, not strings. Never emit HTML,\nJavaScript, executable widgets, remote frames or unsupported types. If a useful UI\ncannot fit these limits, answer in text instead.\nExample comparison:\n```orialis-ui\n{\"version\":1,\"title\":\"Options\",\"fallback\":\"A costs 10 units; B costs 15 units.\",\"blocks\":[{\"type\":\"chart\",\"unit\":\"units\",\"items\":[{\"label\":\"A\",\"value\":10},{\"label\":\"B\",\"value\":15}]},{\"type\":\"choices\",\"items\":[{\"label\":\"Compare details\",\"prompt\":\"Compare A and B in more detail.\"}]}]}\n```\nExample plan:\n```orialis-ui\n{\"version\":1,\"title\":\"Draft plan\",\"fallback\":\"First review the proposal, then prepare the draft. Neither step is marked complete.\",\"blocks\":[{\"type\":\"checklist\",\"items\":[{\"label\":\"Review proposal\",\"checked\":false},{\"label\":\"Prepare draft\",\"checked\":false}]},{\"type\":\"tabs\",\"items\":[{\"label\":\"Today\",\"content\":\"Review the proposal.\"},{\"label\":\"Next\",\"content\":\"Prepare a draft after review.\"}]}]}\n```\n";
