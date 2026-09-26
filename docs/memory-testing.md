# Memory and fuzz testing

The ordinary `zig build check` suite includes the following bounded campaigns.
They use fixed seeds and require no credentials or external service.

| Campaign | Scope and oracle |
| --- | --- |
| 100,000 parser cases | Mutations of all 66 contract fixtures, truncation, insertion, random bytes, and unchanged seeds; variable scratch capacities; defined error set, guard bytes, typed answer bounds |
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

## Coverage-guided campaigns

The standalone fuzz target now runs on unmodified Zig 0.16.0 using LLVM with
error-return tracing disabled. The compiler's default fuzz runner otherwise
fails at `test_runner.zig:566` by passing `*builtin.StackTrace` to a function
expecting `*const debug.StackTrace`. Disabling return tracing avoids that branch;
assertions, bounds checks, test failures, allocator leak checks, and coverage
instrumentation remain enabled. Ordinary SDK tests and production builds retain
their usual settings. `-Dfuzz-error-tracing=true` reproduces the original blocker.
The default x86 backend also produced an empty coverage PC table, so the standalone
fuzz target explicitly selects LLVM. No compiler files are patched.

```sh
python3 scripts/fuzz.py --iterations 100000 --optimize Debug
python3 scripts/fuzz.py --iterations 100000 --optimize ReleaseSafe
# Direct invocation of a single oracle:
zig build fuzz -Dfuzz-target=parser --fuzz=100000
zig build fuzz -Dfuzz-target=encoder --fuzz=100000
```

The Python runner is Linux-only. Each oracle gets a fresh local cache so the
reported runs and coverage cannot be inherited from an earlier campaign. A pass
requires a successful exit, the expected oracle, at least the requested runs,
nonzero instrumented/executed PCs, and no captured crash. Zig can slightly
overshoot its requested iteration limit. A 600-second timeout per oracle kills
the entire build/fuzzer process group. JSON reports include actual runs, unique
runs, covered/total PCs, source commit, dirty-checkout status, and toolchain.
PC coverage is for the instrumented test executable, including library code;
it is not a percentage of the SDK's public behavior or a completeness guarantee.

The parser seeds all 66 response fixtures at full and empty scratch capacity.
The encoder seeds empty, plain text, escaped, Unicode, invalid UTF-8, and maximum
length inputs at full and empty output capacity. Corpus serialization follows
Zig 0.16.0 Smith's slice-length/bytes/weighted-integer format. These seeds also run
as ordinary regression inputs during `zig build check`.

The manually triggered **Jevlin coverage-guided fuzzing** workflow runs separate
Debug and ReleaseSafe jobs and uploads `fuzz-results/` reports, logs, and any
captured crash inputs. It performs no API calls. Deterministic campaigns remain
part of normal six-job native CI; coverage-guided campaigns are a separate
Linux workflow.

### Crash replay and promotion

On failure, the runner preserves Zig's `cache/f/crash` as
`fuzz-results/parser-crash.smith` or `encoder-crash.smith` before deleting the
isolated cache. The JSON `crash_saved` flag identifies whether this run captured
an input; older files in a reused output directory are not new findings.
Replay without enabling continuous fuzzing:

```sh
JEVLIN_FUZZ_REPLAY="$PWD/fuzz-results/parser-crash.smith" zig build fuzz -Dfuzz-target=parser
JEVLIN_FUZZ_REPLAY="$PWD/fuzz-results/encoder-crash.smith" zig build fuzz -Dfuzz-target=encoder
```

Always specify the matching oracle. After diagnosing a failure, preserve its
input under `src/fixtures` and add a named regression test with the expected
behavior. A crash is a finding to investigate, not automatically an SDK defect.
The runner removes inherited replay configuration before starting a campaign.

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
