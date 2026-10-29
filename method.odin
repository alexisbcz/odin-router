package router

import "base:runtime"
import "core:strings"

/*
Method is an HTTP request method that a route can be registered for.

Methods are case-sensitive tokens (RFC 9110, section 9.1), so method_parse
accepts only the canonical upper-case spelling.
*/
Method :: enum u8 {
	Get,
	Head,
	Post,
	Put,
	Patch,
	Delete,
	Connect,
	Options,
	Trace,
}

// Methods is a set of HTTP methods. The router uses it to build `Allow` headers.
Methods :: bit_set[Method]

// MAX_ALLOW_LEN is the longest string methods_write can produce: every method, comma separated.
MAX_ALLOW_LEN :: 64

// method_string returns the canonical upper-case token for `m`, for example "GET".
method_string :: proc(m: Method) -> string {
	switch m {
	case .Get:
		return "GET"
	case .Head:
		return "HEAD"
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Patch:
		return "PATCH"
	case .Delete:
		return "DELETE"
	case .Connect:
		return "CONNECT"
	case .Options:
		return "OPTIONS"
	case .Trace:
		return "TRACE"
	}
	return ""
}

/*
method_parse converts a request method token such as "GET" into a Method.

Returns:
- m: the parsed method; `.Get` when `ok` is false.
- ok: false when `s` isn't one of the nine standard methods. Matching is
  case-sensitive, so "get" isn't accepted.
*/
method_parse :: proc(s: string) -> (m: Method, ok: bool) {
	for candidate in Method {
		if method_string(candidate) == s {
			return candidate, true
		}
	}
	return .Get, false
}

/*
methods_write formats `methods` as an `Allow` header value, for example
"GET, HEAD, POST", into `buf`. Methods appear in Method declaration order.

Returns:
- s: a string that borrows `buf`.
- ok: false when `buf` is too small; MAX_ALLOW_LEN bytes always suffice.
*/
methods_write :: proc(methods: Methods, buf: []byte) -> (s: string, ok: bool) {
	n := 0
	for m in Method {
		if m not_in methods {
			continue
		}
		name := method_string(m)
		need := len(name)
		if n > 0 {
			need += 2
		}
		if n + need > len(buf) {
			return "", false
		}
		if n > 0 {
			buf[n] = ','
			buf[n + 1] = ' '
			n += 2
		}
		n += copy(buf[n:], name)
	}
	return string(buf[:n]), true
}

/*
methods_format formats `methods` as an `Allow` header value, like methods_write.

Returns:
- s: a new string owned by the caller; free it with `delete(s, allocator)`.
- err: an allocator error.
*/
methods_format :: proc(methods: Methods, allocator := context.allocator) -> (s: string, err: runtime.Allocator_Error) {
	buf: [MAX_ALLOW_LEN]byte
	text, _ := methods_write(methods, buf[:])
	return strings.clone(text, allocator)
}
