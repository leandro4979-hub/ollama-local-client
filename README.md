# Ollama Local Client

A narrow Swift 6 client for one local Ollama boundary:

- endpoint: `http://127.0.0.1:11434`
- model: `gemma3:4b`
- operations: `status`, `verify`, and stdin-only `ask`
- no redirects, proxies, cookies, cache, cloud fallback, arbitrary URLs, shell execution, or filesystem authority

The client validates bounded NDJSON streams, enforces request and response limits,
and keeps cancellation scoped to the originating request.

## Requirements

- macOS 14 or later
- Swift 6
- Ollama listening on literal `127.0.0.1:11434`
- `gemma3:4b` installed locally

## Build and test

```bash
swift test
swift test --sanitize=thread
swift build -c release --product ollama-local
```

## Usage

```bash
swift run ollama-local status
swift run ollama-local verify
printf '%s\n' 'Explain Swift actors.' | swift run ollama-local ask
```

## Security model

Model output is untrusted text. This package has no action executor. See
[SECURITY.md](SECURITY.md) for reporting and supported security boundaries.

## License

MIT
