"""Keep recognizable date/time agendas out of a single calendar event."""

import re

EVENT_GRANULARITY_RULES = (
    "One event per activity in each date/time slot, including separate activities on the same day. "
    "Before writing, split the source into individual occurrences with their own title, startAt, endAt and location. "
    "For example, morning West Lake photography, noon campus visit, outbound train and return train are separate events. "
    "Never create a trip-summary event spanning the first departure to the final return, or hide other dates/time slots in description. "
    "Description may contain only details for that event. A single continuous overnight train or other continuous activity may cross midnight. "
    "Missing times must be clarified or left pending, never invented or replaced by a multi-day/all-day placeholder. "
    "After writing, read back every saved event and report each title and time separately; do not report a summary event as successful splitting."
)

# shortcut: recognizes explicit agenda headings, not arbitrary prose; expand only for observed missed formats.
_AGENDA_HEADING = re.compile(
    r"(?:^|[\n;；])\s*(?:[-*•]\s*)?"
    r"(?P<label>"
    r"(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[/月]\d{1,2}日?)"
    r"\s*(?:[（(](?:周|星期)[一二三四五六日天][）)])?\s*[:：]"
    r"|(?:[01]?\d|2[0-3])[:：][0-5]\d"
    r"(?:\s*[-—–~～至到]\s*(?:[01]?\d|2[0-3])[:：][0-5]\d)?"
    r"|(?:清晨|早晨|早上|上午|中午|午后|下午|傍晚|晚上|夜间|凌晨)"
    r")\s*[:：]?\s*[^\s:：;；\n]",
    re.MULTILINE,
)


def validate_event_description(description: str | None) -> str | None:
    if description and len(list(_AGENDA_HEADING.finditer(description))) >= 2:
        raise ValueError(
            "split_required: description contains multiple date/time agenda entries. "
            "Create one event per activity and time slot, each with its own title, startAt/endAt and location; "
            "keep only that event's details in description. Ask for missing times; do not invent them."
        )
    return description
