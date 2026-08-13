# Contributing

Thank you for helping improve Ollama Local Client.

## Before you start

- Search existing issues and pull requests.
- Keep each change focused and preserve the literal `127.0.0.1:11434` boundary.
- Do not include credentials, prompts, local model data, generated build products,
  or unrelated formatting changes.
- Discuss proposals that add endpoints, models, cloud access, filesystem authority,
  or command execution before implementing them.

## Validation

Use Swift 6 on macOS 14 or later and run:

```bash
swift test
```

Security-sensitive changes require focused tests proving deterministic, fail-closed
behavior for endpoint validation, redirects, cancellation, malformed streams, and
request or response bounds as applicable.

## Pull requests

Include a concise summary and rationale, tests added or updated, exact validation
commands and results, and any compatibility or security implications.

Concise conventional commit prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and
`chore:` are encouraged.

Do not report vulnerabilities publicly. Follow [SECURITY.md](SECURITY.md).
