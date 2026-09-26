# API contract and compatibility

Reviewed 2026-09-25 against the [API reference](https://docs.typesafe.ai/api),
[Score](https://docs.typesafe.ai/primitives/score),
[Choice](https://docs.typesafe.ai/primitives/choice),
[Noul](https://docs.typesafe.ai/primitives/noul), and
[Python retry reference](https://docs.typesafe.ai/sdk/python/api/retries).
This is a compatibility baseline, not a claim of complete API support.

## Supported surface

| Area | Jevlin behavior | Evidence |
| --- | --- | --- |
| Evaluation | POST to official HTTPS endpoint with Bearer authentication and JSON | HTTP adapter; prior live smoke |
| Request envelope | model, state, questions; string/object/array state | Exact request fixture and state-variant test |
| Noul | Text/structured instruction and optional true/false criteria; probability in [0,1] | Response corpus |
| Choice | Enum options, string/object/array/null descriptions, complete distribution and confidence | Request fixture; response corpus; compile checks |
| Score | Ordered text/structured levels, weighted score, distribution, legend, confidence | Request fixture; response corpus; compile checks |
| Response envelope | Requires model string and requested answers | Missing-field and wrong-type fixtures |
| HTTP errors | 401/403 Unauthorized; 400/422 BadRequest; 429 RateLimited; 5xx ServerError | Status table test |
| Retry | Transport failures, 408, 429, 5xx; bounded total budget | Status test, deterministic retry tests |

The documented Choice maximum is 255; Score supports 2–10 levels. The API
documents 401, 422, 429, and 529. The existing adapter additionally handles
400, 403, and other statuses; 400 validation responses were observed during the
earlier upstream SDK review. Retry configuration is Jevlin's own policy, not
Python SDK parity.

## Explicit gaps and compatibility choices

| Area | Current limitation or local policy |
| --- | --- |
| Noul criteria | Supported by noulWithCriteria; pass null to omit |
| Structured questions | Supported by structured helpers; validated after bounded JSON encoding |
| Usage | Optional typed counters; present usage must contain nonnegative integer input/output counts. Missing usage remains accepted for compatibility |
| Error bodies | Status/attempts plus borrowed raw body and best-effort parsed JSON; no assumed vendor-specific error envelope |
| Retry headers | Numeric seconds/milliseconds and all three HTTP-date forms; valid milliseconds take precedence, malformed values are ignored |
| Extra fields | Unknown root/answer fields and extra answer IDs are ignored |
| Probability rounding | Sum tolerance 0.02; selected Choice may trail maximum by up to 0.02 |
| Score rounding | Weighted-value tolerance 0.02 times level count; range remains strict |
| Legend | Accepts string/object/array values; API reference lists strings. Structured acceptance is a local extension, not evidence of upstream output. Does not compare legend text with request criteria |
| Confidence | Checks numeric range, not the upstream confidence formula |
| Local request limits | 128 questions; nonempty model/instructions/Score text; 32 parsed nesting levels; caller buffer capacities |
| Input trust | Arbitrary custom Zig serializers are caller code; no universal serializer stack bound |
| Models | Caller supplies the model string; no model discovery or allowlist |

These permissive cases are intentionally named in fixtures. Passing the suite
does not mean strict rejection of every deviation from the reference has been
implemented. Missing usage and extra fields remain permissive choices. Tightening these policies
requires an explicit compatibility decision and updated fixtures.

## Fixture provenance and execution

`src/fixtures/request.json` and `responses.json` contain synthetic, independently
authored protocol examples, not recordings or verbatim vendor examples. They
contain no credentials or customer data. The response corpus has 66 named cases:
valid batches, required-field omissions, incorrect types, bounds, rounding,
unknown fields, malformed syntax, and explicitly permissive behavior.

The response runner uses the public Client with an injected transport, including
envelope validation and the normal codec. Negative cases require InvalidResponse
and exactly one attempt. Request tests compare a fixed wire fixture and exercise
all state categories. Nine status cases assert exact error and attempt count.
Existing loopback tests cover transport body handling separately.

Run `zig build check` and `zig build check -Doptimize=ReleaseSafe`; both execute
the corpus through the normal CI test target. This is an offline contract suite,
not a server conformance test. No new live requests were needed for this change.

When documentation changes: record the review date/source, classify each change
as upstream requirement or local policy, add a named fixture, and resolve affected
gaps before claiming support. Keep regressions even when their original bug is fixed.
