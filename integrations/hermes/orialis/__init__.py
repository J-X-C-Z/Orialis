"""Orialis Agent Gateway platform plugin for Hermes."""

def register(ctx) -> None:
    """Register the capability-discovery tool and the Orialis platform adapter."""
    from .tools import register_tools
    from .adapter import register as register_platform

    register_tools(ctx)
    register_platform(ctx)


__all__ = ["register"]
