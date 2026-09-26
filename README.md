# Jevlin

[![Tip my tokens](https://tokentip.to/badge/copyleftdev.svg?logo=1)](https://tokentip.to/@copyleftdev)

A typed Zig SDK for TypeSafe AI's Jev. Ask yes/no, classification, and scoring
questions in one request. Get probabilities and Zig enums back.

**Zig 0.16.0 · Experimental · Independent of TypeSafe AI**

```zig
const Team = enum { billing, technical, sales };
const questions = .{
    .urgent = jevlin.noul("Does this need urgent attention?"),
    .team = jevlin.choice(Team, "Which team should handle this?", .{}),
    .severity = jevlin.score("How severe?", [3][]const u8{
        "Minor", "Workaround available", "Cannot use the service",
    }),
};
const result = try client.evaluate(
    .{ .ticket = "I was charged twice." }, questions, "jev-latest",
    workspace, &diagnostics,
);
// result.answers.team.choice is a Team.
```

The [complete example](examples/triage.zig) shows client setup, buffers, and cleanup.
[Offline examples](examples/README.md) cover structured questions, error handling,
and bounded parallel use.

## Use it

For a local checkout, add this to your `build.zig.zon` dependencies:

```zig
.jevlin = .{ .path = "../jevlin" },
```

In `build.zig`, add the dependency to your application module:

```zig
const jevlin = b.dependency("jevlin", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jevlin", jevlin.module("jevlin"));
```

You own the request, response, and scratch buffers. Results borrow that memory;
copy borrowed data before reusing it. Give each concurrent worker its own client
and workspace. HTTP/TLS uses the allocator you supply.

## Run the checks

```sh
zig build check
zig build check -Doptimize=ReleaseSafe
zig build examples
```

Checks run locally without API credentials. Transport tests use loopback sockets.
Native CI covers Linux, macOS, and Windows in both modes, including TLS rejection
and allocation recovery. Separate manual workflows run
[coverage-guided fuzzing](.github/workflows/fuzz.yml) and
[soak tests](.github/workflows/soak.yml).

With `TYPESAFE_API_KEY` set, `zig build live` sends a real request. It is billable,
and retries can incur additional charges. The SDK does not read credential files.

## Details

- [API contract](docs/api-stability.md): ownership, configuration, errors, and compatibility.
- [Jev API coverage](docs/contract.md): supported fields and known limits.
- [Testing](docs/memory-testing.md): mutation tests, fuzz campaigns, and crash replay.
- [TLS checks](docs/tls-certificates.md) and [platform compatibility](docs/compatibility.md).
- [Changelog](CHANGELOG.md) and [release preparation](docs/releases.md).

Still pre-release. Dynamic schemas, model discovery, and connection pooling are
not implemented. Licensed under [MIT](LICENSE).
