# Package and platform checks

Jevlin targets Zig 0.16.0. CI runs Debug and ReleaseSafe on Ubuntu 24.04,
macOS 14, and Windows Server 2022 using native GitHub runners. Runner labels
follow the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Adding a target to CI is not evidence of passing: check the six jobs for the
specific commit before relying on it.

Each job checks formatting, offline contract and transport fault tests, example
compilation, invalid-schema compilation failures, and a separate application
using the packaged SDK. All three platforms additionally verify valid, expired, future,
wrong-host, and untrusted TLS certificates and allocation-failure recovery.
The resource soak remains Linux-only; its measurements do not establish
equivalent resource behavior on Windows or macOS. TLS results cover the runner
OS and root-store snapshot, not every OS version or trust configuration.

## Independent consumer

```sh
python3 scripts/consumer.py --optimize=Debug
python3 scripts/consumer.py --optimize=ReleaseSafe
```

The script archives tracked working files, fetches that archive with Zig into a
fresh cache, and initializes an application outside the checkout. Its dependency
uses the package hash; the archive is removed before the application builds.
This catches missing packaged files and mistakes in the exported build module.
The report records the package hash, platform, architecture, build mode, and result.

The application exercises structured state/questions, all three typed answer
families, usage, API errors, diagnostics, and recovery. It initializes the real
HTTP adapter but uses an injected transport for responses, so no credentials,
external network, or billable API requests are needed. Public registry delivery,
release archive URLs, and live service behavior are separate release checks.

Cross-compilation of the example is useful additional evidence, but cannot
replace native tests. The repository remains private until release is approved.
