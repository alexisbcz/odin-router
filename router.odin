/*
Package router is a transport-agnostic HTTP request router built on a radix tree.

Routes are patterns made of static text, `:param` segments that capture one
path segment, and a trailing `*wildcard` that captures the rest of the path.
Static segments win over parameters, and parameters win over wildcards; when
a branch fails deeper down, the router backtracks and tries the next one.

The router detects 404 Not Found and 405 Method Not Allowed, and builds the
`Allow` header for the second. Routes can live in groups that share a path
prefix and a middleware chain.

The router knows nothing about sockets. A server hands serve a Request (method
and path) and a Response_Writer (three procedure pointers), so it works with
any HTTP server, test harness or framework.

Example:
	import "core:fmt"
	import router "shared:odin-router"

	show_user :: proc(ctx: ^router.Context) {
		id, _ := router.param(ctx, "id")
		router.write_string(ctx, id)
	}

	main :: proc() {
		r: router.Router
		router.router_init(&r)
		defer router.router_destroy(&r)

		if err := router.handle(&r, .Get, "/users/:id", show_user); err != nil {
			fmt.eprintln("bad route:", err)
			return
		}
		// For each request your server reads:
		// router.serve(&r, {method = "GET", path = "/users/42"}, writer)
	}

Thread safety: register every route and middleware before serving. After
that, serve and router_lookup only read the router and never allocate, so any
number of threads may call them at once. Registration isn't thread-safe.
*/
package router

import "base:runtime"
import "core:strings"

// MAX_GROUP_DEPTH is how deeply groups may nest, counting the router's own base group.
MAX_GROUP_DEPTH :: 16

// Route_Error lists the ways registering a route, group or middleware can fail.
Route_Error :: enum {
	None,
	// The pattern was the empty string.
	Empty_Pattern,
	// Patterns and group prefixes must start with '/'.
	Missing_Leading_Slash,
	// The pattern holds '?', '#', a space or a control byte.
	Invalid_Character,
	// A `:param` or `*wildcard` name was empty or used a byte outside [A-Za-z0-9_].
	Invalid_Param_Name,
	// The same parameter name appears twice in one pattern.
	Duplicate_Param_Name,
	// A `*wildcard` must be the last segment, and group prefixes can't hold one.
	Wildcard_Not_Last,
	// The pattern declares more than MAX_PARAMS parameters.
	Too_Many_Params,
	// Another route already uses a different name for the parameter or wildcard at this position.
	Param_Name_Conflict,
	// A route with the same method and pattern already exists.
	Duplicate_Route,
	// A handler or middleware was nil.
	Nil_Handler,
	// Creating the group would exceed MAX_GROUP_DEPTH.
	Group_Too_Deep,
	// The target was nil, or its router wasn't initialized with router_init.
	Invalid_Target,
}

/*
Error is the compound error type returned by every registration procedure.
`nil` means success. Compare it against a variant such as
`router.Error(router.Route_Error.Duplicate_Route)`, or use a type switch.
*/
Error :: union #shared_nil {
	Route_Error,
	runtime.Allocator_Error,
}

// Lookup_Error tells why a request didn't reach a route handler.
Lookup_Error :: enum {
	None,
	// No route matches the path for any method.
	Not_Found,
	// Some route matches the path, but not for the request method.
	Method_Not_Allowed,
	// The path was empty or didn't start with '/'.
	Invalid_Path,
}

/*
Handler handles one request, or wraps the rest of the chain as middleware.

A middleware calls next(ctx) to run the rest of the chain, and may do work
before and after that call. A middleware that doesn't call next stops the
chain, for example to reject an unauthorized request.
*/
Handler :: #type proc(ctx: ^Context)

// Param is one captured path parameter. Both strings borrow memory; see Context.params.
Param :: struct {
	name:  string,
	value: string,
}

/*
Route is one registered method and pattern. The router owns every Route and
frees them in router_destroy. Treat the fields as read-only.
*/
Route :: struct {
	method:  Method,
	// The full pattern, including group prefixes, owned by the router.
	pattern: string,
	handler: Handler,
	// The group the route was registered on; its middleware chain wraps the handler.
	group:   ^Group,
}

/*
Group is a set of routes that share a path prefix and a middleware chain.

Create one with group. The router owns every group and frees it in
router_destroy, so don't free a group yourself. Middleware added to a group
applies to every route registered on it or on its subgroups, including routes
registered before the middleware.
*/
Group :: struct {
	router:     ^Router,
	parent:     ^Group,
	// The full prefix, including parent prefixes, owned by the router.
	prefix:     string,
	middleware: [dynamic]Handler,
	// 1 for the router's base group, plus one per level of nesting.
	depth:      int,
}

/*
Router maps request methods and paths to handlers.

Initialize it with router_init and release it with router_destroy. Don't copy
a Router after router_init, because its groups point back at it.

The handler fields are optional hooks. When nil, serve uses a small built-in
handler that writes a plain-text status line.
*/
Router :: struct {
	allocator:          runtime.Allocator,
	root:               ^Node,
	// The base group: the router's own prefix-less group. Middleware added with use(&r, ...) lives here.
	base:               ^Group,
	groups:             [dynamic]^Group,
	// Every route in registration order. Read-only.
	routes:             [dynamic]^Route,
	// Runs when no route matches the path. Default: 404 with a plain-text body.
	not_found:          Handler,
	// Runs when the path matches but the method doesn't. Default: 405 with an Allow header.
	method_not_allowed: Handler,
	// Runs when the request path is empty or doesn't start with '/'. Default: 400.
	bad_request:        Handler,
	// When true (the default), a HEAD request falls back to the GET route of the same path.
	head_uses_get:      bool,
	// When true (the default), an OPTIONS request without an OPTIONS route gets 204 and an Allow header.
	handle_options:     bool,
}

/*
Target is anything routes and middleware can be registered on: a Router (its
base group) or a Group. Pass `&r` or a `^Group`; both convert implicitly.
*/
Target :: union {
	^Router,
	^Group,
}

/*
router_init prepares `r` for use. Every allocation the router makes later,
including copies of patterns and prefixes, uses `allocator`. Call
router_destroy when done.

Returns an allocator error; on error `r` holds nothing that needs freeing.
*/
router_init :: proc(r: ^Router, allocator := context.allocator) -> runtime.Allocator_Error {
	r^ = {}
	r.allocator = allocator
	r.head_uses_get = true
	r.handle_options = true
	r.groups = make([dynamic]^Group, allocator)
	r.routes = make([dynamic]^Route, allocator)

	err: runtime.Allocator_Error
	defer if err != nil {
		router_destroy(r)
	}
	r.root, err = node_new(.Static, allocator)
	if err != nil {
		return err
	}
	r.base, err = group_new(r, nil, "")
	return err
}

// router_destroy frees every node, route, group and copied string. The router is zeroed.
router_destroy :: proc(r: ^Router) {
	node_destroy(r.root, r.allocator)
	for route in r.routes {
		delete(route.pattern, r.allocator)
		free(route, r.allocator)
	}
	delete(r.routes)
	for g in r.groups {
		delete(g.prefix, r.allocator)
		delete(g.middleware)
		free(g, r.allocator)
	}
	delete(r.groups)
	r^ = {}
}

@(private)
target_group :: proc(target: Target) -> ^Group {
	switch t in target {
	case ^Router:
		if t != nil {
			return t.base
		}
	case ^Group:
		return t
	}
	return nil
}

// group_new allocates a group with an owned copy of `prefix` and records it in the router.
@(private)
group_new :: proc(r: ^Router, parent: ^Group, prefix: string) -> (g: ^Group, err: runtime.Allocator_Error) {
	g = new(Group, r.allocator) or_return
	g.router = r
	g.parent = parent
	g.depth = 1 if parent == nil else parent.depth + 1
	g.middleware = make([dynamic]Handler, r.allocator)
	g.prefix, err = strings.clone(prefix, r.allocator)
	if err == nil {
		_, err = append(&r.groups, g)
	}
	if err != nil {
		delete(g.prefix, r.allocator)
		delete(g.middleware)
		free(g, r.allocator)
		return nil, err
	}
	return g, nil
}

/*
group creates a subgroup of `target` whose routes all start with `prefix`.

Inputs:
- target: the router or the parent group.
- prefix: "" or a path starting with '/'. It may hold `:param` segments but no
  wildcard. Trailing slashes are dropped, so "/api/" and "/api" are the same.

Returns:
- g: the new group, owned by the router; router_destroy frees it.
- err: a Route_Error for a bad prefix or a group nested too deeply, or an allocator error.
*/
group :: proc(target: Target, prefix: string) -> (g: ^Group, err: Error) {
	parent := target_group(target)
	if parent == nil {
		return nil, .Invalid_Target
	}
	if parent.depth >= MAX_GROUP_DEPTH {
		return nil, .Group_Too_Deep
	}
	trimmed := strings.trim_right(prefix, "/")
	if trimmed != "" && trimmed[0] != '/' {
		return nil, .Missing_Leading_Slash
	}

	r := parent.router
	full := strings.concatenate({parent.prefix, trimmed}, context.temp_allocator) or_return
	defer delete(full, context.temp_allocator)
	if full != "" {
		p: Pattern
		pattern_parse(full, &p) or_return
		if p.tokens[p.count - 1].kind == .Wildcard {
			return nil, .Wildcard_Not_Last
		}
	}
	return group_new(r, parent, full)
}

/*
use appends middleware to `target`. Middleware runs outermost first: the
router's base group, then each group from the outside in, in the order added.

Returns `.Nil_Handler` if any handler is nil, in which case none are added.
*/
use :: proc(target: Target, handlers: ..Handler) -> Error {
	g := target_group(target)
	if g == nil {
		return .Invalid_Target
	}
	for h in handlers {
		if h == nil {
			return .Nil_Handler
		}
	}
	_, err := append(&g.middleware, ..handlers)
	return err
}

/*
handle registers `handler` for `method` requests whose path matches `pattern`.

Inputs:
- target: the router, or a group whose prefix goes in front of `pattern`.
- method: the request method.
- pattern: a path starting with '/'. A segment that starts with `:` captures
  one non-empty path segment, and a final segment that starts with `*`
  captures the rest of the path, which may be empty. A bare `*` captures under
  the name "*". Elsewhere `:` and `*` are literal.
- handler: the procedure to call; must not be nil.

Returns a Route_Error for a malformed or conflicting pattern, or an allocator
error. On error the router is unchanged.

Example:
	router.handle(&r, .Get, "/users/:id", show_user)
*/
handle :: proc(target: Target, method: Method, pattern: string, handler: Handler) -> Error {
	g := target_group(target)
	if g == nil || g.router == nil || g.router.root == nil {
		return .Invalid_Target
	}
	if handler == nil {
		return .Nil_Handler
	}
	r := g.router

	owned := strings.concatenate({g.prefix, pattern}, r.allocator) or_return
	err := route_insert(r, g, method, owned, handler)
	if err != nil {
		delete(owned, r.allocator)
	}
	return err
}

/*
handle_methods registers `handler` for each method in `methods`, as if by
calling handle once per method. It stops at the first error; routes added
before the error stay registered.
*/
handle_methods :: proc(target: Target, methods: Methods, pattern: string, handler: Handler) -> Error {
	for m in Method {
		if m in methods {
			handle(target, m, pattern, handler) or_return
		}
	}
	return nil
}

// route_insert adds a route for the owned pattern `full`. It takes ownership of `full` only on success.
@(private)
route_insert :: proc(r: ^Router, g: ^Group, method: Method, full: string, handler: Handler) -> Error {
	p: Pattern
	pattern_parse(full, &p) or_return
	route_check_conflicts(r, &p, method) or_return

	route := new(Route, r.allocator) or_return
	route^ = {
		method  = method,
		pattern = full,
		handler = handler,
		group   = g,
	}
	if _, err := append(&r.routes, route); err != nil {
		free(route, r.allocator)
		return err
	}

	n := r.root
	for t in p.tokens[:p.count] {
		err: runtime.Allocator_Error
		switch t.kind {
		case .Static:
			n, err = node_insert_static(n, t.text, r.allocator)
		case .Param:
			if n.param == nil {
				n.param, err = node_new(.Param, r.allocator)
				if err == nil {
					n.param.name = t.text
				}
			}
			n = n.param
		case .Wildcard:
			if n.wildcard == nil {
				n.wildcard, err = node_new(.Wildcard, r.allocator)
				if err == nil {
					n.wildcard.name = t.text
				}
			}
			n = n.wildcard
		}
		if err != nil {
			// Nodes added so far stay in the tree without a route; they match nothing.
			pop(&r.routes)
			free(route, r.allocator)
			return err
		}
	}
	n.routes[method] = route
	n.methods += {method}
	return nil
}

// route_check_conflicts reports name conflicts and duplicates without changing the tree.
@(private)
route_check_conflicts :: proc(r: ^Router, p: ^Pattern, method: Method) -> Route_Error {
	n := r.root
	for t in p.tokens[:p.count] {
		switch t.kind {
		case .Static:
			n = node_walk_static(n, t.text)
		case .Param:
			if n.param != nil && n.param.name != t.text {
				return .Param_Name_Conflict
			}
			n = n.param
		case .Wildcard:
			if n.wildcard != nil && n.wildcard.name != t.text {
				return .Param_Name_Conflict
			}
			n = n.wildcard
		}
		if n == nil {
			// The pattern leaves the existing tree here, so nothing further can clash.
			return .None
		}
	}
	if method in n.methods {
		return .Duplicate_Route
	}
	return .None
}

/*
Match is the result of router_lookup.

`route` is set when the lookup succeeds. `allowed` is set for
`.Method_Not_Allowed` and lists every method that would succeed, including
HEAD and OPTIONS when the router answers those for you.
*/
Match :: struct {
	route:       ^Route,
	allowed:     Methods,
	params:      [MAX_PARAMS]Param,
	param_count: int,
}

/*
match_params returns the captured parameters of `m` in pattern order.
The slice points into `m`, so it's valid only while `m` is.
*/
match_params :: proc(m: ^Match) -> []Param {
	return m.params[:m.param_count]
}

/*
router_lookup finds the route for `method` and `path` without running it.

Inputs:
- method: the request method.
- path: the request path. Everything from the first '?' or '#' is ignored.
  Matching is byte-for-byte: the router doesn't decode percent escapes or
  clean up "//" and "..".

Returns:
- m: the route and parameters. Parameter values borrow `path`, and names
  borrow the router.
- err: `.Not_Found`, `.Method_Not_Allowed` (with `m.allowed` set) or `.Invalid_Path`.
*/
router_lookup :: proc(r: ^Router, method: Method, path: string) -> (m: Match, err: Lookup_Error) {
	err = lookup(r, {method}, path, &m)
	return
}

// lookup implements router_lookup. An empty `want` set skips straight to computing `allowed`.
@(private)
lookup :: proc(r: ^Router, want: Methods, path: string, m: ^Match) -> Lookup_Error {
	path := path
	if i := strings.index_any(path, "?#"); i >= 0 {
		path = path[:i]
	}
	if len(path) == 0 || path[0] != '/' || r.root == nil {
		return .Invalid_Path
	}

	s: Search
	s.want = want
	if .Head in want && r.head_uses_get {
		s.want += {.Get}
	}
	if s.want != {} {
		if n := node_find(r.root, path, &s); n != nil {
			method := Method.Get
			for candidate in want {
				method = candidate
				break
			}
			m.route = n.routes[method]
			if m.route == nil {
				m.route = n.routes[.Get]
			}
			m.params = s.params
			m.param_count = s.count
			return .None
		}
	}

	s = {collect = true}
	node_find(r.root, path, &s)
	if s.allowed == {} {
		return .Not_Found
	}
	m.allowed = s.allowed
	if .Get in m.allowed && r.head_uses_get {
		m.allowed += {.Head}
	}
	if r.handle_options {
		m.allowed += {.Options}
	}
	return .Method_Not_Allowed
}
