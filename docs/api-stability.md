# Public API contract

Jevlin is still `0.1.0-dev`, targeting Zig 0.16.0. This document defines the
reviewed source API and the checks used to detect accidental changes; it is not
a 1.0 compatibility guarantee. Before a tagged release, breaking changes require
an explicit compatibility review and updates to this contract, its consumer
sentinel, and migration instructions. A passing sentinel is evidence for the
covered usage, not proof that every possible downstream program is compatible.

## Supported entry points

Import the `jevlin` module exported by `build.zig`.

| Area | Public API |
| --- | --- |
| Client | `Client.init(Transport, Config)`, `Client.evaluate(state, questions, model, Workspace, *Diagnostics)` |
| HTTP | `Http.init(allocator, io, api_key)`, `Http.transport()`, `Http.deinit()` |
| Configuration and errors | `Config`, `Error`, `Diagnostics` |
| Custom transport | `Transport`, `TransportError`, `Reply` |
| Buffers and results | `Workspace`, `Result(QuestionsType)`, `Answers(QuestionsType)`, `Usage` |
| Text questions | `noul`, `choice`, `score`, `Choice(Enum)`, `Score(level_count)` |
| Structured questions | `noulWithCriteria`, `choiceStructured`, `scoreStructured` |

The existing `engine.Config`, `engine.Diagnostics`, `engine.Transport`,
`engine.Error`, and `engine.Reply` paths remain aliases of the same types.
Prefer the top-level names in new applications. Direct engine helper calls,
imports of internal source files, and the storage fields of `Client` and `Http`
are implementation details outside this supported contract. Do not mutate their
state, construct them with struct literals, or depend on their binary layout.
There is no C ABI or serialized-memory-layout guarantee.

The consumer sentinel in `examples/api_contract.zig` checks function signatures,
documented field types, the complete public error set, default values, typed
answers, and legacy aliases. The separate package consumer compiles and runs
this same sentinel against a fetched archive. The examples exercise evaluation
and structured helpers; the contract suite checks wire and error semantics.
Additive error variants also require review: they break exhaustive Zig switches.

## Defaults and results

`Config` defaults to a 10,000 ms total deadline, two retries (at most three
attempts), 100 ms initial backoff, and PRNG seed 1. Valid limits are
1–300,000 ms, 0–8 retries, and 0–5,000 ms backoff. Retries may repeat a billable
request. HTTP 408, 429, and 5xx and `TransportFailure` are retryable within the
configured budget; TLS errors and invalid responses are not automatically retried.

`Result(Q)` contains `answers: Answers(Q)`, `model: []const u8`,
`raw: []const u8`, `usage: ?Usage`, and `attempts: u8`. `Usage` has unsigned
64-bit input/output token counts. Missing usage is distinct from zero usage.
Choice answers contain the caller's enum, named probabilities, and confidence.
Score answers contain a score, fixed-length probability and legend arrays, and
confidence. Noul answers contain a probability. Numeric answer fields are `f64`.
See the [wire contract](contract.md) for validation tolerances and limits.

## Ownership and concurrency

- Keep each `Client` and its transport context alive and at stable addresses
  throughout their calls. Keep `Http` at a stable address after obtaining its
  transport. Do not copy active clients or adapters.
- One call can run on a client at a time. An overlapping call returns `Busy`
  without touching that call's workspace or diagnostics. The guard does not make
  sharing diagnostics, buffers, or mutating configuration concurrently safe.
- Each in-flight call needs its own diagnostics and three nonempty, disjoint
  buffers. Request bytes hold encoded JSON; response bytes hold the response;
  scratch holds encoding validation and parsed JSON. Capacities are application
  limits, not automatic allocations. There is no universal scratch-to-body ratio.
- State, questions, model strings, and their referenced data must remain valid
  through the synchronous call. Custom serializers execute caller code.
- Result model/raw slices, Score legend contents, and diagnostic body/JSON borrow
  workspace. They become invalid when that storage is reused or freed, including
  a subsequent call that fails. Copy retained text/JSON before reuse. Numbers,
  enums, and numeric arrays can be copied by value.
- Diagnostics reset after acquiring the client. They describe the current call;
  a later transport failure clears stale HTTP details. `error_json` is best effort
  and may be absent for non-JSON bodies or insufficient scratch capacity.
- `Http.init` copies the key; `deinit` wipes its internal authorization buffer.
  The allocator and I/O context must outlive all calls. Wait for workers to finish
  before deinitializing. HTTP/TLS uses heap allocation; the codec uses caller buffers.

For bounded parallel use, give each worker its own client, adapter, diagnostics,
and buffers. The [parallel example](../examples/parallel.zig) starts four workers,
processes a finite batch, and joins or cancels every started worker on all exits.

## Errors and application response

| Errors | Meaning and handling |
| --- | --- |
| `InvalidConfig` | Invalid configuration/key or overlapping buffers; correct setup |
| `Busy` | Client already in use; serialize calls or use independent workers |
| `InvalidRequest` | Local request validation failed; correct input |
| `RequestTooLarge` | Request encoding exceeded capacity before transport; increase the request budget or reduce input |
| `WorkspaceTooSmall` | Empty buffers or exhausted scratch; may occur before or after transport |
| `ResponseTooLarge` | Response exceeded capacity; an upstream request may already have completed |
| `OutOfMemory` | Allocating transport failed; restore resources before considering another call |
| `DeadlineExceeded`, `Canceled` | Call stopped; upstream processing may already have occurred |
| `ConcurrencyUnavailable` | I/O runtime could not start required work |
| `TransportFailure`, `TlsFailure` | Transport or certificate/TLS failure; investigate diagnostics and configuration |
| `BadRequest` | HTTP 400 or 422; correct the request |
| `Unauthorized` | HTTP 401 or 403; verify credentials/access |
| `RateLimited` | HTTP 429 after the retry policy stopped |
| `ServerError` | HTTP 5xx after the retry policy stopped |
| `UnexpectedStatus` | Other non-2xx status, including exhausted HTTP 408 retries |
| `InvalidResponse` | Malformed, unsupported, or semantically invalid response |

Do not automatically replay every capacity or deadline error: a request may
already have reached the server and incurred charges. Log status, attempts, and
error names by default; raw diagnostics may contain sensitive upstream data.
There is no public `Client.cancel()` method. The HTTP adapter uses the supplied
I/O runtime's cooperative cancellation and joins its work before returning.

## Implementing a transport

`Transport.context` points to caller-owned state. `now` returns monotonic
nanoseconds (`i96`); `sleep` accepts a relative nanosecond delay (`u64`);
`exchange` receives encoded request bytes, writable response capacity, and an
absolute deadline on the same clock. Return `Reply` with status, bytes written,
and an optional relative retry delay in nanoseconds. Return transport failures
as `TransportError`; return HTTP failures as statuses so the client can classify
them and preserve their bodies.

Honor capacity, cancellation, and deadlines. Do not retain or access caller
buffers after returning, even on failure. Cleanup must finish before return.
The client cannot enforce these properties on an arbitrary custom transport.
The examples' fixed-response transport is solely an offline teaching fixture.
