// Simple and clean Regex API
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const parse = @import("parse.zig");
const compile = @import("compile.zig");
const thompson_nfa = @import("thompson_nfa.zig");
const input_mod = @import("input.zig");

const Parser = parse.Parser;
const Compiler = compile.Compiler;
const DirectCompiler = compile.DirectCompiler;
const Program = compile.Program;
const Input = input_mod.Input;

pub const Regex = struct {
    allocator: Allocator,
    program: Program,
    pattern: []const u8,

    pub fn compile(allocator: Allocator, pattern: []const u8) !Regex {
        // 暂时恢复原来的编译方式，DirectCompiler需要更完整的实现
        var parser = Parser.init(allocator);
        defer parser.deinit();

        const expr = try parser.parse(pattern);

        var compiler = Compiler.init(allocator);
        defer compiler.deinit();

        const compiled_program = try compiler.compile(expr);
        return Regex{
            .allocator = allocator,
            .program = compiled_program,
            .pattern = pattern,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.program.deinit();
    }

    pub fn match(self: *Regex, input: []const u8) !bool {
        var input_obj = Input.init(input, .bytes);
        var slots = std.ArrayListUnmanaged(?usize){};
        defer slots.deinit(self.allocator);
        return thompson_nfa.ThompsonNfa.exec(self.allocator, self.program, self.program.find_start, &input_obj, &slots);
    }

    pub fn partialMatch(self: *Regex, input: []const u8) !bool {
        return self.match(input);
    }

    pub fn find(self: *Regex, input: []const u8) !?Match {
        var input_obj = Input.init(input, .bytes);
        var slots = std.ArrayListUnmanaged(?usize){};
        defer slots.deinit(self.allocator);

        const is_match = try thompson_nfa.ThompsonNfa.exec(self.allocator, self.program, self.program.find_start, &input_obj, &slots);

        if (is_match) {
            return Match{
                .start = slots.items[0] orelse 0,
                .end = slots.items[1] orelse input.len,
            };
        }
        return null;
    }

    pub fn captures(self: *Regex, input: []const u8) !?Captures {
        var input_obj = Input.init(input, .bytes);
        var slots = std.ArrayListUnmanaged(?usize){};
        defer slots.deinit(self.allocator);

        const is_match = try thompson_nfa.ThompsonNfa.exec(self.allocator, self.program, self.program.find_start, &input_obj, &slots);

        if (is_match) {
            return try Captures.init(input, self.allocator, slots.items);
        }
        return null;
    }
};

pub const Match = struct {
    start: usize,
    end: usize,

    pub fn text(self: Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

pub const Captures = struct {
    const Self = @This();

    input: []const u8,
    allocator: Allocator,
    slots: []const ?usize,

    pub fn init(input: []const u8, allocator: Allocator, slots: []const ?usize) !Captures {
        return Captures{
            .input = input,
            .allocator = allocator,
            .slots = try allocator.dupe(?usize, slots),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    pub fn len(self: *const Self) usize {
        return self.slots.len / 2;
    }

    pub fn sliceAt(self: *const Self, n: usize) ?[]const u8 {
        const base = 2 * n;
        if (base >= self.slots.len) return null;

        const start = self.slots[base] orelse return null;
        const end = self.slots[base + 1] orelse return null;

        return self.input[start..end];
    }

    pub fn get(self: *const Self, n: usize) ?Match {
        const base = 2 * n;
        if (base >= self.slots.len) return null;

        const start = self.slots[base] orelse return null;
        const end = self.slots[base + 1] orelse return null;

        return Match{ .start = start, .end = end };
    }
};
