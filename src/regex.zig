// External high-level Regex api.
//
// This hides details such as what matching engine is used internally and the parsing/compilation
// stages are merged into a single wrapper function.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const debug = std.debug;

const parse = @import("parse.zig");
const compile = @import("compile.zig");
const exec = @import("exec.zig");

const Parser = parse.Parser;
const Expr = parse.Expr;
const Compiler = compile.Compiler;
const Program = compile.Program;
const Instruction = compile.Instruction;

const input_new = @import("input_new.zig");
const Input = input_new.Input;
const InputBytes = input_new.InputBytes;

// 匹配选项 - 从 regex_new.zig 合并
pub const MatchOptions = struct {
    case_insensitive: bool = false,
    unicode: bool = false,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    enable_literals: bool = true,
};

// 编译选项 - 从 regex_new.zig 合并
pub const CompileOptions = struct {
    enable_literal_optimization: bool = true,
    unicode: bool = false,
    optimization_level: OptimizationLevel = .default,

    pub const OptimizationLevel = enum {
        none,
        default,
        aggressive,
    };
};

// 匹配结果 - 从 regex_new.zig 合并
pub const Match = struct {
    span: Span,
    captures: ?[]const Span,
    matched_text: []const u8,

    // 获取匹配的文本
    pub fn text(self: Match, input: []const u8) []const u8 {
        return input[self.span.lower..self.span.upper];
    }

    // 获取捕获组文本
    pub fn captureText(self: Match, input: []const u8, index: usize) ?[]const u8 {
        if (self.captures == null or index >= self.captures.?.len) return null;
        const span = self.captures.?[index];
        return input[span.lower..span.upper];
    }

    // 获取捕获组数量
    pub fn captureCount(self: Match) usize {
        return if (self.captures) |caps| caps.len else 0;
    }
};

// 匹配迭代器 - 从 regex_new.zig 合并
pub const MatchIterator = struct {
    allocator: Allocator,
    regex: *const Regex,
    input: []const u8,
    current_pos: usize,

    pub fn init(allocator: Allocator, regex: *const Regex, input: []const u8) MatchIterator {
        return MatchIterator{
            .allocator = allocator,
            .regex = regex,
            .input = input,
            .current_pos = 0,
        };
    }

    pub fn deinit(self: *MatchIterator) void {
        _ = self;
    }

    // 获取下一个匹配
    pub fn next(self: *MatchIterator) !?Match {
        if (self.current_pos >= self.input.len) return null;

        const result = try self.regex.findAt(self.input, self.current_pos);
        if (result) |match| {
            self.current_pos = match.span.upper;
            return match;
        }
        return null;
    }

    // 获取所有匹配
    pub fn collectAll(self: *MatchIterator, allocator: Allocator) ![]Match {
        var match_list = std.ArrayList(Match).init(allocator);
        errdefer match_list.deinit();

        while (try self.next()) |match| {
            try match_list.append(match);
        }

        return match_list.toOwnedSlice();
    }
};

pub const Regex = struct {
    // Internal allocator
    allocator: Allocator,
    // A compiled set of instructions
    compiled: Program,
    // Capture slots
    slots: ArrayList(?usize),
    // Original regex string
    string: []const u8,

    // Compile a regex, possibly returning any error which occurred.
    pub fn compile(a: Allocator, re: []const u8) !Regex {
        return compileWithOptions(a, re, .{});
    }

    // 带选项编译正则表达式 - 从 regex_new.zig 合并
    pub fn compileWithOptions(a: Allocator, re: []const u8, options: CompileOptions) !Regex {
        _ = options; // TODO: 实现选项功能
        var p = Parser.init(a);
        defer p.deinit();

        const expr = try p.parse(re);

        var c = Compiler.init(a);
        defer c.deinit();

        return Regex{
            .allocator = a,
            .compiled = try c.compile(expr),
            .slots = ArrayListUnmanaged(?usize).empty,
            .string = re,
        };
    }

    pub fn deinit(re: *Regex) void {
        re.slots.deinit(re.allocator);
        re.compiled.deinit();
    }

    // Does the regex match anywhere in the string?
    pub fn match(re: *Regex, input_str: []const u8) !bool {
        var input = Input.init(input_str, .bytes);
        return exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input, &re.slots);
    }

    // Does the regex match anywhere in the string?
    pub fn partialMatch(re: *Regex, input_str: []const u8) !bool {
        var input = Input.init(input_str, .bytes);
        return exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input, &re.slots);
    }

    // 简化的匹配接口 - 从 regex_new.zig 合并
    pub fn isMatch(re: *Regex, input_str: []const u8) !bool {
        return re.match(input_str);
    }

    // 查找第一个匹配 - 从 regex_new.zig 合并
    pub fn find(re: *Regex, input_str: []const u8) !?Match {
        return re.findAt(input_str, 0);
    }

    // 从指定位置查找 - 从 regex_new.zig 合并
    pub fn findAt(re: *Regex, input_str: []const u8, start_pos: usize) !?Match {
        _ = start_pos; // TODO: 实现 start_pos 功能
        var input = Input.init(input_str, .bytes);
        const is_match = try exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input, &re.slots);

        if (is_match) {
            return Match{
                .span = Span{
                    .lower = re.slots.items[0] orelse 0,
                    .upper = re.slots.items[1] orelse input_str.len,
                },
                .captures = null, // TODO: 实现捕获组
                .matched_text = input_str[re.slots.items[0] orelse 0 .. re.slots.items[1] orelse input_str.len],
            };
        }
        return null;
    }

    // 创建匹配迭代器 - 从 regex_new.zig 合并
    pub fn iterator(re: *Regex, input_str: []const u8) MatchIterator {
        return MatchIterator.init(re.allocator, re, input_str);
    }

    // Where in the string does the regex and its capture groups match?
    //
    // Zero capture is the entire match.
    pub fn captures(re: *Regex, input_str: []const u8) !?Captures {
        var input = Input.init(input_str, .bytes);
        const is_match = try exec.exec(re.allocator, re.compiled, re.compiled.find_start, &input, &re.slots);

        if (is_match) {
            return try Captures.init(input_str, re.allocator, &re.slots);
        } else {
            return null;
        }
    }
};

// A pair of bounds used to index into an associated slice.
pub const Span = struct {
    lower: usize,
    upper: usize,
};

// A set of captures of a Regex on an input slice.
pub const Captures = struct {
    const Self = @This();

    input: []const u8,
    allocator: Allocator,
    slots: []const ?usize,

    pub fn init(input: []const u8, allocator: Allocator, slots: *ArrayListUnmanaged(?usize)) !Captures {
        return Captures{
            .input = input,
            .allocator = allocator,
            .slots = try allocator.dupe(?usize, slots.items),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    pub fn len(self: *const Self) usize {
        return self.slots.len / 2;
    }

    // Return the slice of the matching string for the specified capture index.
    // If the index did not participate in the capture group null is returned.
    pub fn sliceAt(self: *const Self, n: usize) ?[]const u8 {
        if (self.boundsAt(n)) |span| {
            return self.input[span.lower..span.upper];
        }

        return null;
    }

    // Return the substring slices of the input directly.
    pub fn boundsAt(self: *const Self, n: usize) ?Span {
        const base = 2 * n;

        if (base < self.slots.len) {
            if (self.slots[base]) |lower| {
                if (self.slots[base + 1]) |upper| {
                    if (lower <= upper) {
                        return Span{
                            .lower = lower,
                            .upper = upper,
                        };
                    }
                }
            }
        }

        return null;
    }
};
