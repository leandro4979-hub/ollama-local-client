# Security Policy

Please report vulnerabilities privately through GitHub Security Advisories rather
than opening a public issue.

The enforced boundary is literal `127.0.0.1:11434`, fixed API paths, and the fixed
`gemma3:4b` model. Redirects, aliases such as `localhost`, alternate ports, malformed
streams, oversized responses, and model substitution fail closed.

The package does not claim to sandbox Ollama itself. Operators remain responsible
for running Ollama with cloud features disabled and for securing the host account.
