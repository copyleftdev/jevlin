const std = @import("std");
const codec = @import("codec.zig");
const schema = @import("schema.zig");
pub const engine = @import("engine.zig");
/// Preferred public names. The engine aliases remain source-compatible.
pub const Config = engine.Config;
pub const Diagnostics = engine.Diagnostics;
pub const Transport = engine.Transport;
pub const TransportError = engine.Error;
pub const Reply = engine.Reply;
pub const Http = @import("http.zig");
pub const noul = schema.noul;
pub const choice = schema.choice;
pub const score = schema.score;
pub const Choice = schema.Choice;
pub const Score = schema.Score;
pub const Answers = schema.Answers;
pub const noulWithCriteria = schema.noulWithCriteria;
pub const choiceStructured = schema.choiceStructured;
pub const scoreStructured = schema.scoreStructured;
pub const Usage = codec.Usage;
pub const Error = engine.Error || codec.Error;
/// Caller-owned, nonempty, disjoint buffers. Do not share across in-flight calls.
pub const Workspace = struct { request: []u8, response: []u8, scratch: []u8 };
pub fn Result(comptime Q: type) type {
    return struct { answers: Answers(Q), model: []const u8, raw: []const u8, usage: ?Usage, attempts: u8 };
}
/// One in-flight call per client; concurrent callers receive Busy. Use separate
/// clients/workspaces for a fixed-size worker pool. Never copy an active client.
pub const Client = struct {
    transport: engine.Transport,
    config: engine.Config,
    busy: std.atomic.Value(bool) = .init(false),
    pub fn init(transport: engine.Transport, config: engine.Config) Error!Client {
        try config.validate();
        return .{ .transport = transport, .config = config };
    }
    /// Returned model/legend/raw and diagnostic JSON borrow workspace until reuse,
    /// including a later failed call. Copy borrowed data before the next call.
    /// Busy returns without modifying diagnostics or workspace.
    /// State must be JSON-serializable; structured question helpers accept JSON-serializable values.
    pub fn evaluate(self: *Client, state: anytype, questions: anytype, model: []const u8, workspace: Workspace, diagnostics: *engine.Diagnostics) Error!Result(@TypeOf(questions)) {
        if (self.busy.swap(true, .acquire)) return error.Busy;
        defer self.busy.store(false, .release);
        diagnostics.* = .{};
        try self.config.validate();
        try validateWorkspace(workspace);
        const end = engine.deadline(self.transport, self.config);
        const body = try codec.encode(state, questions, model, workspace.request, workspace.scratch);
        const reply = engine.send(self.transport, self.config, end, body, workspace.response, diagnostics) catch |err| {
            if (diagnostics.error_body.len != 0)
                diagnostics.error_json = codec.parse(diagnostics.error_body, workspace.scratch) catch null;
            return err;
        };
        const raw = workspace.response[0..reply.len];
        const tree = try codec.parse(raw, workspace.scratch);
        const answers = try codec.decode(@TypeOf(questions), tree);
        const name = try codec.string(try codec.get(try codec.object(tree), "model"));
        const usage = try codec.decodeUsage(tree);
        try engine.checkDeadline(self.transport, end);
        return .{ .answers = answers, .model = name, .raw = raw, .usage = usage, .attempts = diagnostics.attempts };
    }
};
test {
    _ = Http;
    _ = @import("tests.zig");
    _ = @import("fuzz.zig");
}

fn overlaps(a: []u8, b: []u8) bool {
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return if (x <= y) y - x < a.len else x - y < b.len;
}
fn validateWorkspace(w: Workspace) Error!void {
    if (w.request.len == 0 or w.response.len == 0 or w.scratch.len == 0) return error.WorkspaceTooSmall;
    if (overlaps(w.request, w.response) or overlaps(w.request, w.scratch) or overlaps(w.response, w.scratch)) return error.InvalidConfig;
}
