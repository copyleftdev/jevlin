# Changelog

## Unreleased — 0.1.0-dev

- Native TLS certificate and allocation-recovery checks on Linux, macOS, and
  Windows; Windows system-root loading releases certificate contexts on OOM
  instead of triggering Zig 0.16.0's store-close assertion.

- Typed Noul, Choice, and Score batches, structured instructions/criteria, and
  optional token usage for the Jev systemone endpoint.
- Caller-owned bounded buffers, explicit borrowed result lifetimes, typed errors,
  and HTTP diagnostics with best-effort JSON details.
- Configurable deadlines and bounded retries, including numeric and HTTP-date
  Retry-After handling; TLS validation and cancellation cleanup.
- Top-level configuration/transport aliases preserving existing engine paths;
  documented public API contract and offline examples.
- Contract fixtures, deterministic mutation campaigns, allocation-failure tests,
  transport fault recovery, Linux TLS fixtures, and manually triggered soak runs.
- Native Linux, macOS, and Windows Debug/ReleaseSafe CI and independent packaged
  consumers with API compatibility checks.
- Private source-archive rehearsal with SHA-256 checksums and reproducibility
  checks. No public release or license has been selected yet.

Coverage-guided parser and encoder campaigns now run with LLVM and a scoped
error-return-tracing workaround on unmodified Zig 0.16.0. Reports, crash capture,
and replay are available through a manual workflow. Platform TLS coverage and
soak evidence retain their documented limits.
