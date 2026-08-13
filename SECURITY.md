# Security Policy

## Supported versions

Security fixes are provided for the latest version on the `main` branch.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories rather
than opening a public issue. Include the affected version or commit, minimal
reproduction steps, impact, and a suggested mitigation when available. Never include
real credentials, private prompts, personal data, or local model data. Allow
reasonable time for investigation before disclosure.

## Project boundary

The enforced boundary is literal `127.0.0.1:11434`, fixed API paths, and the fixed
`gemma3:4b` model. Redirects, aliases such as `localhost`, alternate ports, malformed
streams, oversized responses, and model substitution fail closed.

The package does not claim to sandbox Ollama itself. Operators remain responsible
for running Ollama with cloud features disabled and for securing the host account.

## Contributor expectations

- Never commit credentials, tokens, private keys, prompts, personal data, or `.env` files.
- Do not add arbitrary endpoints, hostname aliases, redirects, proxies, or cloud fallback.
- Preserve bounded request and streamed-response processing.
- Review dependency and CI action updates before merging them.
