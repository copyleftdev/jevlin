const std = @import("std");
const codec = @import("codec.zig");
const schema = @import("schema.zig");
const t = std.testing;
const Fixture = struct { name: []const u8, response: []const u8, valid: bool };

fn replay(comptime oracle: fn (void, *t.Smith) anyerror!void) !bool {
    const path = t.environ.getAlloc(t.allocator, "JEVLIN_FUZZ_REPLAY") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => return err,
    };
    defer t.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(128 * 1024));
    defer t.allocator.free(bytes);
    var smith: t.Smith = .{ .in = bytes };
    try oracle({}, &smith);
    return true;
}

// Zig 0.16 Smith's serialized input is a u32 slice length, bytes, then a
// u64 weighted capacity value. Keep this helper versioned with the toolchain.
fn seedInput(allocator: std.mem.Allocator, bytes: []const u8, capacity: u64) ![]const u8 {
    const seed = try allocator.alloc(u8, bytes.len + 12);
    std.mem.writeInt(u32, seed[0..4], @intCast(bytes.len), .little);
    @memcpy(seed[4..][0..bytes.len], bytes);
    std.mem.writeInt(u64, seed[4 + bytes.len ..][0..8], capacity, .little);
    return seed;
}
const Questions = @TypeOf(.{
    .urgent = schema.noul("Urgent?"),
    .team = schema.choice(enum { billing, technical }, "Route?", .{}),
    .severity = schema.score("Severity?", [2][]const u8{ "Low", "High" }),
});

// Shared oracle for deterministic mutation tests and coverage-guided fuzzing.
fn probe(bytes: []const u8, capacity: usize) !void {
    var memory: [65538]u8 = @splat(0xa5);
    const tree = codec.parse(bytes, memory[1..][0..capacity]) catch |err| {
        try t.expect(err == error.InvalidResponse or err == error.WorkspaceTooSmall);
        try t.expectEqual(@as(u8, 0xa5), memory[0]);
        try t.expectEqual(@as(u8, 0xa5), memory[capacity + 1]);
        return;
    };
    try t.expectEqual(@as(u8, 0xa5), memory[0]);
    try t.expectEqual(@as(u8, 0xa5), memory[capacity + 1]);
    if (codec.decode(Questions, tree)) |answers| {
        try t.expect(std.math.isFinite(answers.urgent.probability));
        try t.expect(answers.urgent.probability >= 0 and answers.urgent.probability <= 1);
        try t.expect(answers.severity.score >= 0 and answers.severity.score <= 1);
    } else |err| try t.expectEqual(error.InvalidResponse, err);
}
fn fuzzParse(_: void, smith: *t.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len = smith.slice(&bytes);
    const capacity = smith.valueRangeAtMost(u32, 0, 65536);
    try probe(bytes[0..len], capacity);
}
test "fuzz parser and typed decoder" {
    if (try replay(fuzzParse)) return;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const corpus = try std.json.parseFromSlice([]Fixture, allocator, @embedFile("fixtures/responses.json"), .{});
    const seeds = try allocator.alloc([]const u8, corpus.value.len * 2);
    for (corpus.value, 0..) |fixture, i| {
        try t.expect(fixture.response.len <= 4096);
        seeds[i * 2] = try seedInput(allocator, fixture.response, 65536);
        seeds[i * 2 + 1] = try seedInput(allocator, fixture.response, 0);
    }
    try t.fuzz({}, fuzzParse, .{ .corpus = seeds });
}
fn fuzzEncode(_: void, smith: *t.Smith) !void {
    var state: [2048]u8 = undefined;
    const len = smith.slice(&state);
    var output: [8194]u8 = @splat(0xa5);
    var scratch: [65536]u8 = undefined;
    const capacity = smith.valueRangeAtMost(u32, 0, 8192);
    const q = .{ .urgent = schema.noul("Urgent?") };
    const encoded = codec.encode(state[0..len], q, "jev-latest", output[1..][0..capacity], &scratch);
    if (encoded) |bytes| {
        const parsed = try codec.parse(bytes, &scratch);
        const value = parsed.object.get("state").?;
        // Valid UTF-8 strings must round-trip exactly. std.json may encode
        // arbitrary invalid UTF-8 byte slices as an array; that is allowed state.
        if (std.unicode.utf8ValidateSlice(state[0..len]))
            try t.expectEqualStrings(state[0..len], try codec.string(value));
    } else |err| try t.expect(err == error.RequestTooLarge or err == error.WorkspaceTooSmall or err == error.InvalidRequest);
    try t.expectEqual(@as(u8, 0xa5), output[0]);
    try t.expectEqual(@as(u8, 0xa5), output[capacity + 1]);
}
test "fuzz request encoder" {
    if (try replay(fuzzEncode)) return;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const inputs = [_][]const u8{ "", "normal ticket", "quotes\" and newline\n", "\xf0\x9f\x98\x80", "\xff\x00", "a" ** 2048 };
    var seeds: [inputs.len * 2][]const u8 = undefined;
    for (inputs, 0..) |input, i| {
        seeds[i * 2] = try seedInput(arena.allocator(), input, 8192);
        seeds[i * 2 + 1] = try seedInput(arena.allocator(), input, 0);
    }
    try t.fuzz({}, fuzzEncode, .{ .corpus = &seeds });
}

test "deterministic 100000 parser mutations across contract corpus" {
    const corpus = try std.json.parseFromSlice([]Fixture, t.allocator, @embedFile("fixtures/responses.json"), .{});
    defer corpus.deinit();
    var rng = std.Random.DefaultPrng.init(0x4a65766c696e);
    const random = rng.random();
    var bytes: [4096]u8 = undefined;
    for (0..100_000) |iteration| {
        const source = corpus.value[iteration % corpus.value.len].response;
        var len = source.len;
        @memcpy(bytes[0..len], source);
        switch (iteration % 5) {
            0 => for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
                bytes[random.uintLessThan(usize, len)] = random.int(u8);
            },
            1 => len = random.intRangeAtMost(usize, 0, len),
            2 => {
                len = random.intRangeAtMost(usize, 0, bytes.len);
                random.bytes(bytes[0..len]);
            },
            3 => {
                const at = random.uintLessThan(usize, len);
                std.mem.copyBackwards(u8, bytes[at + 1 .. len + 1], bytes[at..len]);
                bytes[at] = random.int(u8);
                len += 1;
            },
            else => {}, // Unmutated fixtures exercise successful deep decoding.
        }
        try probe(bytes[0..len], if (iteration % 3 == 0) 65536 else random.intRangeAtMost(usize, 0, 65536));
    }
}

test "deterministic 20000 request encoder inputs" {
    var rng = std.Random.DefaultPrng.init(0x656e636f6465);
    const random = rng.random();
    var bytes: [4096]u8 = undefined;
    for (0..20_000) |iteration| {
        random.bytes(&bytes);
        if (iteration % 2 == 0) for (&bytes) |*byte| {
            byte.* &= 0x7f;
        };
        var smith: t.Smith = .{ .in = &bytes };
        try fuzzEncode({}, &smith);
    }
}
