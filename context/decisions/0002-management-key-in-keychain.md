# 0002: Management key in Keychain only

- **Date:** 2026-10-02
- **Status:** accepted

## Context
The Management API needs `Authorization: Bearer <key>`; the proxy config only stores a bcrypt hash, so the key can't be recovered.

## Decision
The user pastes the key in Settings; it is stored only in the login Keychain (service `dev.ksotis.dynamic-island`), never on disk, in UserDefaults or logs. Base URL must be loopback http or https; non-loopback asks for confirmation. Redirects refused; 8 MiB response cap.

## Alternatives considered
Reading the config (impossible: hash only); storing in UserDefaults (insecure).

## Consequences
Without a key nothing is polled (root cause of the 'usage is missing' report).
