# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

### Added

- Radix-tree router with static, `:param` and trailing `*wildcard` segments. Static segments win over parameters, which win over wildcards, and the router backtracks when a branch fails.
- Registration through `handle` and `handle_methods` on a router or a group, returning `Route_Error` values for malformed, conflicting or duplicate patterns.
- Route groups with shared prefixes, and middleware chains resolved per request through `use` and `next`.
- `serve`, an allocation-free dispatcher that works with any server through `Request` and `Response_Writer`.
- 404, 405 and 400 detection with an `Allow` header built from every matching route, plus optional HEAD-to-GET fallback and automatic OPTIONS answers.
- `router_lookup`, `match_params`, `param` and `params_get` for reading routes and path parameters.
- `method_parse`, `method_string`, `methods_write` and `methods_format` helpers.
- Examples: `basic` routes fake requests in memory, and `server` runs a small HTTP/1.1 server on `core:net`.

[Unreleased]: https://github.com/alexisbcz/odin-router/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexisbcz/odin-router/releases/tag/v0.1.0
