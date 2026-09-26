const std = @import("std");
pub const Kind = enum { noul, choice, score };
pub const Noul = struct {
    pub const kind: Kind = .noul;
    pub const Answer = struct { probability: f64 };
    instructions: []const u8,
    pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
        try w.write(.{ .type = "noul", .instructions = q.instructions });
    }
};
pub fn noul(instructions: []const u8) Noul {
    return .{ .instructions = instructions };
}

pub fn Choice(comptime E: type) type {
    const info = @typeInfo(E);
    if (info != .@"enum" or !info.@"enum".is_exhaustive) @compileError("Choice requires an exhaustive enum");
    const n = info.@"enum".fields.len;
    if (n < 1 or n > 255) @compileError("Choice requires 1..255 options");
    return struct {
        pub const kind: Kind = .choice;
        pub const Options = E;
        pub const Descriptions = std.enums.EnumFieldStruct(E, ?[]const u8, @as(?[]const u8, null));
        pub const Answer = struct {
            choice: E,
            probabilities: std.enums.EnumFieldStruct(E, f64, null),
            confidence: f64,
        };
        instructions: []const u8,
        descriptions: Descriptions = .{},
        pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
            try w.write(.{ .type = "choice", .instructions = q.instructions, .criteria = q.descriptions });
        }
    };
}
pub fn choice(comptime E: type, instructions: []const u8, descriptions: Choice(E).Descriptions) Choice(E) {
    return .{ .instructions = instructions, .descriptions = descriptions };
}
pub fn Score(comptime n: usize) type {
    if (n < 2 or n > 10) @compileError("Score requires 2..10 levels");
    return struct {
        pub const kind: Kind = .score;
        pub const count = n;
        pub const Answer = struct { score: f64, probabilities: [n]f64, confidence: f64, legend: [n]std.json.Value };
        instructions: []const u8,
        levels: [n][]const u8,
        pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
            try w.write(.{ .type = "score", .instructions = q.instructions, .criteria = q.levels });
        }
    };
}
pub fn score(instructions: []const u8, levels: anytype) Score(levels.len) {
    return .{ .instructions = instructions, .levels = levels };
}
pub fn Answers(comptime Q: type) type {
    const fields = @typeInfo(Q).@"struct".fields;
    if (fields.len == 0 or fields.len > 128) @compileError("A batch requires 1..128 questions");
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;
    const attrs: [fields.len]std.builtin.Type.StructField.Attributes = @splat(.{});
    for (fields, 0..) |field, i| {
        if (field.name.len == 0) @compileError("Question IDs must not be empty");
        names[i] = field.name;
        types[i] = field.type.Answer;
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Structured instructions with optional true/false descriptions. Pass null to
/// omit criteria. Values are borrowed until evaluate returns.
pub fn noulWithCriteria(instructions: anytype, criteria: anytype) struct {
    pub const structured = true;
    pub const kind: Kind = .noul;
    pub const Answer = Noul.Answer;
    instructions: @TypeOf(instructions),
    criteria: @TypeOf(criteria),
    pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
        if (@TypeOf(q.criteria) == @TypeOf(null))
            try w.write(.{ .type = "noul", .instructions = q.instructions })
        else
            try w.write(.{ .type = "noul", .instructions = q.instructions, .criteria = q.criteria });
    }
} {
    return .{ .instructions = instructions, .criteria = criteria };
}
pub fn choiceStructured(comptime E: type, instructions: anytype, descriptions: anytype) struct {
    pub const structured = true;
    pub const kind: Kind = .choice;
    pub const Options = E;
    pub const Answer = Choice(E).Answer;
    instructions: @TypeOf(instructions),
    descriptions: @TypeOf(descriptions),
    pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
        try w.write(.{ .type = "choice", .instructions = q.instructions, .criteria = q.descriptions });
    }
} {
    return .{ .instructions = instructions, .descriptions = descriptions };
}
pub fn scoreStructured(instructions: anytype, levels: anytype) struct {
    pub const structured = true;
    pub const kind: Kind = .score;
    pub const count = levels.len;
    pub const Answer = Score(count).Answer;
    instructions: @TypeOf(instructions),
    levels: @TypeOf(levels),
    pub fn jsonStringify(q: @This(), w: *std.json.Stringify) !void {
        try w.write(.{ .type = "score", .instructions = q.instructions, .criteria = q.levels });
    }
} {
    return .{ .instructions = instructions, .levels = levels };
}
