package router

// MAX_PARAMS is the most `:param` and `*wildcard` segments one route may declare.
MAX_PARAMS :: 16

@(private)
Token_Kind :: enum u8 {
	Static,
	Param,
	Wildcard,
}

// Token is one piece of a parsed pattern. `text` borrows the pattern string.
@(private)
Token :: struct {
	kind: Token_Kind,
	text: string,
}

// Each parameter can be preceded by a static run, plus one trailing static run.
@(private)
MAX_TOKENS :: MAX_PARAMS * 2 + 1

@(private)
Pattern :: struct {
	tokens: [MAX_TOKENS]Token,
	count:  int,
}

@(private)
pattern_push :: proc(p: ^Pattern, kind: Token_Kind, text: string) {
	assert(p.count < MAX_TOKENS, "router: token buffer overflow")
	p.tokens[p.count] = {kind, text}
	p.count += 1
}

@(private)
is_name_byte :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
		return true
	}
	return false
}

/*
pattern_parse splits `pattern` into static runs, parameters and an optional
trailing wildcard. A `:` or `*` is special only at the start of a segment, so
"/v1/files:batch" is a static pattern. The tokens borrow `pattern`.
*/
@(private)
pattern_parse :: proc(pattern: string, p: ^Pattern) -> Route_Error {
	p.count = 0
	if len(pattern) == 0 {
		return .Empty_Pattern
	}
	if pattern[0] != '/' {
		return .Missing_Leading_Slash
	}

	params := 0
	start := 0
	i := 0
	for i < len(pattern) {
		c := pattern[i]
		if c == '?' || c == '#' || c <= ' ' || c == 0x7f {
			return .Invalid_Character
		}
		// pattern[0] is '/', so `i - 1` is in range whenever c is ':' or '*'.
		if !((c == ':' || c == '*') && pattern[i - 1] == '/') {
			i += 1
			continue
		}

		// A parameter or wildcard runs to the end of its segment.
		j := i + 1
		for j < len(pattern) && pattern[j] != '/' {
			j += 1
		}
		name := pattern[i + 1:j]
		kind := Token_Kind.Param
		if c == '*' {
			kind = .Wildcard
			if j < len(pattern) {
				return .Wildcard_Not_Last
			}
			if name == "" {
				// A bare `*` captures under the name "*".
				name = pattern[i:j]
			}
		}
		if name == "" {
			return .Invalid_Param_Name
		}
		if name != "*" {
			for k in 0 ..< len(name) {
				if !is_name_byte(name[k]) {
					return .Invalid_Param_Name
				}
			}
		}
		for t in p.tokens[:p.count] {
			if t.kind != .Static && t.text == name {
				return .Duplicate_Param_Name
			}
		}
		params += 1
		if params > MAX_PARAMS {
			return .Too_Many_Params
		}
		if i > start {
			pattern_push(p, .Static, pattern[start:i])
		}
		pattern_push(p, kind, name)
		i = j
		start = j
	}
	if start < len(pattern) {
		pattern_push(p, .Static, pattern[start:])
	}
	return .None
}
