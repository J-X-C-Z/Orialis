"""Stable mapping between Orialis conversations and Hermes chat/session IDs."""

from urllib.parse import quote, unquote


CHAT_ID_PREFIX = "orialis:"


def chat_id_for_conversation(conversation_id: str) -> str:
    """Return a stable Hermes chat ID for one Orialis conversation.

    The encoded suffix keeps the mapping reversible while preventing separators in an
    Orialis ID from changing Hermes' session-key layout.
    """
    value = str(conversation_id)
    if not value.strip():
        raise ValueError("conversation_id is required")
    return CHAT_ID_PREFIX + quote(value, safe="")


def conversation_id_for_chat_id(chat_id: str) -> str:
    """Decode a chat ID created by :func:`chat_id_for_conversation`."""
    value = str(chat_id)
    if not value.startswith(CHAT_ID_PREFIX):
        return value
    return unquote(value[len(CHAT_ID_PREFIX):])
