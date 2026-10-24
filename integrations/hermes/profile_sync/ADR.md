# ADR: Keep Hermes execution local while syncing curated profile files

Status: adopted for this implementation.

Each device runs its own Hermes gateway and tools. A separately operated SSH hub retains content-addressed history while clients periodically reconcile curated profile files against their last applied base. This separates portable skills, SOUL and selected long-term memories from device-local authentication, configuration, session history and runtime dependencies.

The hub avoids making a personal laptop a mandatory relay. Offline deletion uses the saved base; concurrent text edits merge where possible, while unresolved edits preserve local content and both historical objects. Atomic replacement, memory locks and materialized skill links preserve local writers and external skill libraries.

The trade-off is that hub unavailability delays exchange and installed dependencies remain each device's responsibility. Trigger intervals do not guarantee completion time. Running conversations are not reset to load a new prompt. Cloud-memory backends and credentials are independently configured; this component neither migrates them nor automatically retains whole conversations.

This public artifact includes only code, synthetic tests and configurable templates. Private bootstrap archives, real profile contents, host inventories, credentials and operational diagnostics are excluded.
