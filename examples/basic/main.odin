// Example basic routes a few fake requests through a router and prints the responses. Run it with `odin run examples/basic`.
package main

import router "../.."
import "core:fmt"
import "core:os"
import "core:strings"

// Response is a minimal in-memory response that the router writes through.
Response :: struct {
	status: int,
	allow:  string,
	body:   strings.Builder,
}

response_set_header :: proc(data: rawptr, name, value: string) {
	res := (^Response)(data)
	if name == "Allow" {
		res.allow = strings.clone(value, context.temp_allocator)
	}
}

response_write_status :: proc(data: rawptr, status: int) {
	(^Response)(data).status = status
}

response_write :: proc(data: rawptr, body: []byte) {
	strings.write_bytes(&(^Response)(data).body, body)
}

list_users :: proc(ctx: ^router.Context) {
	router.write_status(ctx, 200)
	router.write_string(ctx, "alice, bob")
}

show_user :: proc(ctx: ^router.Context) {
	id, _ := router.param(ctx, "id")
	router.write_status(ctx, 200)
	router.write_string(ctx, "user ")
	router.write_string(ctx, id)
}

serve_file :: proc(ctx: ^router.Context) {
	path, _ := router.param(ctx, "path")
	router.write_status(ctx, 200)
	router.write_string(ctx, "file ")
	router.write_string(ctx, path)
}

// log_requests is middleware: it runs the rest of the chain, then logs the result.
log_requests :: proc(ctx: ^router.Context) {
	router.next(ctx)
	res := (^Response)(ctx.response.data)
	fmt.printf("%-7s %-24s -> %d", ctx.request.method, ctx.request.path, res.status)
}

main :: proc() {
	r: router.Router
	if err := router.router_init(&r); err != nil {
		fmt.eprintln("router_init failed:", err)
		os.exit(1)
	}
	defer router.router_destroy(&r)

	api, gerr := router.group(&r, "/api")
	if gerr != nil {
		fmt.eprintln("group failed:", gerr)
		os.exit(1)
	}
	errs := [?]router.Error {
		router.use(&r, log_requests),
		router.handle(api, .Get, "/users", list_users),
		router.handle(api, .Get, "/users/:id", show_user),
		router.handle(&r, .Get, "/static/*path", serve_file),
	}
	for err in errs {
		if err != nil {
			fmt.eprintln("route registration failed:", err)
			os.exit(1)
		}
	}

	requests := [?]router.Request {
		{method = "GET", path = "/api/users"},
		{method = "GET", path = "/api/users/42?verbose=1"},
		{method = "GET", path = "/static/css/site.css"},
		{method = "DELETE", path = "/api/users/42"},
		{method = "OPTIONS", path = "/api/users"},
		{method = "GET", path = "/nowhere"},
	}
	for req in requests {
		res: Response
		res.body = strings.builder_make()
		defer strings.builder_destroy(&res.body)

		writer := router.Response_Writer {
			data         = &res,
			set_header   = response_set_header,
			write_status = response_write_status,
			write        = response_write,
		}
		router.serve(&r, req, writer)
		if res.allow != "" {
			fmt.printf("  Allow: %s", res.allow)
		}
		fmt.printf("  %q\n", strings.to_string(res.body))
	}
	free_all(context.temp_allocator)
}
