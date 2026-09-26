# Memory and fuzz testing

The ordinary `zig build check` suite includes the following bounded campaigns.
They use fixed seeds and require no credentials or external service.

| Campaign | Scope and oracle |
| --- | --- |
| 100,000 parser cases | Mutations of all 62 contract fixtures, truncation, insertion, random bytes, and unchanged seeds; variable scratch capacities; defined error set, guard bytes, typed answer bounds |
| 20,000 encoder cases | Arbitrary bytes and ASCII input, variable output capacities; guard bytes, defined errors, exact round-trip for valid UTF-8 strings |
| 4,095 scratch capacities | Public client success or WorkspaceTooSmall; a normal successful request after every attempt |
| Exact capacities | Request length minus one/exact; response length minus one/exact |
| Six overlap layouts | All workspace buffer pairs in both address directions; rejection before transport and successful next call |
| Nesting and malformed input | Depth 32 accepted/33 rejected; invalid UTF-8, duplicate keys, syntax and envelope failures; 700 failure/recovery pairs |
| HTTP allocation failures | Successful baseline then failure at every allocator allocation index on a loopback HTTP success path; allocated/freed byte accounting and same-adapter recovery after restoring memory |

The HTTP test also asserts that the baseline actually allocates, preventing a
vacuous allocation-failure pass. It uses the production exchange/cancellation
code with a private test endpoint. The test allocator checks heap leaks; fixed
codec buffers do not use the heap. HTTP recovery uses the same adapter after
replacing its failing allocator with the test allocator. Each attempt creates a
fresh standard HTTP client, as it does in production.

## Run

```sh
zig build fuzz
zig build check
zig build check -Doptimize=ReleaseSafe
```

The standalone `fuzz` step needs no sockets. The full checks additionally require
loopback sockets. Both build modes run the deterministic campaigns in existing CI.
These tests are bounded mutation/property tests, not coverage-guided exploration.

## Coverage-guided harness and blocker

`src/fuzz.zig` also provides two `std.testing.fuzz` entry points, for parsing plus
typed decoding and for request encoding. Intended invocation:

```sh
zig build fuzz --fuzz=100000
```

On the installed official Zig 0.16.0 Linux toolchain, the attempted coverage-guided
build fails in `lib/compiler/test_runner.zig:566`: `writeStackTrace` expects
`*const debug.StackTrace` but receives `*builtin.StackTrace`. No coverage-guided
iterations completed. The SDK does not patch the compiler or silently treat this
as success. Recheck this command after a compatible toolchain fix; preserve any
resulting crash inputs under `src/fixtures` with a named regression test.

## Limits

Passing does not establish freedom from all crashes or leaks. Input lengths in
the mutation campaigns are capped at 4 KiB (parser) and 2 KiB (encoder); scratch
is capped at 64 KiB. Fixed seeds and immediate guard bytes have finite coverage.
The allocation sweep covers allocator calls on one plain HTTP success path,
not TLS/certificate loading, every HTTP error path, resize-failure injection,
or allocations internal to the I/O runtime. Race stress, sustained resource
monitoring, larger inputs, additional seeds, and TLS failure injection remain.

The newer [certificate suite](tls-certificates.md) additionally sweeps CA loading
and TLS connection allocations. The plain HTTP sweep limits above describe the
original campaign, not the full current test coverage.
