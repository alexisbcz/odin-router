package router

import "base:runtime"
import "core:strings"

@(private)
Node_Kind :: enum u8 {
	Static,
	Param,
	Wildcard,
}

/*
Node is one vertex of the radix tree.

Static nodes hold a compressed run of literal bytes in `prefix`, and no two
static children of a node share a first byte. A node whose full path ends in
'/' may also have one `:param` child and one `*wildcard` child. Every string a
node holds borrows a Route's owned pattern, so nodes never free strings.
*/
@(private)
Node :: struct {
	kind:     Node_Kind,
	prefix:   string,
	name:     string,
	children: [dynamic]^Node,
	param:    ^Node,
	wildcard: ^Node,
	methods:  Methods,
	routes:   [Method]^Route,
}

@(private)
node_new :: proc(kind: Node_Kind, allocator: runtime.Allocator) -> (n: ^Node, err: runtime.Allocator_Error) {
	n = new(Node, allocator) or_return
	n.kind = kind
	n.children = make([dynamic]^Node, allocator)
	return n, nil
}

@(private)
node_destroy :: proc(n: ^Node, allocator: runtime.Allocator) {
	if n == nil {
		return
	}
	for c in n.children {
		node_destroy(c, allocator)
	}
	delete(n.children)
	node_destroy(n.param, allocator)
	node_destroy(n.wildcard, allocator)
	free(n, allocator)
}

@(private)
common_prefix_len :: proc(a, b: string) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

@(private)
node_static_child :: proc(n: ^Node, first: byte) -> int {
	for c, i in n.children {
		if c.prefix[0] == first {
			return i
		}
	}
	return -1
}

/*
node_insert_static walks or extends the tree below `parent` along the literal
run `s`, splitting an existing node when `s` ends inside its prefix. It returns
the node whose full path ends exactly after `s`.
*/
@(private)
node_insert_static :: proc(parent: ^Node, s: string, allocator: runtime.Allocator) -> (end: ^Node, err: runtime.Allocator_Error) {
	n := parent
	s := s
	for len(s) > 0 {
		idx := node_static_child(n, s[0])
		if idx < 0 {
			c := node_new(.Static, allocator) or_return
			c.prefix = s
			if _, e := append(&n.children, c); e != nil {
				node_destroy(c, allocator)
				return nil, e
			}
			return c, nil
		}
		c := n.children[idx]
		l := common_prefix_len(c.prefix, s)
		if l < len(c.prefix) {
			mid := node_new(.Static, allocator) or_return
			if _, e := append(&mid.children, c); e != nil {
				node_destroy(mid, allocator)
				return nil, e
			}
			mid.prefix = c.prefix[:l]
			c.prefix = c.prefix[l:]
			n.children[idx] = mid
			c = mid
		}
		s = s[l:]
		n = c
	}
	return n, nil
}

/*
node_walk_static follows `s` below `n` without changing the tree. It returns
the node whose path ends exactly after `s`, or nil when `s` would branch off
into new territory, where no existing route can conflict.
*/
@(private)
node_walk_static :: proc(n: ^Node, s: string) -> ^Node {
	n := n
	s := s
	for len(s) > 0 {
		idx := node_static_child(n, s[0])
		if idx < 0 {
			return nil
		}
		c := n.children[idx]
		if !strings.has_prefix(s, c.prefix) {
			return nil
		}
		s = s[len(c.prefix):]
		n = c
	}
	return n
}

/*
Search carries the state of one lookup. In find mode the first node, in
priority order, that has a route for a method in `want` wins. In collect mode
the search visits every matching node and unions their methods into `allowed`.
*/
@(private)
Search :: struct {
	want:    Methods,
	collect: bool,
	allowed: Methods,
	params:  [MAX_PARAMS]Param,
	count:   int,
}

@(private)
node_accepts :: proc(n: ^Node, s: ^Search) -> bool {
	if s.collect {
		s.allowed += n.methods
		return false
	}
	return n.methods & s.want != {}
}

/*
node_find matches the rest of the request path against the subtree at `n`.
Static children win over the parameter child, which wins over the wildcard.
When a branch fails deeper down, the search backtracks and tries the next.
*/
@(private)
node_find :: proc(n: ^Node, path: string, s: ^Search) -> ^Node {
	if len(path) == 0 && node_accepts(n, s) {
		return n
	}
	if len(path) > 0 {
		if idx := node_static_child(n, path[0]); idx >= 0 {
			c := n.children[idx]
			if strings.has_prefix(path, c.prefix) {
				if found := node_find(c, path[len(c.prefix):], s); found != nil {
					return found
				}
			}
		}
		if n.param != nil && s.count < MAX_PARAMS {
			end := strings.index_byte(path, '/')
			if end < 0 {
				end = len(path)
			}
			if end > 0 {
				s.params[s.count] = {n.param.name, path[:end]}
				s.count += 1
				if found := node_find(n.param, path[end:], s); found != nil {
					return found
				}
				s.count -= 1
			}
		}
	}
	if n.wildcard != nil && s.count < MAX_PARAMS {
		s.params[s.count] = {n.wildcard.name, path}
		s.count += 1
		if node_accepts(n.wildcard, s) {
			return n.wildcard
		}
		s.count -= 1
	}
	return nil
}
