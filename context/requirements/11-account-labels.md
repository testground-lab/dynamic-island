# Never show raw auth file names

**Statement:** An account renders as email, else label, else account field (".json" stripped), else "<Provider> · <last 4 of id>". Approved by the user from the v3 snapshots ("disabled.json" was showing).

**Source:** User approval, 2026-10-02.

**Status:** current

**Where in code:** `IslandCore/AccountMapper.swift` (`label(for:)`), `UsageStore` labels
