# mylib

[![CI](https://github.com/alexisbcz/mylib/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/mylib/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

One sentence that says what this library does and why someone would pick it.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/mylib libs/mylib
```

```odin
import "libs/mylib"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/mylib ~/odin-shared/mylib
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:mylib"
```

## Quick start

```odin
package main

import "core:fmt"
import "shared:mylib"

main :: proc() {
	line, err := mylib.repeat("na", 8)
	if err != nil {
		fmt.eprintln("repeat failed:", err)
		return
	}
	defer delete(line)
	fmt.println(line, "batman")
}
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `repeat(s, count, allocator)` | Concatenate `s` with itself `count` times | Yes | `delete` |
| `Tally` | Count how often each word occurs | Not by itself | `tally_destroy` |
| `tally_init(t, allocator)` | Prepare a `Tally` | Yes | `tally_destroy` |
| `tally_add(t, word)` | Record one occurrence, copying new words | Yes | `tally_destroy` |
| `tally_count(t, word)` | Look up a count | No | Not needed |
| `Error` | Union of `Repeat_Error` and `runtime.Allocator_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result.
- Fallible procedures return `(T, Error)`. The library never panics on bad input.
- The package keeps no global mutable state, so it's safe to use from several threads as long as each value stays on one thread.

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
