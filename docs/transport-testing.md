# Transport lifecycle testing

The loopback suite exercises the production HTTP adapter with a private test-only
endpoint. No credentials or external API requests are used. It runs automatically
under `zig build check` in Debug and ReleaseSafe.

## Scenarios

- Peer closes after request headers while a 16 MiB upload is in progress.
- Peer closes partway through response headers or a declared response body.
- Peer stalls before headers or after a partial body; the deadline cancels I/O.
- A response arrives near a 5 ms deadline; either completion or DeadlineExceeded
  is valid. This is a scheduling race test, not a deterministic ordering assertion.
- Caller explicitly cancels after the peer has accepted and parsed the request.
- Every fault/race is followed by a healthy request on the same adapter.
- Real HTTP 503 responses exercise three-attempt exhaustion and recovery on the
  third attempt, including numeric server-directed retry delays.

One worker runs six rounds of seven fault/race/cancellation cases, each followed
by recovery: 84 exchanges. Tests run one worker sequentially and four independent
workers concurrently, totaling 420 exchanges, plus warm-up and retry checks.
Each concurrent worker has its own adapter, allocator accounting, and buffers.
These are adapter-level concurrency tests; they do not simulate simultaneous
calls sharing a single public Client.

## Cleanup evidence

After each exchange returns, the test overwrites response storage and checks it
again after 8 ms while the server may still be alive. This catches delayed writes
within that observation window. Server tasks are canceled/joined and their active
count must return to zero. Production exchange joins its HTTP/timer tasks before
returning; there is no test-only shortcut around that path.

Allocator accounting checks allocated bytes equal freed bytes after faults and
recovery rounds. The test allocator also reports heap leaks. On Linux, the
sequential worker must leave `/proc/self/fd` count unchanged after runtime warm-up.
Failure responses must have the expected classification, and retry checks assert
exactly three attempts. Timing checks allow up to one second of scheduler/cleanup
slack beyond the configured deadline.

## Limits

This is a short stress suite, not an hours-long soak or proof of race freedom.
Descriptor accounting covers the sequential worker; concurrency is checked by
completion, buffer guards, and allocation accounting. There is no process-wide
RSS/thread-count plateau assertion. TCP buffering can affect when upload failure
becomes visible. Deadline races may consistently favor one outcome on a given
machine; the test does not claim exhaustive interleaving coverage.

Basic TLS failures and optional persistent-process resource monitoring are now
covered by [TLS and soak testing](tls-soak-testing.md). DNS failures, multi-hour
soak evidence, broader platform coverage, and longer coverage-guided campaigns
remain outstanding. See [fuzz testing](memory-testing.md) for the working bounded
campaigns. Cancellation is cooperative,
not hard real-time.
