# TLS failures and sustained transport testing

## Recorded run

On 2026-09-26, the ReleaseSafe Linux campaign requested 120 seconds and completed
in 121.649 seconds (excluding compilation). Both opt-in tests passed. The soak
completed 107 rounds / 8,988 exchanges, excluding warm-up. Quiescent descriptors
remained at four. Across 243 samples, middle/final RSS medians were both 5,092 KiB;
peak RSS was 21,492 KiB. Middle/final thread medians and peak were seven.
Both resource gates passed. See [raw report](soak-report.json).

The normal suite passed in Debug and ReleaseSafe: 27 passed, with the two opt-in
tests skipped there and executed separately above. This is a two-minute baseline,
not multi-hour production-readiness evidence.

## Coverage and reproduction

### Manual GitHub workflow

`.github/workflows/soak.yml` uses only `workflow_dispatch`, with durations of
300, 1,800, 3,600, or 10,800 seconds (default one hour). It requires no API secrets,
runs on Ubuntu 24.04 with Zig 0.16.0, and uploads the JSON report and console log
with 30-day retention, including on test failure. A job summary reports the gates.
Runs on the same branch queue rather than canceling a previous soak.

The workflow lives in [copyleftdev/jevlin](https://github.com/copyleftdev/jevlin).
GitHub requires the workflow on the default branch before manual dispatch is available; see
[GitHub workflow_dispatch documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).
Local YAML/trigger/permission and shell syntax checks passed. GitHub execution
has not been verified yet.

The normal Debug/ReleaseSafe suite now checks a TLS peer disconnecting during
ClientHello, sending plaintext instead of TLS, and stalling the handshake.
Stalls must return DeadlineExceeded; interruption/malformed records must return
TlsFailure or TransportFailure. Each failure is followed by a healthy loopback
HTTP request using the same adapter. No certificate verification is disabled.

Two additional tests are opt-in and appear as skipped in the normal suite.
The Linux runner enables them together:

```sh
python3 scripts/soak.py --zig /path/to/zig --seconds 300 --report soak-report.json
```

Requirements: Zig 0.16.0, Python 3, OpenSSL CLI, Linux `/proc`, and permission to
open loopback sockets. The script generates a temporary self-signed certificate
with a matching loopback IP SAN. The SDK must reject it with TlsFailure using
normal system trust. Recovery is checked against plain HTTP; a successful
trusted TLS control is not included. Temporary private keys are deleted with
the test directory and are never committed.

The soak repeatedly executes the existing 84-exchange lifecycle worker in one
process, including faults, cancellation, races, and successful recovery. It
asserts unchanged quiescent descriptor count after each worker round and tracks
adapter allocations. The runner samples RSS, thread count, and descriptors every
0.5 seconds. It compares last-quarter medians with second-quarter medians, allowing
16 MiB RSS growth and four additional threads. These are coarse regression gates,
not proof of leak freedom. Active-request descriptor samples may fluctuate;
quiescent equality is asserted inside the Zig test.

The JSON report contains the exit status, gate results, test output, and all
samples. Child execution is bounded by requested duration plus 60 seconds for
warm-up/cleanup; compile time is outside that budget. Duration can be 30–86,400
seconds. Start with a short run before an hours-long campaign.

Still outstanding: trusted local CA controls for hostname/expiry failures,
TLS-specific allocation failure injection, successful TLS recovery, DNS faults,
multi-hour soak evidence, and other platforms. The soak repeats sequential
workers; the separate normal suite covers four concurrent adapters.
