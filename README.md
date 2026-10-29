# router

[![CI](https://github.com/alexisbcz/odin-router/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-router/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

A transport-agnostic HTTP request router for Odin: radix-tree matching with `:param` and `*wildcard` segments, 404 and 405 detection with an `Allow` header, route groups and middleware, and an allocation-free dispatch path that plugs into any HTTP server.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-router libs/router
```

```odin
import "libs/router"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-router ~/odin-shared/odin-router
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import router "shared:odin-router"
```

## Quick start

```odin
package main

import "core:fmt"
import router "shared:odin-router"

show_user :: proc(ctx: ^router.Context) {
	id, _ := router.param(ctx, "id")
	router.write_status(ctx, 200)
	router.write_string(ctx, id)
}

print_status :: proc(data: rawptr, status: int) {
	fmt.println("status:", status)
}

print_body :: proc(data: rawptr, body: []byte) {
	fmt.println("body:", string(body))
}

main :: proc() {
	r: router.Router
	if err := router.router_init(&r); err != nil {
		fmt.eprintln("router_init failed:", err)
		return
	}
	defer router.router_destroy(&r)

	if err := router.handle(&r, .Get, "/users/:id", show_user); err != nil {
		fmt.eprintln("bad route:", err)
		return
	}

	// A real server fills these from the socket; see examples/server.
	writer := router.Response_Writer {
		write_status = print_status,
		write        = print_body,
	}
	router.serve(&r, {method = "GET", path = "/users/42"}, writer)
}
```

## Patterns

| Segment | Matches | Example pattern | Example path | Captures |
| --- | --- | --- | --- | --- |
| Static | The exact bytes | `/about` | `/about` | Nothing |
| `:name` | One non-empty segment | `/users/:id` | `/users/42` | `id` = `42` |
| `*name` | The rest of the path, possibly empty; last segment only | `/static/*path` | `/static/css/a.css` | `path` = `css/a.css` |
| `*` | Like `*name`, captured under the name `*` | `/*` | `/any/thing` | `*` = `any/thing` |

- `:` and `*` are special only at the start of a segment, so `/v1/files:batch` is a static route.
- When several routes match, a static segment wins over a parameter, and a parameter wins over a wildcard. If the preferred branch fails further down, the router backtracks and tries the next one.
- Matching is byte-for-byte. The router ignores the query string and fragment, keeps percent escapes in parameter values as they are, and treats `/a` and `/a/` as different paths.
- A pattern may hold at most `MAX_PARAMS` (16) parameters. Two routes can't give different names to the parameter at the same position.

## Groups and middleware

A group shares a path prefix and a middleware chain. A middleware is an ordinary `Handler` that calls `router.next` to run the rest of the chain:

```odin
log_requests :: proc(ctx: ^router.Context) {
	router.next(ctx)
	fmt.println(ctx.request.method, ctx.request.path)
}

require_token :: proc(ctx: ^router.Context) {
	if ctx.user == nil {
		router.write_status(ctx, 401)
		return // Not calling next stops the chain.
	}
	router.next(ctx)
}

setup :: proc(r: ^router.Router) -> router.Error {
	router.use(r, log_requests) or_return

	admin := router.group(r, "/admin") or_return
	router.use(admin, require_token) or_return
	router.handle(admin, .Get, "/users/:id", show_user) or_return
	return nil
}
```

Middleware runs from the outside in: the router's own middleware first, then each enclosing group in order. The router resolves the chain when a request arrives, so middleware that you add after a route still wraps it. The router's own middleware also wraps the 404, 405 and 400 handlers.

## Not found, method not allowed and OPTIONS

`serve` returns a `Lookup_Error` that tells you which handler ran.

- `.Not_Found`: no route matches the path. The `not_found` hook runs, or a built-in 404.
- `.Method_Not_Allowed`: the path matches, but not for this method. `ctx.allowed` and `ctx.allow` hold the methods that would work, and the built-in handler sends them in an `Allow` header with a 405.
- `.Invalid_Path`: the path is empty or doesn't start with `/`. The `bad_request` hook runs, or a built-in 400.

A HEAD request uses the GET route when no HEAD route exists, and an OPTIONS request without an OPTIONS route gets a 204 with an `Allow` header. Set `r.head_uses_get` or `r.handle_options` to `false` to turn either off.

## Connecting a server

The router never touches a socket. Your server builds a `Request` with the method and path, and a `Response_Writer` with three procedure pointers. Both carry a `data` pointer for your server's native request and response:

```odin
Request :: struct {
	method: string,
	path:   string,
	data:   rawptr,
}

Response_Writer :: struct {
	data:         rawptr,
	set_header:   proc(data: rawptr, name, value: string),
	write_status: proc(data: rawptr, status: int),
	write:        proc(data: rawptr, body: []byte),
}
```

`examples/server` connects the router to a small HTTP/1.1 server on `core:net`.

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `router_init(r, allocator)` | Prepare a `Router` | Yes | `router_destroy` |
| `router_destroy(r)` | Free every route, group and node | No | Not needed |
| `handle(target, method, pattern, handler)` | Register a route on a router or group | Yes | `router_destroy` |
| `handle_methods(target, methods, pattern, handler)` | Register one handler for several methods | Yes | `router_destroy` |
| `group(target, prefix)` | Create a subgroup with a shared prefix | Yes | `router_destroy` |
| `use(target, ..handlers)` | Append middleware to a router or group | Yes | `router_destroy` |
| `serve(r, request, writer, user)` | Route one request and run its chain | No | Not needed |
| `router_lookup(r, method, path)` | Find a route without running it | No | Not needed |
| `next(ctx)` | Run the rest of the middleware chain | No | Not needed |
| `param(ctx, name)`, `params_get(params, name)` | Read a captured parameter | No | Not needed |
| `set_header`, `write_status`, `write`, `write_string` | Write through the `Response_Writer` | No | Not needed |
| `method_parse(s)`, `method_string(m)` | Convert between `Method` and its token | No | Not needed |
| `methods_write(methods, buf)` | Format an `Allow` value into a buffer | No | Not needed |
| `methods_format(methods, allocator)` | Format an `Allow` value as a new string | Yes | `delete` |
| `Error` | Union of `Route_Error` and `runtime.Allocator_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic    # routes fake requests and prints the responses
odin run examples/server   # serves http://127.0.0.1:8080
```

## Design notes

- Registration copies every pattern and prefix into the router's allocator. Parameter values borrow the request path, so copy them if a handler needs them after it returns.
- `serve` and `router_lookup` never allocate and only read the router. Register every route first, and then any number of threads may serve at once.
- Registration returns `Error` values and leaves the router unchanged on failure. The library never panics on bad input.
- There's no global state; every setting lives on the `Router`.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
