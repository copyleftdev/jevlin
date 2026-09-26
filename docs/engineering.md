# Engineering notes

Jevlin takes inspiration from [TigerStyle](https://tigerstyle.dev/) and uses a
**Power-of-Ten-inspired adaptation for Zig**. This is neither literal NASA/JPL
compliance nor a claim of TigerBeetle-level assurance.

## Explicit bounds

| Resource | Bound |
| --- | --- |
| Questions | 1–128 per batch, local SDK policy |
| Choice options | 1–255 |
| Score levels | 2–10 |
| JSON nesting accepted by parser | 32 |
| Request, response, parse storage | Caller capacities |
| API key | 1–1017 printable ASCII bytes |
| Timeout | 1–300,000 milliseconds |
| Retries | 0–8; attempts are retries plus one |
| Exponential backoff | Capped at 5,000 milliseconds |
| Concurrent calls per client | One; others return Busy |

Request encoding and response parsing use a fixed-buffer allocator. Parsing
pre-scans token depth before constructing the standard library JSON tree.
Duplicate keys, truncated JSON, missing required answers, wrong primitive types,
non-finite/out-of-range probabilities, and inconsistent scores are rejected.
Unknown additional fields are tolerated for forward compatibility.
Probability sums allow an absolute 0.02 rounding tolerance; score consistency
allows 0.02 times the level count. These are local validation policies, not
documented upstream guarantees.

## Fault testing

The transport injects clock, sleep, and exchange operations, allowing repeatable
tests without wall-clock waiting or credentials. Retry tests exercise 1,000 seeds.
Loopback tests exercise exact-size bodies, declared overflow, chunked overflow,
truncation, and real cancellation of a delayed HTTP response. Compile-failure
tests verify the intended diagnostic for invalid schemas, rather than accepting
any compiler error as success. Live tests remain opt-in and separate from CI.

The deadline starts before serialization and is checked after decoding. A custom
transport must honor the supplied deadline; Jevlin cannot preempt arbitrary
user-provided callbacks. The production transport races HTTP against a timer and
joins canceled tasks before releasing buffer ownership. OS scheduling and cleanup
can extend elapsed time beyond the configured deadline.

## Deliberate deviations and remaining evidence

- Zig generics and compile-time reflection generate typed schemas. They replace
  handwritten duplication; this is an adaptation of the original C rules.
- Function pointers form the transport boundary for deterministic fault injection.
- Standard JSON internals can recurse; the parser bounds input nesting first.
  Serialization accepts trusted Zig values and can recurse before its output is
  validated. No universal stack bound is claimed for arbitrary user serializers.
- Standard HTTP/TLS allocates dynamically and may use threads. Only codec storage
  has a caller-controlled fixed capacity. Fresh clients avoid connection lifetime
  complexity but add latency and TLS setup cost.
- Runtime input checks return errors instead of assertions. Assertions are not
  substitutes for validating server data. Assertion density and full static
  analysis have not been audited against the original Power of Ten rules.
- Linux is the validated platform for this cut. Bounded mutation campaigns and
  loopback HTTP allocation-failure injection are covered in [memory testing](memory-testing.md).
  Cross-platform behavior, load, TLS allocation failures, coverage-guided fuzzing,
  and long-duration cancellation stress remain work before a production-readiness claim.
  Short [transport lifecycle stress tests](transport-testing.md) cover real loopback
  disconnects, stalls, cancellation, concurrent adapters, and retry recovery.

The HTTP adapter fixes the official HTTPS endpoint and does not follow redirects.
It stores an authorization copy, wipes that copy on deinit, and does not log
credentials. The caller remains responsible for its original key and environment.
Diagnostics expose status, attempt count, a borrowed raw HTTP error body, and
best-effort parsed JSON. Error parsing failures preserve the original status error.

## Protocol references

- [TypeSafe API](https://docs.typesafe.ai/api)
- [Score primitive](https://docs.typesafe.ai/primitives/score)
- [Python SDK retry documentation](https://docs.typesafe.ai/sdk/python/api/retries)

The initial live verification used the official endpoint and `jev-latest`, which
returned `jev-1.13.0`. Text helpers and structured question helpers are now both implemented.
