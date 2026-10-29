package router

/*
Request is the part of an HTTP request the router reads.

Fill it from whatever server you use. `data` is yours: point it at the
server's native request so handlers can read headers and the body.
*/
Request :: struct {
	// The method token, for example "GET". Unknown methods get 404 or 405.
	method: string,
	// The request target path. A query string or fragment is ignored for matching.
	path:   string,
	data:   rawptr,
}

/*
Response_Writer is the small interface the router and handlers write through.

Each procedure receives `data` as its first argument. Point `data` at the
server's native response. Any procedure may be nil, in which case calls to it
do nothing.
*/
Response_Writer :: struct {
	data:         rawptr,
	// Sets a response header. Called before write_status.
	set_header:   proc(data: rawptr, name, value: string),
	// Sends the status line. Called at most once per request by the built-in handlers.
	write_status: proc(data: rawptr, status: int),
	// Appends bytes to the response body.
	write:        proc(data: rawptr, body: []byte),
}

/*
Context is the per-request state that serve passes to every handler and middleware.

serve keeps the Context on its own stack, so a handler must not keep a pointer
to it, or to anything it borrows, after the handler returns. Don't copy a
Context either: `params` points into it. Fields after `user` are internal.
*/
Context :: struct {
	request:       Request,
	response:      Response_Writer,
	router:        ^Router,
	// The matched route, or nil when a not-found, method-not-allowed, bad-request or automatic OPTIONS handler runs.
	route:         ^Route,
	// Captured path parameters in pattern order. Values borrow `request.path`.
	params:        []Param,
	// For 405 and automatic OPTIONS responses: the methods the path supports.
	allowed:       Methods,
	// The `Allow` header value for `allowed`. Borrows the Context.
	allow:         string,
	// Free for middleware to pass per-request state to later handlers. serve sets it from its `user` argument.
	user:          rawptr,
	chain_groups:  [MAX_GROUP_DEPTH]^Group,
	chain_depth:   int,
	chain_group:   int,
	chain_index:   int,
	chain_handler: Handler,
	chain_done:    bool,
	param_storage: [MAX_PARAMS]Param,
	allow_storage: [MAX_ALLOW_LEN]byte,
}

/*
serve routes one request and runs the matching handler inside its middleware chain.

Inputs:
- r: an initialized router.
- req: the request method and path.
- res: the response interface handlers write through.
- user: copied into `Context.user` before the first middleware runs.

Returns `.None` when a route handler or the automatic OPTIONS answer ran, or
the Lookup_Error whose handler ran instead. In every case the router's base
middleware wraps the handler, so logging middleware sees 404s too. serve
doesn't allocate.
*/
serve :: proc(r: ^Router, req: Request, res: Response_Writer, user: rawptr = nil) -> Lookup_Error {
	ctx: Context
	ctx.request = req
	ctx.response = res
	ctx.router = r
	ctx.user = user

	want: Methods
	method, known := method_parse(req.method)
	if known {
		want = {method}
	}
	m: Match
	err := lookup(r, want, req.path, &m)

	g := r.base
	switch err {
	case .None:
		ctx.route = m.route
		ctx.chain_handler = m.route.handler
		g = m.route.group
	case .Method_Not_Allowed:
		ctx.allowed = m.allowed
		ctx.allow, _ = methods_write(m.allowed, ctx.allow_storage[:])
		if known && method == .Options && r.handle_options {
			ctx.chain_handler = default_options
			err = .None
		} else {
			ctx.chain_handler = r.method_not_allowed if r.method_not_allowed != nil else default_method_not_allowed
		}
	case .Not_Found:
		ctx.chain_handler = r.not_found if r.not_found != nil else default_not_found
	case .Invalid_Path:
		ctx.chain_handler = r.bad_request if r.bad_request != nil else default_bad_request
	}

	ctx.param_storage = m.params
	ctx.params = ctx.param_storage[:m.param_count]

	if g != nil {
		ctx.chain_depth = g.depth
		for it := g; it != nil; it = it.parent {
			ctx.chain_groups[it.depth - 1] = it
		}
	}
	next(&ctx)
	return err
}

/*
next runs the rest of the chain: the next middleware, or the handler once
every middleware has run. Calling it after the handler has run does nothing.
*/
next :: proc(ctx: ^Context) {
	for ctx.chain_group < ctx.chain_depth {
		g := ctx.chain_groups[ctx.chain_group]
		if ctx.chain_index < len(g.middleware) {
			h := g.middleware[ctx.chain_index]
			ctx.chain_index += 1
			h(ctx)
			return
		}
		ctx.chain_group += 1
		ctx.chain_index = 0
	}
	if !ctx.chain_done && ctx.chain_handler != nil {
		ctx.chain_done = true
		ctx.chain_handler(ctx)
	}
}

/*
param returns the value captured for `name`.

Returns:
- value: the raw, still percent-encoded value, borrowing the request path.
- ok: false when the route has no parameter called `name`.
*/
param :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	return params_get(ctx.params, name)
}

// params_get finds `name` in `params`, as returned by match_params or held in Context.params.
params_get :: proc(params: []Param, name: string) -> (value: string, ok: bool) {
	for p in params {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

// set_header sets a response header through the Response_Writer.
set_header :: proc(ctx: ^Context, name, value: string) {
	if ctx.response.set_header != nil {
		ctx.response.set_header(ctx.response.data, name, value)
	}
}

// write_status sends the response status through the Response_Writer.
write_status :: proc(ctx: ^Context, status: int) {
	if ctx.response.write_status != nil {
		ctx.response.write_status(ctx.response.data, status)
	}
}

// write appends `body` to the response through the Response_Writer.
write :: proc(ctx: ^Context, body: []byte) {
	if ctx.response.write != nil && len(body) > 0 {
		ctx.response.write(ctx.response.data, body)
	}
}

// write_string appends `s` to the response through the Response_Writer.
write_string :: proc(ctx: ^Context, s: string) {
	write(ctx, transmute([]byte)s)
}

@(private)
write_plain :: proc(ctx: ^Context, status: int, body: string) {
	set_header(ctx, "Content-Type", "text/plain; charset=utf-8")
	write_status(ctx, status)
	write_string(ctx, body)
}

// default_not_found answers 404 with a plain-text body.
default_not_found :: proc(ctx: ^Context) {
	write_plain(ctx, 404, "404 Not Found\n")
}

// default_method_not_allowed answers 405 with an Allow header listing Context.allowed.
default_method_not_allowed :: proc(ctx: ^Context) {
	set_header(ctx, "Allow", ctx.allow)
	write_plain(ctx, 405, "405 Method Not Allowed\n")
}

// default_bad_request answers 400 with a plain-text body.
default_bad_request :: proc(ctx: ^Context) {
	write_plain(ctx, 400, "400 Bad Request\n")
}

// default_options answers an OPTIONS request with 204 and an Allow header listing Context.allowed.
default_options :: proc(ctx: ^Context) {
	set_header(ctx, "Allow", ctx.allow)
	write_status(ctx, 204)
}
