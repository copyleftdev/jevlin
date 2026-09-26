//! Consumer-side compatibility sentinel: change only after an explicit API review.
const std = @import("std");
const j = @import("jevlin");
const Team = enum { billing, support };
const Questions = @TypeOf(.{
    .urgent = j.noul("Urgent?"),
    .team = j.choice(Team, "Route?", .{}),
    .risk = j.score("Risk?", [2][]const u8{ "Low", "High" }),
});
const ExpectedError = error{
    OutOfMemory,
    Busy,
    InvalidConfig,
    DeadlineExceeded,
    Canceled,
    TransportFailure,
    TlsFailure,
    ConcurrencyUnavailable,
    ResponseTooLarge,
    Unauthorized,
    RateLimited,
    BadRequest,
    ServerError,
    UnexpectedStatus,
    InvalidResponse,
    InvalidRequest,
    RequestTooLarge,
    WorkspaceTooSmall,
};
fn field(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (@FieldType(T, name) != Expected) @compileError("Public field type changed: " ++ name);
}
comptime {
    if (j.Error != ExpectedError) @compileError("Public error set changed; review exhaustive consumer switches");
    if (j.Config != j.engine.Config or j.Diagnostics != j.engine.Diagnostics or
        j.Transport != j.engine.Transport or j.TransportError != j.engine.Error or j.Reply != j.engine.Reply)
        @compileError("Legacy engine aliases must remain compatible");
    const init: *const fn (j.Transport, j.Config) j.Error!j.Client = &j.Client.init;
    const http_init: *const fn (std.mem.Allocator, std.Io, []const u8) j.TransportError!j.Http = &j.Http.init;
    const http_deinit: *const fn (*j.Http) void = &j.Http.deinit;
    const transport: *const fn (*j.Http) j.Transport = &j.Http.transport;
    _ = .{ init, http_init, http_deinit, transport };
    field(j.Config, "timeout_ms", u32);
    field(j.Config, "max_retries", u8);
    field(j.Config, "backoff_ms", u32);
    field(j.Config, "seed", u64);
    for (.{ "request", "response", "scratch" }) |name| field(j.Workspace, name, []u8);
    field(j.Diagnostics, "status", ?u16);
    field(j.Diagnostics, "attempts", u8);
    field(j.Diagnostics, "error_body", []const u8);
    field(j.Diagnostics, "error_json", ?std.json.Value);
    field(j.Usage, "input_tokens", u64);
    field(j.Usage, "output_tokens", u64);
    field(j.Reply, "status", u16);
    field(j.Reply, "len", usize);
    field(j.Reply, "retry_after_ns", ?u64);
    field(j.Transport, "context", *anyopaque);
    field(j.Transport, "now", *const fn (*anyopaque) i96);
    field(j.Transport, "sleep", *const fn (*anyopaque, u64) j.TransportError!void);
    field(j.Transport, "exchange", *const fn (*anyopaque, []const u8, []u8, i96) j.TransportError!j.Reply);
    const R = j.Result(Questions);
    field(R, "answers", j.Answers(Questions));
    field(R, "model", []const u8);
    field(R, "raw", []const u8);
    field(R, "usage", ?j.Usage);
    field(R, "attempts", u8);
    field(@FieldType(j.Answers(Questions), "urgent"), "probability", f64);
    field(j.Choice(Team).Answer, "choice", Team);
    field(j.Choice(Team).Answer, "confidence", f64);
    field(@FieldType(j.Choice(Team).Answer, "probabilities"), "billing", f64);
    field(@FieldType(j.Choice(Team).Answer, "probabilities"), "support", f64);
    field(j.Score(2).Answer, "score", f64);
    field(j.Score(2).Answer, "confidence", f64);
    field(j.Score(2).Answer, "probabilities", [2]f64);
    field(j.Score(2).Answer, "legend", [2]std.json.Value);
}
pub fn main() !void {
    const config: j.Config = .{};
    try std.testing.expectEqual(@as(u32, 10_000), config.timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), config.max_retries);
    try std.testing.expectEqual(@as(u32, 100), config.backoff_ms);
    try std.testing.expectEqual(@as(u64, 1), config.seed);
    try config.validate();
    const diagnostics: j.Diagnostics = .{};
    try std.testing.expect(diagnostics.status == null and diagnostics.error_json == null);
    try std.testing.expect(diagnostics.attempts == 0 and diagnostics.error_body.len == 0);
    const reply: j.Reply = .{ .status = 200, .len = 0 };
    try std.testing.expect(reply.retry_after_ns == null);
}
