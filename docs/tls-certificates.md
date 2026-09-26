# Certificate validation and TLS allocation recovery

Run the isolated fixture suite with:

```sh
python3 scripts/tls.py --zig /path/to/zig --optimize Debug --report tls-report.json
python3 scripts/tls.py --zig /path/to/zig --optimize ReleaseSafe --report tls-report.json
```

Python's standard library and the OpenSSL 3 CLI generate a temporary CA and five
localhost HTTPS servers. No package install, API key, public endpoint, or system
trust-store modification is needed. Keys and certificates live in a temporary
directory that is removed afterward.

Use `--openssl /path/to/openssl` to select OpenSSL 3 explicitly. On macOS CI,
Homebrew's `openssl@3` is selected instead of the system LibreSSL. Windows uses
an `.exe` test binary. Reports record the OS/architecture, OpenSSL fixture-tool
version, and Python TLS version; the SDK itself uses Zig's TLS implementation.

## Recorded verification

On 2026-09-26 both certificate tests passed in Debug and ReleaseSafe, with three
trusted-path and eight system-root-path allocation points exercised. No invalid
certificate server received an HTTP request. The full ReleaseSafe suite passed
36 tests with four fixture/soak tests skipped; the dedicated runners exercised
those separately. A 30-second regression soak passed with 2,268 exchanges and
four quiescent descriptors. Reports: [Debug](tls-debug-report.json),
[ReleaseSafe](tls-release-report.json).

## What is checked

| Fixture | Expected result |
| --- | --- |
| Valid local-CA certificate, localhost SAN | HTTP 200 and exact response body |
| Expired leaf, correct hostname and issuer | TlsFailure; no HTTP request sent |
| Wrong hostname, valid dates and trusted issuer | TlsFailure; no HTTP request sent |
| Not-yet-valid leaf, correct hostname and issuer | TlsFailure; no HTTP request sent |
| Self-signed certificate with matching hostname | TlsFailure; no HTTP request sent |

OpenSSL independently checks each fixture, including the intended rejection
reason. Zig's standard HTTP client collapses verifier errors such as
CertificateExpired into TlsInitializationFailed; Jevlin exposes TlsFailure.
The suite therefore does not claim that the public SDK distinguishes the precise
certificate cause. Every rejection is followed by a successful HTTPS request
using the same adapter and the valid local certificate.

The runner fails if an invalid-certificate server receives an HTTP request. It
records fixture verification, request/rejection counts, test output, and server
errors in a JSON report. Child test execution has a 120-second timeout.

## Allocation failure coverage

The test allocator sweeps each allocation index from two successful test paths:

1. Load the test CA, complete a trusted TLS handshake, and read an HTTP response.
2. Load system roots and reject the isolated CA, then recover with the test CA.

On the development Linux system these paths had three and eight allocation
points respectively. Counts depend on platform/root-store contents and are not
hard-coded. Every induced allocation failure must return OutOfMemory and balance
allocated/freed byte counts. After memory is restored, the same adapter must
complete a trusted HTTPS request. Resize-failure injection and allocations
internal to the I/O runtime remain outside this sweep.

Root loading now happens explicitly before the standard HTTP request so its
allocation errors are preserved. Previously std.http converted root-bundle
loading errors to CertificateBundleLoadFailure, losing the OutOfMemory cause.
The production adapter still uses system trust and the official endpoint.

The custom CA path exists only in test builds. In ordinary builds the hook is a
zero-storage void field and its branch is eliminated. Test environment variables
are consumed only by test functions; production does not read them.

## CI and previous evidence

Regular GitHub CI runs the certificate suite on Linux, macOS, and Windows in Debug and ReleaseSafe
and uploads its JSON reports. The manual soak workflow also runs it and uploads
its report and log alongside soak artifacts. Normal `zig build check` skips these
two fixture-dependent tests when the runner has not provided the fixture.

The older soak used an IP-only SAN. Zig 0.16.0's hostname verifier handles DNS SANs,
so that earlier generic TLS rejection could have been a hostname mismatch rather
than an untrusted issuer. The soak now uses matching localhost DNS names, and
this suite verifies a trusted positive control and each negative fixture. The
historical soak report remains historical evidence, not proof of its exact
certificate rejection cause.

## Windows allocation cleanup

Native Windows testing found that Zig 0.16.0's system-root loader retained its
current certificate context on an allocation-error return. Closing the store
then hit an assertion instead of returning OutOfMemory. Jevlin's small Windows
loader in `src/system_roots.zig` frees the outstanding context before closing the
store on every early exit and checks enumeration termination. Other platforms
continue to use the standard loader. No trust store or verification policy is
relaxed, and the system-root allocation sweep remains enabled.

This follows [Microsoft's certificate enumeration ownership contract](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certenumcertificatesinstore):
advancing enumeration releases the previous context; an early exit requires an
explicit context release. The store-close check also detects outstanding native
certificate contexts, which Zig allocator accounting alone would not detect.

Remaining scope includes certificate chains with intermediates, revocation
policy, additional OS versions, runtime allocator failures, concurrent TLS
stress, and multi-hour soak evidence. These tests do not establish comprehensive
TLS protocol conformance.
