# Security Policy

Rewinder records your screen — treat its security seriously, and so do we.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting: **Security tab →
"Report a vulnerability"** on this repository. Reports are reviewed as
quickly as possible; please allow a reasonable window for a fix before
public disclosure.

## Scope notes

- Rewinder is fully local: no accounts, no telemetry, no network access
  except the loopback interface (the timeline server binds 127.0.0.1 only).
- Frames, OCR text, and the search index live wherever the user points
  storage; nothing leaves the machine.
- Release binaries are signed with a Developer ID certificate and notarized
  by Apple. Verify with: `spctl -a -vv /Applications/Rewinder.app`
