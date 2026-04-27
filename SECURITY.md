# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Previous release | Security fixes only |
| Older releases | No |

## Reporting a Vulnerability

If you discover a security vulnerability in iClaw, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, send an email to **hello@last-byte.org** with:

- A description of the vulnerability
- Steps to reproduce the issue
- The potential impact
- Any suggested fixes (optional)

## Response Timeline

- **Acknowledgement**: Within 48 hours of receiving the report
- **Assessment**: Within 1 week, we will confirm whether the issue is valid and its severity
- **Fix**: Critical issues will be prioritized for the next release; lower severity issues will be scheduled accordingly
- **Disclosure**: We will coordinate with the reporter on public disclosure timing

## Scope

iClaw runs entirely on-device with no cloud AI calls. The primary security considerations are:

- Local data storage (SQLite database, UserDefaults)
- Network requests made by tools (web search, fetch, API calls)
- AppleScript automation (Automate tool)
- File system access (Read/Write tools)
- Inter-process communication (Browser Bridge, Native Messaging)
- CloudKit Continuity (cross-device tool execution)

## Recognition

We appreciate responsible disclosure and will credit reporters in release notes (unless anonymity is preferred).
