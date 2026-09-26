const std = @import("std");
const schema = @import("schema.zig");
pub const Error = error{ InvalidRequest, InvalidResponse, RequestTooLarge, WorkspaceTooSmall };
const Value = std.json.Value;
const Object = std.json.ObjectMap;
// Allow rounding in vendor probabilities, but reject grossly inconsistent data.
pub const probability_tolerance = 0.02;
pub const max_depth = 32;

pub fn parse(bytes: []const u8, memory: []u8) Error!Value {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidResponse;
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    var depth: usize = 0;
    // Each token consumes input, except end_of_document. Bound by bytes + 1.
    for (0..bytes.len + 1) |_| {
        const token = scanner.next() catch |err| return if (err == error.OutOfMemory) error.WorkspaceTooSmall else error.InvalidResponse;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > max_depth) return error.InvalidResponse;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidResponse;
                depth -= 1;
            },
            .end_of_document => break,
            else => {},
        }
    }
    scanner.deinit();
    fixed.reset();
    const parsed = std.json.parseFromSlice(Value, fixed.allocator(), bytes, .{
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.WorkspaceTooSmall,
        else => error.InvalidResponse,
    };
    // All allocations belong to caller's fixed scratch storage; no heap cleanup.
    return parsed.value;
}
pub fn encode(state: anytype, questions: anytype, model: []const u8, output: []u8, scratch: []u8) Error![]const u8 {
    if (model.len == 0 or !std.unicode.utf8ValidateSlice(model)) return error.InvalidRequest;
    inline for (@typeInfo(@TypeOf(questions)).@"struct".fields) |field| {
        if (!@hasDecl(field.type, "structured")) {
            const q = @field(questions, field.name);
            if (!std.unicode.utf8ValidateSlice(q.instructions)) return error.InvalidRequest;
            if (field.type.kind == .score) for (q.levels) |level| {
                if (!std.unicode.utf8ValidateSlice(level)) return error.InvalidRequest;
            };
            if (field.type.kind == .choice) inline for (@typeInfo(field.type.Options).@"enum".fields) |option| {
                if (@field(q.descriptions, option.name)) |text| {
                    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidRequest;
                }
            };
        }
    }
    var writer: std.Io.Writer = .fixed(output);
    std.json.Stringify.value(.{ .model = model, .state = state, .questions = questions }, .{}, &writer) catch return error.RequestTooLarge;
    const bytes = writer.buffered();
    const tree = parse(bytes, scratch) catch |err| return if (err == error.WorkspaceTooSmall) err else error.InvalidRequest;
    const state_value = tree.object.get("state") orelse return error.InvalidRequest;
    switch (state_value) {
        .string, .object, .array => {},
        else => return error.InvalidRequest,
    }
    try validateQuestions(@TypeOf(questions), tree.object.get("questions").?);
    return bytes;
}
pub fn object(v: Value) Error!Object {
    return if (v == .object) v.object else error.InvalidResponse;
}
pub fn get(o: Object, name: []const u8) Error!Value {
    return o.get(name) orelse error.InvalidResponse;
}
pub fn string(v: Value) Error![]const u8 {
    return if (v == .string) v.string else error.InvalidResponse;
}
pub fn number(v: Value) Error!f64 {
    const n: f64 = switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        else => return error.InvalidResponse,
    };
    if (!std.math.isFinite(n)) return error.InvalidResponse;
    return n;
}
fn probability(v: Value) Error!f64 {
    const n = try number(v);
    if (n < 0 or n > 1) return error.InvalidResponse;
    return n;
}
fn distribution(sum: f64) Error!void {
    if (@abs(sum - 1) > probability_tolerance) return error.InvalidResponse;
}
pub fn decode(comptime Q: type, tree: Value) Error!schema.Answers(Q) {
    const root = try object(tree);
    const answers = try object(try get(root, "answers"));
    var result: schema.Answers(Q) = undefined;
    inline for (@typeInfo(Q).@"struct".fields) |field| {
        const answer = try object(try get(answers, field.name));
        if (!std.mem.eql(u8, try string(try get(answer, "type")), @tagName(field.type.kind))) return error.InvalidResponse;
        @field(result, field.name) = switch (field.type.kind) {
            .noul => .{ .probability = try probability(try get(answer, "noul")) },
            .choice => try decodeChoice(field.type, answer),
            .score => try decodeScore(field.type, answer),
        };
    }
    return result;
}
fn decodeChoice(comptime Q: type, answer: Object) Error!Q.Answer {
    const selected = std.meta.stringToEnum(Q.Options, try string(try get(answer, "choice"))) orelse return error.InvalidResponse;
    const probabilities = try object(try get(answer, "probabilities"));
    const fields = @typeInfo(Q.Options).@"enum".fields;
    if (probabilities.count() != fields.len) return error.InvalidResponse;
    var out: Q.Answer = .{ .choice = selected, .probabilities = undefined, .confidence = try probability(try get(answer, "confidence")) };
    var sum: f64 = 0;
    var maximum: f64 = 0;
    inline for (fields) |field| {
        const p = try probability(try get(probabilities, field.name));
        @field(out.probabilities, field.name) = p;
        sum += p;
        maximum = @max(maximum, p);
    }
    try distribution(sum);
    inline for (fields) |field| {
        if (selected == @field(Q.Options, field.name) and @field(out.probabilities, field.name) + probability_tolerance < maximum) return error.InvalidResponse;
    }
    return out;
}
fn decodeScore(comptime Q: type, answer: Object) Error!Q.Answer {
    const n = Q.count;
    const probabilities = try object(try get(answer, "probabilities"));
    const legend = try object(try get(answer, "legend"));
    if (probabilities.count() != n or legend.count() != n) return error.InvalidResponse;
    var out: Q.Answer = .{ .score = try number(try get(answer, "score")), .confidence = try probability(try get(answer, "confidence")), .probabilities = undefined, .legend = undefined };
    if (out.score < 0 or out.score > n - 1) return error.InvalidResponse;
    var sum: f64 = 0;
    var weighted: f64 = 0;
    inline for (0..n) |i| {
        const key = std.fmt.comptimePrint("{d}", .{i});
        out.probabilities[i] = try probability(try get(probabilities, key));
        out.legend[i] = try get(legend, key);
        switch (out.legend[i]) {
            .string, .object, .array => {},
            else => return error.InvalidResponse,
        }
        sum += out.probabilities[i];
        weighted += out.probabilities[i] * @as(f64, @floatFromInt(i));
    }
    try distribution(sum);
    if (@abs(out.score - weighted) > probability_tolerance * @as(f64, n)) return error.InvalidResponse;
    return out;
}

pub const Usage = struct { input_tokens: u64, output_tokens: u64 };
pub fn decodeUsage(tree: Value) Error!?Usage {
    const root = try object(tree);
    const value = root.get("usage") orelse return null;
    const usage = try object(value);
    return .{ .input_tokens = try tokenCount(try get(usage, "input_tokens")), .output_tokens = try tokenCount(try get(usage, "output_tokens")) };
}
fn tokenCount(value: Value) Error!u64 {
    if (value != .integer or value.integer < 0) return error.InvalidResponse;
    return @intCast(value.integer);
}
fn description(value: Value) Error!void {
    switch (value) {
        .string => if (value.string.len == 0) return error.InvalidRequest,
        .object, .array => {},
        else => return error.InvalidRequest,
    }
}
fn validateQuestions(comptime Q: type, value: Value) Error!void {
    inline for (@typeInfo(Q).@"struct".fields) |field| {
        const q = value.object.get(field.name).?.object;
        try description(q.get("instructions").?);
        switch (field.type.kind) {
            .noul => if (q.get("criteria")) |criteria| {
                if (criteria != .object) return error.InvalidRequest;
                var iterator = criteria.object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "true") and !std.mem.eql(u8, entry.key_ptr.*, "false")) return error.InvalidRequest;
                    try description(entry.value_ptr.*);
                }
            },
            .choice => {
                const criteria = q.get("criteria").?;
                const fields = @typeInfo(field.type.Options).@"enum".fields;
                if (criteria != .object or criteria.object.count() != fields.len) return error.InvalidRequest;
                inline for (fields) |option| {
                    const v = criteria.object.get(option.name) orelse return error.InvalidRequest;
                    // Empty text descriptions remain valid for compatibility.
                    if (v != .null and v != .string) try description(v);
                }
            },
            .score => {
                const criteria = q.get("criteria").?;
                if (criteria != .array or criteria.array.items.len != field.type.count) return error.InvalidRequest;
                for (criteria.array.items) |level| try description(level);
            },
        }
    }
}
