# Show quota per account and live usage

**Statement:** Show (1) quota per logged-in account (provider, label, remaining/used vs limit, reset time, cooldown/rate-limited status) and (2) usage: requests and tokens. User picked these two only.

**Source:** Initial brief, 2026-10-02.

**Status:** current (usage part refined by 08)

**Where in code:** `Sources/IslandCore/AccountMapper.swift`, `QuotaParsing.swift`, `DashboardView.swift` (Limits)
