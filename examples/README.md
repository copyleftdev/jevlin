# Examples

Run the offline examples and API compatibility sentinel:

```sh
zig build examples
zig build examples -Doptimize=ReleaseSafe
```

`zig build check` also runs them. Native Linux, macOS, and Windows CI execute
them in both modes. They require no key or network and issue no billable calls.

| File | What it demonstrates |
| --- | --- |
| [structured.zig](structured.zig) | Object state, structured questions, typed results, optional usage, copying borrowed data before workspace reuse |
| [errors_and_buffers.zig](errors_and_buffers.zig) | Request/scratch exhaustion, safe request resizing, API diagnostics, successful recovery |
| [parallel.zig](parallel.zig) | Twelve tickets across at most four workers, independent client/workspace ownership, cleanup on partial startup or failure |
| [api_contract.zig](api_contract.zig) | Consumer expectations for signatures, field types, error set, defaults, and legacy aliases |
| [triage.zig](triage.zig) | Real HTTP adapter and allocator cleanup; compile-only during normal checks |

The offline examples share [fixture.zig](fixture.zig), which supplies synthetic
answers. Its 4 KiB request/response and 64 KiB scratch buffers are teaching
capacities, not recommended limits for every workload. Set explicit budgets for
your application's largest supported batch and structured fields. Test them
against representative responses. Parsing scratch can be larger than response
bytes; there is no guaranteed multiplier.

To adapt an offline example to real calls, create `Http` with an allocator, I/O
context, and key, pass `http.transport()` into the client, and defer `http.deinit()`
until all work has finished. In a worker group, initialize an adapter inside each
worker so its address and lifetime stay valid. Preserve the ownership and cleanup
pattern and replace the fixture-specific assertions with application behavior.

`TYPESAFE_API_KEY=... zig build live` runs the HTTP triage example and is billable.
Set the key through your environment/secret manager; avoid putting real keys in
shell history. The SDK does not read credential files. Retries can incur extra
charges. See the [API contract](../docs/api-stability.md) before automatically
replaying a failed request.
