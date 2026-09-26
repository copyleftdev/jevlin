//! Offline teaching fixture, not an HTTP transport. Each worker owns one instance.
const j = @import("jevlin");
pub const Fixture = struct {
    status: u16 = 200,
    calls: usize = 0,
    const body =
        \\{"model":"offline","usage":{"input_tokens":12,"output_tokens":3},"answers":{"urgent":{"type":"noul","noul":0.8},"team":{"type":"choice","choice":"billing","confidence":0.5,"probabilities":{"billing":0.8,"support":0.2}},"risk":{"type":"score","score":0.25,"confidence":0.5,"probabilities":{"0":0.75,"1":0.25},"legend":{"0":"Low","1":"High"}}}}
    ;
    pub fn transport(self: *@This()) j.Transport {
        return .{ .context = self, .now = now, .sleep = sleep, .exchange = exchange };
    }
    fn now(_: *anyopaque) i96 {
        return 0;
    }
    fn sleep(_: *anyopaque, _: u64) j.TransportError!void {}
    fn exchange(context: *anyopaque, _: []const u8, out: []u8, _: i96) j.TransportError!j.Reply {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        const bytes = if (self.status == 200) body else "{\"detail\":\"invalid question\"}";
        if (bytes.len > out.len) return error.ResponseTooLarge;
        @memcpy(out[0..bytes.len], bytes);
        return .{ .status = self.status, .len = bytes.len };
    }
};
pub const Team = enum { billing, support };
pub const questions = .{
    .urgent = j.noulWithCriteria(.{ .question = "Urgent?", .context = "Customer support" }, .{ .true = "Needs action now", .false = "Can wait" }),
    .team = j.choiceStructured(Team, "Route?", .{ .billing = .{ .meaning = "Payments" }, .support = null }),
    .risk = j.scoreStructured("Risk?", .{ "Low", "High" }),
};
// Example capacities, not universal sizing guarantees.
pub const Buffers = struct {
    request: [4096]u8 = undefined,
    response: [4096]u8 = undefined,
    scratch: [65536]u8 = undefined,
    pub fn workspace(self: *@This()) j.Workspace {
        return .{ .request = &self.request, .response = &self.response, .scratch = &self.scratch };
    }
};
