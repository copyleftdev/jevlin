# Jevlin

A small, typed Zig SDK for TypeSafe AI's Jev. Independent and experimental;
not affiliated with TypeSafe AI or TigerBeetle. Targets **Zig 0.16.0**.

See the [changelog](CHANGELOG.md) and [private release rehearsal](docs/releases.md)
for release preparation and versioning policy.

The first working slice sends a batch of Noul, Choice, and Score questions to
`POST https://api.typesafe.ai/v1/systemone`, then validates and decodes typed answers.
It supports JSON-serializable string/object/array state, text helpers, and structured
instructions and criteria.

```zig
const Team = enum { billing, technical, sales };
const questions = .{
    .urgent = jevlin.noul("Does this need urgent help?"),
    .team = jevlin.choice(Team, "Which team should handle this?", .{}),
    .severity = jevlin.score("How severe?", [3][]const u8{
        "Minor inconvenience", "Workaround required", "Unable to use service",
    }),
};
const result = try client.evaluate(
    .{ .ticket = "I was charged twice." }, questions, "jev-latest",
    workspace, &diagnostics,
);
// result.answers.team.choice is Team, not a string.
```

See [the complete runnable example](examples/triage.zig) for initialization,
buffers, credentials, and cleanup.
See the [offline examples](examples/README.md) for structured questions, capacity
errors, and bounded parallel usage, and the [public API contract](docs/api-stability.md)
for ownership, error handling, and compatibility expectations.

## Run

From this directory with Zig 0.16.0 on PATH:

```sh
zig build check
zig build check -Doptimize=ReleaseSafe
python3 scripts/compile_fail.py "$(command -v zig)"
```

Tests use loopback sockets but require no API key or external service.
With `TYPESAFE_API_KEY` already set in the environment, `zig build live` runs a
billable triage request. Retries can cause additional billable requests.
The SDK never loads credential files automatically.

To consume locally, add `.jevlin = .{ .path = "../jevlin" }` under your package's
`build.zig.zon` dependencies, then import `b.dependency("jevlin", .{
.target = target, .optimize = optimize }).module("jevlin")` into your application module.

`python3 scripts/consumer.py` verifies installation from a local archive in a
separate application with a fresh package cache. See the
[compatibility checks](docs/compatibility.md) for platform coverage and limits.

## Contract

- Choice uses an exhaustive enum with 1–255 options; Score has 2–10 levels.
  Invalid static schemas fail compilation. Jevlin limits batches to 128 questions.
- Request, response, and parsing scratch buffers belong to the caller. They must
  not overlap or be shared by simultaneous calls. Capacity failures return errors.
- Result `model`, `raw`, and Score legend values borrow the workspace. Copy them
  before reusing or releasing it. Typed numeric values and enum choices are values.
- One call per client; simultaneous calls receive `Busy`. For parallel calls,
  create a fixed number of clients and separate workspaces. Keep `Http` at a
  stable address until its clients finish; do not copy active clients.
- Default deadline is 10 seconds for encoding, attempts, backoff, and decoding.
  HTTP tasks are canceled and joined before returning. This is cooperative
  cancellation, not a hard real-time guarantee.
- Default maximum is two retries. Only transport failures and HTTP 408, 429,
  and 5xx are retried. `Retry-After` accepts numeric delays and HTTP dates; `Retry-After-Ms`
  accepts numeric milliseconds. Valid milliseconds take precedence regardless of
  header order. Invalid values fall back to another valid header or normal backoff.
  Backoff is seeded and reproducible;
  configure distinct seeds across workers to avoid synchronized retries.
- HTTP uses the standard library allocator and a fresh connection per attempt.
  The codec uses fixed caller memory; the whole SDK is **not allocation-free**.

## Status

Local Debug and ReleaseSafe checks, compile-failure schema tests, deterministic
retry tests, malformed-response tests, and loopback HTTP boundary/deadline tests
cover this first slice. A live three-question batch succeeded against `jev-1.13.0`.
Live success does not establish production readiness or predictive accuracy.

Next work: broader compatibility fixtures,
broader TLS coverage, longer load/cancellation tests, and measured connection
reuse. Dynamic schemas and model discovery are not implemented.

Structured inputs use `noulWithCriteria(instructions, criteria)`,
`choiceStructured(Enum, instructions, descriptions)`, and
`scoreStructured(instructions, levels)`. Use Zig structs for objects and arrays
or tuples for arrays. `noulWithCriteria(instructions, null)` omits criteria.
For Choice, supply every enum option, using null where no description is needed.

```zig
const questions = .{
    .urgent = jevlin.noulWithCriteria(
        .{ .question = "Urgent?", .context = "Customer support" },
        .{ .@"true" = "Immediate attention", .@"false" = "Routine" },
    ),
    .severity = jevlin.scoreStructured("Severity?", .{
        .{ .label = "Minor", .example = "Cosmetic issue" },
        .{ .label = "Major", .example = "Cannot log in" },
    }),
};
```

`result.usage` is optional typed token usage with `input_tokens` and
`output_tokens`. Absence remains accepted for compatibility; malformed present
usage returns InvalidResponse. Counters must be nonnegative JSON integers
representable by the parser's signed 64-bit integer type.

After a failed evaluation, `diagnostics` retains status, attempts, raw
`error_body`, and best-effort parsed `error_json` for the last complete HTTP error
response. Non-JSON or insufficient parse workspace does not replace the original
error. A later transport failure clears stale response details. These fields
borrow the workspace until reuse; copy anything needed longer. The JSON preserves
vendor fields without assuming a stable error schema. It may contain sensitive
upstream data, so callers control logging.

The [manual soak workflow](.github/workflows/soak.yml) offers 5-minute through
3-hour runs and downloadable logs/reports. The repository is [copyleftdev/jevlin](https://github.com/copyleftdev/jevlin).
Start a soak from Actions → Jevlin manual soak → Run workflow.

See [engineering notes](docs/engineering.md) for the safety adaptation and limits.
See the [API contract matrix](docs/contract.md) for supported fields, explicit
compatibility gaps, fixture provenance, and validation policies.
See [memory and fuzz testing](docs/memory-testing.md) for the bounded campaigns,
allocation-failure coverage, and the bounded coverage-guided campaigns.
See [transport lifecycle testing](docs/transport-testing.md) for disconnects,
deadline races, cancellation, concurrent adapters, and cleanup evidence.
See [TLS and soak testing](docs/tls-soak-testing.md) for the optional persistent
process campaign and resource-monitoring gates.

See [retry-header behavior](docs/retry-after.md) for date formats, clock handling,
rounding, and delay bounds.

See [certificate validation tests](docs/tls-certificates.md) for trusted HTTPS,
certificate rejection, and TLS allocation-failure recovery.
