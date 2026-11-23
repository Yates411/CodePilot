# Security Policy

## Local-First Privacy Guarantees

- **Zero Telemetry & Zero Prompt Uploads**: CodePilot never uploads prompts, session logs, file paths, or code snippets to any remote server.
- **Strictly Read-Only Ingestion**: Local SQLite databases (such as WorkBuddy WAL) are opened read-only via short-lived temporary snapshots so host tools are never locked or mutated.
- **macOS Keychain Storage**: Optional API keys (e.g., DeepSeek balance query key) are stored exclusively in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and never written to plain-text preferences or logs.
- **Hardened Unix Domain Socket**: `~/.codepilot/events.sock` enforces `0700` directory permissions, `0600` socket permissions, and `getpeereid` same-UID peer verification.
- **Strict Deep-Link Whitelisting**: Only explicitly validated `codex://threads/<safe-id>` and `claude://code/continue?session=<safe-id>` URLs are opened.

## Reporting a Vulnerability

If you discover a security issue (e.g., deep-link injection, socket privilege bypass, or credential leak), please **do not** open a public GitHub issue. Instead, report it privately via GitHub Security Advisories or contact the maintainers directly. We aim to acknowledge reports within 48 hours.
