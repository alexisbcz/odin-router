// Package router_tests holds the unit tests for router. Run them with `odin test tests`.
package router_tests

import router ".."
import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"

// ---- Fixtures ----

// Fixture owns a router whose every allocation goes through a tracking allocator.
Fixture :: struct {
	t:     ^testing.T,
	track: mem.Tracking_Allocator,
	alloc: runtime.Allocator,
	r:     router.Router,
}

fixture_init :: proc(f: ^Fixture, t: ^testing.T) {
	f.t = t
	mem.tracking_allocator_init(&f.track, context.allocator)
	f.alloc = mem.tracking_allocator(&f.track)
	testing.expect_value(t, router.router_init(&f.r, f.alloc), nil)
}

// fixture_destroy frees the router and fails the test on any leak or bad free.
fixture_destroy :: proc(f: ^Fixture) {
	router.router_destroy(&f.r)
	testing.expectf(f.t, len(f.track.allocation_map) == 0, "leaked %d allocations", len(f.track.allocation_map))
	testing.expectf(f.t, len(f.track.bad_free_array) == 0, "%d bad frees", len(f.track.bad_free_array))
	mem.tracking_allocator_destroy(&f.track)
}

// Recorder is a fixed-size fake response: it never allocates.
Recorder :: struct {
	status:       int,
	status_calls: int,
	allow:        [router.MAX_ALLOW_LEN]byte,
	allow_len:    int,
	has_allow:    bool,
	body:         [256]byte,
	body_len:     int,
	steps:        [32]string,
	step_count:   int,
}

rec_set_header :: proc(data: rawptr, name, value: string) {
	rec := (^Recorder)(data)
	if name == "Allow" {
		rec.has_allow = true
		rec.allow_len = copy(rec.allow[:], value)
	}
}

rec_write_status :: proc(data: rawptr, status: int) {
	rec := (^Recorder)(data)
	rec.status = status
	rec.status_calls += 1
}

rec_write :: proc(data: rawptr, body: []byte) {
	rec := (^Recorder)(data)
	rec.body_len += copy(rec.body[rec.body_len:], body)
}

writer :: proc(rec: ^Recorder) -> router.Response_Writer {
	return {data = rec, set_header = rec_set_header, write_status = rec_write_status, write = rec_write}
}

body :: proc(rec: ^Recorder) -> string {
	return string(rec.body[:rec.body_len])
}

allow :: proc(rec: ^Recorder) -> string {
	return string(rec.allow[:rec.allow_len])
}

// trace joins the recorded steps with spaces into `buf`.
trace :: proc(rec: ^Recorder, buf: []byte) -> string {
	b := strings.builder_from_bytes(buf)
	for s, i in rec.steps[:rec.step_count] {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, s)
	}
	return strings.to_string(b)
}

// mark records a step in the Recorder that serve received as `user`.
mark :: proc(ctx: ^router.Context, step: string) {
	rec := (^Recorder)(ctx.user)
	rec.steps[rec.step_count] = step
	rec.step_count += 1
}

// run serves one request; the Recorder doubles as response and trace.
run :: proc(f: ^Fixture, method, path: string, rec: ^Recorder) -> router.Lookup_Error {
	return router.serve(&f.r, {method = method, path = path}, writer(rec), rec)
}

// add registers a route and fails the test on error.
add :: proc(f: ^Fixture, method: router.Method, pattern: string, h: router.Handler, loc := #caller_location) {
	testing.expect_value(f.t, router.handle(&f.r, method, pattern, h), nil, loc)
}

// expect_route checks that `method path` reaches the route registered as `pattern`.
expect_route :: proc(f: ^Fixture, method: router.Method, path, pattern: string, loc := #caller_location) -> router.Match {
	m, err := router.router_lookup(&f.r, method, path)
	testing.expect_value(f.t, err, router.Lookup_Error.None, loc)
	if m.route != nil {
		testing.expect_value(f.t, m.route.pattern, pattern, loc)
	} else {
		testing.expectf(f.t, false, "no route for %s", path, loc = loc)
	}
	return m
}

expect_lookup_error :: proc(f: ^Fixture, method: router.Method, path: string, want: router.Lookup_Error, loc := #caller_location) {
	_, err := router.router_lookup(&f.r, method, path)
	testing.expect_value(f.t, err, want, loc)
}

route_err :: proc(e: router.Route_Error) -> router.Error {
	return router.Error(e)
}

// ---- Handlers ----

h_a :: proc(ctx: ^router.Context) {mark(ctx, "a")}
h_b :: proc(ctx: ^router.Context) {mark(ctx, "b")}
h_c :: proc(ctx: ^router.Context) {mark(ctx, "c")}

h_ok :: proc(ctx: ^router.Context) {
	mark(ctx, "ok")
	router.write_status(ctx, 200)
	router.write_string(ctx, ctx.route.pattern)
}

h_echo_id :: proc(ctx: ^router.Context) {
	id, ok := router.param(ctx, "id")
	if ok {
		router.write_string(ctx, id)
	}
}

mw_outer :: proc(ctx: ^router.Context) {
	mark(ctx, "outer>")
	router.next(ctx)
	mark(ctx, "<outer")
}

mw_inner :: proc(ctx: ^router.Context) {
	mark(ctx, "inner>")
	router.next(ctx)
	mark(ctx, "<inner")
}

mw_block :: proc(ctx: ^router.Context) {
	mark(ctx, "block")
	router.write_status(ctx, 401)
}

mw_twice :: proc(ctx: ^router.Context) {
	router.next(ctx)
	router.next(ctx)
}

// ---- Methods ----

@(test)
test_method_parse_accepts_standard_tokens :: proc(t: ^testing.T) {
	for m in router.Method {
		got, ok := router.method_parse(router.method_string(m))
		testing.expect(t, ok)
		testing.expect_value(t, got, m)
	}
}

@(test)
test_method_parse_rejects_lowercase_and_unknown :: proc(t: ^testing.T) {
	for s in ([]string{"get", "Get", "", "PURGE", "GET ", "GETS"}) {
		_, ok := router.method_parse(s)
		testing.expectf(t, !ok, "%q parsed", s)
	}
}

@(test)
test_methods_write_formats_in_declaration_order :: proc(t: ^testing.T) {
	buf: [router.MAX_ALLOW_LEN]byte
	s, ok := router.methods_write({.Post, .Get, .Delete}, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "GET, POST, DELETE")
}

@(test)
test_methods_write_fits_every_method_in_max_len :: proc(t: ^testing.T) {
	buf: [router.MAX_ALLOW_LEN]byte
	s, ok := router.methods_write(~router.Methods{}, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "GET, HEAD, POST, PUT, PATCH, DELETE, CONNECT, OPTIONS, TRACE")
}

@(test)
test_methods_write_empty_set_is_empty :: proc(t: ^testing.T) {
	buf: [8]byte
	s, ok := router.methods_write({}, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "")
}

@(test)
test_methods_write_reports_small_buffer :: proc(t: ^testing.T) {
	buf: [8]byte
	_, ok := router.methods_write({.Get, .Post}, buf[:])
	testing.expect(t, !ok)
}

@(test)
test_methods_format_returns_owned_string :: proc(t: ^testing.T) {
	s, err := router.methods_format({.Get, .Head})
	defer delete(s)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, s, "GET, HEAD")
}

// ---- Registration errors ----

@(test)
test_handle_rejects_empty_pattern :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle(&f.r, .Get, "", h_a), route_err(.Empty_Pattern))
}

@(test)
test_handle_rejects_missing_leading_slash :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle(&f.r, .Get, "users", h_a), route_err(.Missing_Leading_Slash))
	testing.expect_value(t, router.handle(&f.r, .Get, ":id", h_a), route_err(.Missing_Leading_Slash))
}

@(test)
test_handle_rejects_invalid_characters :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	for p in ([]string{"/a?b", "/a#b", "/a b", "/a\tb", "/a\x00", "/a\x7f"}) {
		testing.expectf(t, router.handle(&f.r, .Get, p, h_a) == route_err(.Invalid_Character), "%q accepted", p)
	}
}

@(test)
test_handle_rejects_bad_param_names :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	for p in ([]string{"/users/:", "/users/:/x", "/users/:id-x", "/users/:id.json", "/f/*a.b", "/x/:é"}) {
		testing.expectf(t, router.handle(&f.r, .Get, p, h_a) == route_err(.Invalid_Param_Name), "%q accepted", p)
	}
}

@(test)
test_handle_rejects_duplicate_param_name :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle(&f.r, .Get, "/a/:id/b/:id", h_a), route_err(.Duplicate_Param_Name))
	testing.expect_value(t, router.handle(&f.r, .Get, "/a/:id/*id", h_a), route_err(.Duplicate_Param_Name))
}

@(test)
test_handle_rejects_wildcard_not_last :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle(&f.r, .Get, "/files/*path/edit", h_a), route_err(.Wildcard_Not_Last))
	testing.expect_value(t, router.handle(&f.r, .Get, "/files/*/", h_a), route_err(.Wildcard_Not_Last))
}

@(test)
test_handle_rejects_too_many_params :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< router.MAX_PARAMS {
		strings.write_string(&b, "/:p")
		strings.write_int(&b, i)
	}
	testing.expect_value(t, router.handle(&f.r, .Get, strings.to_string(b), h_a), nil)
	strings.write_string(&b, "/:extra")
	testing.expect_value(t, router.handle(&f.r, .Get, strings.to_string(b), h_a), route_err(.Too_Many_Params))
}

@(test)
test_handle_rejects_param_name_conflict :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	testing.expect_value(t, router.handle(&f.r, .Get, "/users/:name/posts", h_a), route_err(.Param_Name_Conflict))
	// The same name at the same position is fine.
	testing.expect_value(t, router.handle(&f.r, .Get, "/users/:id/posts", h_a), nil)
}

@(test)
test_handle_rejects_wildcard_name_conflict :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/static/*path", h_a)
	testing.expect_value(t, router.handle(&f.r, .Post, "/static/*file", h_a), route_err(.Param_Name_Conflict))
	testing.expect_value(t, router.handle(&f.r, .Post, "/static/*path", h_a), nil)
}

@(test)
test_handle_rejects_duplicate_route :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	testing.expect_value(t, router.handle(&f.r, .Get, "/users/:id", h_b), route_err(.Duplicate_Route))
	add(&f, .Put, "/users/:id", h_b)
	testing.expect_value(t, len(f.r.routes), 2)
}

@(test)
test_handle_rejects_nil_handler :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle(&f.r, .Get, "/", nil), route_err(.Nil_Handler))
}

@(test)
test_handle_rejects_invalid_target :: proc(t: ^testing.T) {
	uninit: router.Router
	testing.expect_value(t, router.handle(&uninit, .Get, "/", h_a), route_err(.Invalid_Target))
	nil_router: ^router.Router
	testing.expect_value(t, router.handle(nil_router, .Get, "/", h_a), route_err(.Invalid_Target))
	_, gerr := router.group(nil_router, "/x")
	testing.expect_value(t, gerr, route_err(.Invalid_Target))
}

@(test)
test_failed_registration_leaves_router_unchanged :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	before := len(f.track.allocation_map)
	testing.expect(t, router.handle(&f.r, .Get, "/users/:name/x", h_a) != nil)
	testing.expect(t, router.handle(&f.r, .Get, "/users/:id", h_a) != nil)
	testing.expect_value(t, len(f.track.allocation_map), before)
	testing.expect_value(t, len(f.r.routes), 1)
	expect_lookup_error(&f, .Get, "/users/7/x", .Not_Found)
}

@(test)
test_handle_methods_registers_each_method :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.handle_methods(&f.r, {.Get, .Post, .Delete}, "/items", h_a), nil)
	testing.expect_value(t, len(f.r.routes), 3)
	m, err := router.router_lookup(&f.r, .Delete, "/items")
	testing.expect_value(t, err, router.Lookup_Error.None)
	testing.expect_value(t, m.route.method, router.Method.Delete)
	expect_lookup_error(&f, .Put, "/items", .Method_Not_Allowed)
}

// ---- Matching ----

@(test)
test_match_root :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/", h_a)
	expect_route(&f, .Get, "/", "/")
	expect_lookup_error(&f, .Get, "/x", .Not_Found)
}

@(test)
test_match_static_is_exact :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users", h_a)
	expect_route(&f, .Get, "/users", "/users")
	expect_lookup_error(&f, .Get, "/use", .Not_Found)
	expect_lookup_error(&f, .Get, "/usersx", .Not_Found)
	expect_lookup_error(&f, .Get, "/users/1", .Not_Found)
	expect_lookup_error(&f, .Get, "/Users", .Not_Found)
}

@(test)
test_match_trailing_slash_is_distinct :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_a)
	add(&f, .Get, "/b/", h_b)
	expect_route(&f, .Get, "/a", "/a")
	expect_lookup_error(&f, .Get, "/a/", .Not_Found)
	expect_route(&f, .Get, "/b/", "/b/")
	expect_lookup_error(&f, .Get, "/b", .Not_Found)
}

@(test)
test_match_radix_split_keeps_every_route :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	patterns := []string{"/teams", "/team", "/te", "/contact", "/co", "/c", "/cmd/:tool/", "/cmd/:tool/:sub", "/src/*filepath", "/search/", "/search/:query"}
	for p in patterns {
		add(&f, .Get, p, h_a)
	}
	expect_route(&f, .Get, "/teams", "/teams")
	expect_route(&f, .Get, "/team", "/team")
	expect_route(&f, .Get, "/te", "/te")
	expect_route(&f, .Get, "/contact", "/contact")
	expect_route(&f, .Get, "/co", "/co")
	expect_route(&f, .Get, "/c", "/c")
	expect_route(&f, .Get, "/cmd/vet/", "/cmd/:tool/")
	expect_route(&f, .Get, "/cmd/vet/fix", "/cmd/:tool/:sub")
	expect_route(&f, .Get, "/src/a/b.odin", "/src/*filepath")
	expect_route(&f, .Get, "/search/", "/search/")
	expect_route(&f, .Get, "/search/odin", "/search/:query")
	expect_lookup_error(&f, .Get, "/t", .Not_Found)
	expect_lookup_error(&f, .Get, "/cmd/vet", .Not_Found)
	expect_lookup_error(&f, .Get, "/con", .Not_Found)
}

@(test)
test_match_param_captures_one_segment :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	m := expect_route(&f, .Get, "/users/42", "/users/:id")
	ps := router.match_params(&m)
	testing.expect_value(t, len(ps), 1)
	testing.expect_value(t, ps[0].name, "id")
	testing.expect_value(t, ps[0].value, "42")
	expect_lookup_error(&f, .Get, "/users/42/x", .Not_Found)
}

@(test)
test_match_param_rejects_empty_segment :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	add(&f, .Get, "/a/:x/b", h_a)
	expect_lookup_error(&f, .Get, "/users/", .Not_Found)
	expect_lookup_error(&f, .Get, "/a//b", .Not_Found)
}

@(test)
test_match_multiple_params_in_order :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/orgs/:org/repos/:repo/issues/:number", h_a)
	m := expect_route(&f, .Get, "/orgs/odin-lang/repos/Odin/issues/123", "/orgs/:org/repos/:repo/issues/:number")
	ps := router.match_params(&m)
	testing.expect_value(t, len(ps), 3)
	org, _ := router.params_get(ps, "org")
	repo, _ := router.params_get(ps, "repo")
	num, _ := router.params_get(ps, "number")
	testing.expect_value(t, org, "odin-lang")
	testing.expect_value(t, repo, "Odin")
	testing.expect_value(t, num, "123")
	_, ok := router.params_get(ps, "missing")
	testing.expect(t, !ok)
}

@(test)
test_match_static_beats_param :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_a)
	add(&f, .Get, "/users/new", h_b)
	expect_route(&f, .Get, "/users/new", "/users/new")
	expect_route(&f, .Get, "/users/news", "/users/:id")
	expect_route(&f, .Get, "/users/ne", "/users/:id")
}

@(test)
test_match_param_beats_wildcard :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/files/*path", h_a)
	add(&f, .Get, "/files/:name", h_b)
	expect_route(&f, .Get, "/files/a.txt", "/files/:name")
	expect_route(&f, .Get, "/files/dir/a.txt", "/files/*path")
	expect_route(&f, .Get, "/files/", "/files/*path")
}

@(test)
test_match_backtracks_from_static_to_param :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/new", h_a)
	add(&f, .Get, "/users/:id/edit", h_b)
	m := expect_route(&f, .Get, "/users/new/edit", "/users/:id/edit")
	id, _ := router.params_get(router.match_params(&m), "id")
	testing.expect_value(t, id, "new")
}

@(test)
test_match_backtracks_to_wildcard_and_drops_params :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a/:x/c", h_a)
	add(&f, .Get, "/a/*rest", h_b)
	m := expect_route(&f, .Get, "/a/b/d", "/a/*rest")
	ps := router.match_params(&m)
	// The failed :x branch must not leave its capture behind.
	testing.expect_value(t, len(ps), 1)
	testing.expect_value(t, ps[0].name, "rest")
	testing.expect_value(t, ps[0].value, "b/d")
}

@(test)
test_match_wildcard_captures_rest_and_empty :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/static/*path", h_a)
	m := expect_route(&f, .Get, "/static/css/site/main.css", "/static/*path")
	testing.expect_value(t, router.match_params(&m)[0].value, "css/site/main.css")
	m = expect_route(&f, .Get, "/static/", "/static/*path")
	testing.expect_value(t, router.match_params(&m)[0].value, "")
	expect_lookup_error(&f, .Get, "/static", .Not_Found)
}

@(test)
test_match_bare_wildcard_uses_star_name :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/*", h_a)
	m := expect_route(&f, .Get, "/any/thing", "/*")
	v, ok := router.params_get(router.match_params(&m), "*")
	testing.expect(t, ok)
	testing.expect_value(t, v, "any/thing")
}

@(test)
test_match_colon_inside_segment_is_literal :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Post, "/v1/files:batch", h_a)
	add(&f, .Get, "/a*b", h_b)
	m := expect_route(&f, .Post, "/v1/files:batch", "/v1/files:batch")
	testing.expect_value(t, m.param_count, 0)
	expect_route(&f, .Get, "/a*b", "/a*b")
	expect_lookup_error(&f, .Post, "/v1/filesXbatch", .Not_Found)
}

@(test)
test_match_ignores_query_and_fragment :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/search/:q", h_a)
	m := expect_route(&f, .Get, "/search/odin?page=2&sort=new", "/search/:q")
	testing.expect_value(t, router.match_params(&m)[0].value, "odin")
	expect_route(&f, .Get, "/search/odin#top", "/search/:q")
}

@(test)
test_match_keeps_percent_escapes_raw :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/tags/:tag", h_a)
	m := expect_route(&f, .Get, "/tags/c%2B%2B", "/tags/:tag")
	testing.expect_value(t, router.match_params(&m)[0].value, "c%2B%2B")
}

@(test)
test_match_rejects_invalid_paths :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/*rest", h_a)
	expect_lookup_error(&f, .Get, "", .Invalid_Path)
	expect_lookup_error(&f, .Get, "users", .Invalid_Path)
	expect_lookup_error(&f, .Get, "*", .Invalid_Path)
	expect_lookup_error(&f, .Get, "?a=b", .Invalid_Path)
	expect_lookup_error(&f, .Get, "http://example.com/", .Invalid_Path)
}

@(test)
test_match_selects_route_by_method_across_branches :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/new", h_a)
	add(&f, .Post, "/users/:id", h_b)
	// The static branch has no POST route, so the parameter branch serves it.
	m := expect_route(&f, .Post, "/users/new", "/users/:id")
	testing.expect_value(t, m.route.method, router.Method.Post)
	expect_route(&f, .Get, "/users/new", "/users/new")
}

@(test)
test_match_param_values_borrow_the_path :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/u/:id", h_a)
	path := "/u/abc"
	m, _ := router.router_lookup(&f.r, .Get, path)
	v := router.match_params(&m)[0].value
	testing.expect_value(t, rawptr(raw_data(v)), rawptr(uintptr(raw_data(path)) + 3))
}

// ---- 404, 405, HEAD and OPTIONS ----

@(test)
test_serve_runs_handler_and_returns_none :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_ok)
	rec: Recorder
	testing.expect_value(t, run(&f, "GET", "/users/9", &rec), router.Lookup_Error.None)
	testing.expect_value(t, rec.status, 200)
	testing.expect_value(t, body(&rec), "/users/:id")
}

@(test)
test_serve_exposes_params_to_handler :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id", h_echo_id)
	rec: Recorder
	run(&f, "GET", "/users/alice?x=1", &rec)
	testing.expect_value(t, body(&rec), "alice")
}

@(test)
test_serve_not_found_writes_404 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_a)
	rec: Recorder
	testing.expect_value(t, run(&f, "GET", "/b", &rec), router.Lookup_Error.Not_Found)
	testing.expect_value(t, rec.status, 404)
	testing.expect_value(t, body(&rec), "404 Not Found\n")
	testing.expect(t, !rec.has_allow)
}

@(test)
test_serve_method_not_allowed_writes_allow_header :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/items", h_a)
	add(&f, .Post, "/items", h_b)
	rec: Recorder
	testing.expect_value(t, run(&f, "DELETE", "/items", &rec), router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, rec.status, 405)
	testing.expect_value(t, allow(&rec), "GET, HEAD, POST, OPTIONS")
	testing.expect_value(t, body(&rec), "405 Method Not Allowed\n")
	testing.expect_value(t, rec.step_count, 0)
}

@(test)
test_allow_unions_methods_of_every_matching_route :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/new", h_a)
	add(&f, .Put, "/users/:id", h_b)
	add(&f, .Delete, "/users/*rest", h_c)
	add(&f, .Post, "/other", h_c)
	m, err := router.router_lookup(&f.r, .Patch, "/users/new")
	testing.expect_value(t, err, router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, m.allowed, router.Methods{.Get, .Head, .Put, .Delete, .Options})
}

@(test)
test_head_falls_back_to_get :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/page", h_a)
	m := expect_route(&f, .Head, "/page", "/page")
	testing.expect_value(t, m.route.method, router.Method.Get)
}

@(test)
test_head_route_beats_get_fallback :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/page", h_a)
	add(&f, .Head, "/page", h_b)
	m := expect_route(&f, .Head, "/page", "/page")
	testing.expect_value(t, m.route.method, router.Method.Head)
}

@(test)
test_head_fallback_can_be_disabled :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	f.r.head_uses_get = false
	add(&f, .Get, "/page", h_a)
	m, err := router.router_lookup(&f.r, .Head, "/page")
	testing.expect_value(t, err, router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, m.allowed, router.Methods{.Get, .Options})
}

@(test)
test_options_is_answered_automatically :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/items/:id", h_a)
	add(&f, .Patch, "/items/:id", h_a)
	rec: Recorder
	testing.expect_value(t, run(&f, "OPTIONS", "/items/3", &rec), router.Lookup_Error.None)
	testing.expect_value(t, rec.status, 204)
	testing.expect_value(t, allow(&rec), "GET, HEAD, PATCH, OPTIONS")
	testing.expect_value(t, rec.body_len, 0)
}

@(test)
test_options_on_unknown_path_is_404 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_a)
	rec: Recorder
	testing.expect_value(t, run(&f, "OPTIONS", "/b", &rec), router.Lookup_Error.Not_Found)
	testing.expect_value(t, rec.status, 404)
}

@(test)
test_automatic_options_can_be_disabled :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	f.r.handle_options = false
	add(&f, .Get, "/a", h_a)
	rec: Recorder
	testing.expect_value(t, run(&f, "OPTIONS", "/a", &rec), router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, rec.status, 405)
	testing.expect_value(t, allow(&rec), "GET, HEAD")
}

@(test)
test_explicit_options_route_wins :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_a)
	add(&f, .Options, "/a", h_b)
	rec: Recorder
	testing.expect_value(t, run(&f, "OPTIONS", "/a", &rec), router.Lookup_Error.None)
	testing.expect_value(t, rec.step_count, 1)
	testing.expect_value(t, rec.steps[0], "b")
	testing.expect(t, !rec.has_allow)
}

@(test)
test_unknown_method_gets_405_or_404 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_a)
	rec: Recorder
	testing.expect_value(t, run(&f, "PURGE", "/a", &rec), router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, allow(&rec), "GET, HEAD, OPTIONS")
	rec = {}
	testing.expect_value(t, run(&f, "get", "/nope", &rec), router.Lookup_Error.Not_Found)
}

@(test)
test_serve_bad_path_writes_400 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	rec: Recorder
	testing.expect_value(t, run(&f, "GET", "", &rec), router.Lookup_Error.Invalid_Path)
	testing.expect_value(t, rec.status, 400)
	rec = {}
	testing.expect_value(t, run(&f, "OPTIONS", "*", &rec), router.Lookup_Error.Invalid_Path)
	testing.expect_value(t, rec.status, 400)
}

custom_not_found :: proc(ctx: ^router.Context) {
	mark(ctx, "custom404")
	router.write_status(ctx, 410)
}

custom_405 :: proc(ctx: ^router.Context) {
	mark(ctx, "custom405")
	if ctx.allowed == {.Post, .Options} {
		mark(ctx, "post-only")
	}
	router.write_status(ctx, 418)
}

custom_400 :: proc(ctx: ^router.Context) {
	mark(ctx, "custom400")
}

@(test)
test_custom_fallback_handlers_run :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	f.r.not_found = custom_not_found
	f.r.method_not_allowed = custom_405
	f.r.bad_request = custom_400
	add(&f, .Post, "/form", h_a)
	buf: [64]byte

	rec: Recorder
	run(&f, "GET", "/missing", &rec)
	testing.expect_value(t, trace(&rec, buf[:]), "custom404")
	testing.expect_value(t, rec.status, 410)

	rec = {}
	run(&f, "GET", "/form", &rec)
	testing.expect_value(t, trace(&rec, buf[:]), "custom405 post-only")
	testing.expect_value(t, rec.status, 418)

	rec = {}
	run(&f, "GET", "form", &rec)
	testing.expect_value(t, trace(&rec, buf[:]), "custom400")
}

@(test)
test_nil_response_procs_are_ignored :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/a", h_ok)
	rec: Recorder
	testing.expect_value(t, router.serve(&f.r, {method = "GET", path = "/a"}, {}, &rec), router.Lookup_Error.None)
	testing.expect_value(t, router.serve(&f.r, {method = "DELETE", path = "/a"}, {}, &rec), router.Lookup_Error.Method_Not_Allowed)
	testing.expect_value(t, router.serve(&f.r, {method = "GET", path = "/b"}, {}, &rec), router.Lookup_Error.Not_Found)
	testing.expect_value(t, rec.steps[0], "ok")
}

@(test)
test_serve_and_lookup_do_not_allocate :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/users/:id/files/*path", h_ok)
	testing.expect_value(t, router.use(&f.r, mw_outer), nil)
	before := f.track.total_allocation_count
	context.allocator = f.alloc
	context.temp_allocator = f.alloc
	rec: Recorder
	run(&f, "GET", "/users/1/files/a/b", &rec)
	run(&f, "POST", "/users/1/files/a/b", &rec)
	run(&f, "GET", "/nope", &rec)
	router.router_lookup(&f.r, .Get, "/users/1/files/x")
	testing.expect_value(t, f.track.total_allocation_count, before)
}

// ---- Groups and middleware ----

@(test)
test_group_prefixes_patterns :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	api, err := router.group(&f.r, "/api")
	testing.expect_value(t, err, nil)
	v1, err1 := router.group(api, "/v1/")
	testing.expect_value(t, err1, nil)
	testing.expect_value(t, v1.prefix, "/api/v1")
	testing.expect_value(t, router.handle(v1, .Get, "/users/:id", h_a), nil)
	testing.expect_value(t, router.handle(api, .Get, "/health", h_a), nil)
	expect_route(&f, .Get, "/api/v1/users/5", "/api/v1/users/:id")
	expect_route(&f, .Get, "/api/health", "/api/health")
	expect_lookup_error(&f, .Get, "/users/5", .Not_Found)
}

@(test)
test_group_root_pattern_keeps_slash :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	api, _ := router.group(&f.r, "/api")
	testing.expect_value(t, router.handle(api, .Get, "/", h_a), nil)
	expect_route(&f, .Get, "/api/", "/api/")
	expect_lookup_error(&f, .Get, "/api", .Not_Found)
}

@(test)
test_group_prefix_may_hold_params :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	user, err := router.group(&f.r, "/users/:id")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, router.handle(user, .Get, "/posts/:post", h_a), nil)
	testing.expect_value(t, router.handle(user, .Get, "/posts/:id", h_a), route_err(.Duplicate_Param_Name))
	m := expect_route(&f, .Get, "/users/7/posts/99", "/users/:id/posts/:post")
	testing.expect_value(t, m.param_count, 2)
}

@(test)
test_group_rejects_bad_prefixes :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	_, e1 := router.group(&f.r, "api")
	testing.expect_value(t, e1, route_err(.Missing_Leading_Slash))
	_, e2 := router.group(&f.r, "/files/*path")
	testing.expect_value(t, e2, route_err(.Wildcard_Not_Last))
	_, e3 := router.group(&f.r, "/a/:")
	testing.expect_value(t, e3, route_err(.Invalid_Param_Name))
	_, e4 := router.group(&f.r, "/a?b")
	testing.expect_value(t, e4, route_err(.Invalid_Character))
	g, e5 := router.group(&f.r, "")
	testing.expect_value(t, e5, nil)
	testing.expect_value(t, g.prefix, "")
}

@(test)
test_group_rejects_excessive_nesting :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	parent: router.Target = &f.r
	for _ in 1 ..< router.MAX_GROUP_DEPTH {
		g, err := router.group(parent, "/g")
		testing.expect_value(t, err, nil)
		parent = g
	}
	_, err := router.group(parent, "/g")
	testing.expect_value(t, err, route_err(.Group_Too_Deep))
}

@(test)
test_middleware_runs_outside_in :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	api, _ := router.group(&f.r, "/api")
	testing.expect_value(t, router.use(&f.r, mw_outer), nil)
	testing.expect_value(t, router.use(api, mw_inner), nil)
	testing.expect_value(t, router.handle(api, .Get, "/x", h_a), nil)
	rec: Recorder
	run(&f, "GET", "/api/x", &rec)
	buf: [128]byte
	testing.expect_value(t, trace(&rec, buf[:]), "outer> inner> a <inner <outer")
}

@(test)
test_middleware_added_after_routes_still_applies :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	add(&f, .Get, "/x", h_a)
	testing.expect_value(t, router.use(&f.r, mw_outer, mw_inner), nil)
	rec: Recorder
	run(&f, "GET", "/x", &rec)
	buf: [128]byte
	testing.expect_value(t, trace(&rec, buf[:]), "outer> inner> a <inner <outer")
}

@(test)
test_middleware_can_stop_the_chain :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	admin, _ := router.group(&f.r, "/admin")
	testing.expect_value(t, router.use(admin, mw_block, mw_inner), nil)
	testing.expect_value(t, router.handle(admin, .Get, "/panel", h_a), nil)
	rec: Recorder
	testing.expect_value(t, run(&f, "GET", "/admin/panel", &rec), router.Lookup_Error.None)
	buf: [64]byte
	testing.expect_value(t, trace(&rec, buf[:]), "block")
	testing.expect_value(t, rec.status, 401)
}

@(test)
test_next_twice_runs_handler_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.use(&f.r, mw_twice), nil)
	add(&f, .Get, "/x", h_a)
	rec: Recorder
	run(&f, "GET", "/x", &rec)
	testing.expect_value(t, rec.step_count, 1)
}

@(test)
test_base_middleware_wraps_fallback_handlers :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	api, _ := router.group(&f.r, "/api")
	testing.expect_value(t, router.use(&f.r, mw_outer), nil)
	testing.expect_value(t, router.use(api, mw_inner), nil)
	f.r.not_found = custom_not_found
	rec: Recorder
	run(&f, "GET", "/api/missing", &rec)
	buf: [128]byte
	// Only base middleware wraps a 404: no group owns a path that matched nothing.
	testing.expect_value(t, trace(&rec, buf[:]), "outer> custom404 <outer")
}

@(test)
test_group_middleware_stays_in_its_group :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	a, _ := router.group(&f.r, "/a")
	b, _ := router.group(&f.r, "/b")
	testing.expect_value(t, router.use(a, mw_inner), nil)
	testing.expect_value(t, router.handle(a, .Get, "/x", h_a), nil)
	testing.expect_value(t, router.handle(b, .Get, "/x", h_b), nil)
	rec: Recorder
	run(&f, "GET", "/b/x", &rec)
	buf: [64]byte
	testing.expect_value(t, trace(&rec, buf[:]), "b")
}

@(test)
test_use_rejects_nil_and_adds_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.use(&f.r, mw_outer, nil), route_err(.Nil_Handler))
	testing.expect_value(t, len(f.r.base.middleware), 0)
	uninit: router.Router
	testing.expect_value(t, router.use(&uninit, mw_outer), route_err(.Invalid_Target))
}

set_user :: proc(ctx: ^router.Context) {
	// Middleware swaps in its own per-request state, then restores the caller's.
	saved := ctx.user
	inner: Recorder
	ctx.user = &inner
	router.next(ctx)
	ctx.user = saved
	mark(ctx, inner.steps[0])
}

@(test)
test_middleware_can_replace_user_state :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	testing.expect_value(t, router.use(&f.r, set_user), nil)
	add(&f, .Get, "/x", h_c)
	rec: Recorder
	run(&f, "GET", "/x", &rec)
	testing.expect_value(t, rec.step_count, 1)
	testing.expect_value(t, rec.steps[0], "c")
}

@(test)
test_routes_list_records_registration_order :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	api, _ := router.group(&f.r, "/api")
	add(&f, .Get, "/b", h_a)
	testing.expect_value(t, router.handle(api, .Post, "/a", h_a), nil)
	testing.expect_value(t, len(f.r.routes), 2)
	testing.expect_value(t, f.r.routes[0].pattern, "/b")
	testing.expect_value(t, f.r.routes[1].pattern, "/api/a")
	testing.expect_value(t, f.r.routes[1].method, router.Method.Post)
	testing.expect(t, f.r.routes[1].group == api)
}

@(test)
test_router_destroy_frees_large_tree :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 200 {
		strings.builder_reset(&b)
		strings.write_string(&b, "/r")
		strings.write_int(&b, i)
		strings.write_string(&b, "/:id/x")
		strings.write_int(&b, i % 7)
		add(&f, .Get, strings.to_string(b), h_a)
	}
	expect_route(&f, .Get, "/r123/9/x4", "/r123/:id/x4")
	expect_route(&f, .Get, "/r12/9/x5", "/r12/:id/x5")
	testing.expect_value(t, len(f.r.routes), 200)
}
