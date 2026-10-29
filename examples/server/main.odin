/*
Example server plugs the router into a tiny HTTP/1.1 server built on core:net.

Run it with `odin run examples/server`, then try:

	curl -i localhost:8080/
	curl -i localhost:8080/hello/odin
	curl -i -X POST localhost:8080/hello/odin

The server handles one connection at a time and closes it after one response.
It exists to show the integration, not to face the internet.
*/
package main

import router "../.."
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

ADDRESS :: "127.0.0.1:8080"
MAX_REQUEST_HEAD :: 8 * 1024

// Response collects what the handlers write, then the server sends it in one go.
Response :: struct {
	status:  int,
	headers: strings.Builder,
	body:    strings.Builder,
}

response_set_header :: proc(data: rawptr, name, value: string) {
	res := (^Response)(data)
	fmt.sbprintf(&res.headers, "%s: %s\r\n", name, value)
}

response_write_status :: proc(data: rawptr, status: int) {
	(^Response)(data).status = status
}

response_write :: proc(data: rawptr, body: []byte) {
	strings.write_bytes(&(^Response)(data).body, body)
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 204:
		return "No Content"
	case 400:
		return "Bad Request"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	}
	return "Unknown"
}

index :: proc(ctx: ^router.Context) {
	router.set_header(ctx, "Content-Type", "text/plain; charset=utf-8")
	router.write_status(ctx, 200)
	router.write_string(ctx, "Try /hello/:name\n")
}

hello :: proc(ctx: ^router.Context) {
	name, _ := router.param(ctx, "name")
	router.set_header(ctx, "Content-Type", "text/plain; charset=utf-8")
	router.write_status(ctx, 200)
	router.write_string(ctx, "Hello, ")
	router.write_string(ctx, name)
	router.write_string(ctx, "\n")
}

handle_connection :: proc(r: ^router.Router, client: net.TCP_Socket) {
	buf: [MAX_REQUEST_HEAD]byte
	n := 0
	for n < len(buf) {
		got, err := net.recv_tcp(client, buf[n:])
		if err != nil || got == 0 {
			return
		}
		n += got
		if strings.contains(string(buf[:n]), "\r\n\r\n") {
			break
		}
	}

	// Request line: METHOD SP TARGET SP VERSION
	head := string(buf[:n])
	line_end := strings.index(head, "\r\n")
	if line_end < 0 {
		return
	}
	parts := strings.split(head[:line_end], " ", context.temp_allocator)
	if len(parts) != 3 {
		return
	}

	res: Response
	res.status = 200
	res.headers = strings.builder_make()
	res.body = strings.builder_make()
	defer strings.builder_destroy(&res.headers)
	defer strings.builder_destroy(&res.body)

	writer := router.Response_Writer {
		data         = &res,
		set_header   = response_set_header,
		write_status = response_write_status,
		write        = response_write,
	}
	router.serve(r, {method = parts[0], path = parts[1]}, writer)

	body := strings.to_string(res.body)
	if parts[0] == "HEAD" {
		body = ""
	}
	out := fmt.tprintf(
		"HTTP/1.1 %d %s\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		res.status,
		status_text(res.status),
		strings.to_string(res.headers),
		len(res.body.buf),
		body,
	)
	_, _ = net.send_tcp(client, transmute([]byte)out)
}

main :: proc() {
	r: router.Router
	if err := router.router_init(&r); err != nil {
		fmt.eprintln("router_init failed:", err)
		os.exit(1)
	}
	defer router.router_destroy(&r)

	if err := router.handle(&r, .Get, "/", index); err != nil {
		fmt.eprintln("route failed:", err)
		os.exit(1)
	}
	if err := router.handle(&r, .Get, "/hello/:name", hello); err != nil {
		fmt.eprintln("route failed:", err)
		os.exit(1)
	}

	endpoint, ok := net.parse_endpoint(ADDRESS)
	if !ok {
		fmt.eprintln("bad address", ADDRESS)
		os.exit(1)
	}
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintln("listen failed:", err)
		os.exit(1)
	}
	defer net.close(listener)
	fmt.println("listening on http://" + ADDRESS)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			continue
		}
		handle_connection(&r, client)
		net.close(client)
		free_all(context.temp_allocator)
	}
}
