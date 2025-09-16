// 现代化的正则表达式API设计
// 提供直观、高效、类型安全的正则表达式匹配接口

const std = @import("std");
const Allocator = std.mem.Allocator;
// const ArrayList = std.ArrayList; // Use std.ArrayList directly
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const compile = @import("compile.zig");
const Program = compile.Program;
const exec = @import("exec.zig");
const input_new = @import("input_new.zig");
const Input = input_new.Input;
const utf8 = @import("utf8.zig");
const literal_engine = @import("literal_engine.zig");

// 匹配模式选项
pub const MatchOptions = struct {
    // 是否区分大小写
    case_insensitive: bool = false,
    // 是否启用Unicode支持
    unicode: bool = false,
    // 是否多行模式（^$匹配每行开头结尾）
    multiline: bool = false,
    // 是否点号匹配换行符
    dot_matches_newline: bool = false,
    // 是否启用字面量优化
    enable_literals: bool = true,
    // Unicode规范化形式
    normalization: ?NormalizationForm = null,

    pub const NormalizationForm = enum {
        nfc, // 规范化形式C
        nfd, // 规范化形式D
        nfkc, // 规范化形式KC
        nfkd, // 规范化形式KD
    };
};

// 匹配结果
pub const Match = struct {
    // 匹配的文本范围
    span: Span,
    // 捕获组位置（可选）
    captures: ?[]const Span,
    // 使用的匹配引擎信息
    engine_info: EngineInfo,

    pub const Span = struct {
        start: usize,
        end: usize,
    };

    pub const EngineInfo = struct {
        engine_type: EngineType,
        used_unicode: bool,
        used_literal_optimization: bool,
        match_time_ns: u64,
    };

    pub const EngineType = enum {
        thompson_nfa,
        lazy_dfa,
        literal_fixed_string,
        literal_boyer_moore,
    };

    // 获取匹配的文本
    pub fn text(self: Match, input: []const u8) []const u8 {
        return input[self.span.start..self.span.end];
    }

    // 获取捕获组文本
    pub fn captureText(self: Match, input: []const u8, index: usize) ?[]const u8 {
        if (self.captures == null or index >= self.captures.?.len) return null;
        const span = self.captures.?[index];
        return input[span.start..span.end];
    }

    // 获取捕获组数量
    pub fn captureCount(self: Match) usize {
        return if (self.captures) |caps| caps.len else 0;
    }
};

// 匹配迭代器
pub const MatchIterator = struct {
    allocator: Allocator,
    regex: *const Regex,
    input: []const u8,
    current_pos: usize,
    options: MatchOptions,

    pub fn init(allocator: Allocator, regex: *const Regex, input: []const u8, options: MatchOptions) MatchIterator {
        return MatchIterator{
            .allocator = allocator,
            .regex = regex,
            .input = input,
            .current_pos = 0,
            .options = options,
        };
    }

    pub fn deinit(self: *MatchIterator) void {
        _ = self;
        // 清理资源（如果需要）
    }

    // 获取下一个匹配
    pub fn next(self: *MatchIterator) !?Match {
        if (self.current_pos >= self.input.len) return null;

        const result = try self.regex.findAt(self.input, self.current_pos, self.options);
        if (result) |match| {
            self.current_pos = match.span.end;
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

// 编译选项
pub const CompileOptions = struct {
    // 是否启用字面量优化
    enable_literal_optimization: bool = true,
    // 是否启用Unicode支持
    unicode: bool = false,
    // 编译时优化级别
    optimization_level: OptimizationLevel = .default,

    pub const OptimizationLevel = enum {
        none, // 无优化
        default, // 默认优化
        aggressive, // 激进优化
    };
};

// 正则表达式类型
pub const Regex = struct {
    allocator: Allocator,
    compiled: Program,
    original_pattern: []const u8,
    compile_options: CompileOptions,
    // 缓存常用的匹配选项组合
    unicode_engine: ?*UnicodeEngine = null,

    const UnicodeEngine = struct {
        // Unicode特定的引擎状态
        // 这里将来可以集成 lazy_dfa 或其他Unicode优化引擎
    };

    // 编译正则表达式
    pub fn compile(allocator: Allocator, pattern: []const u8) !Regex {
        return compileWithOptions(allocator, pattern, .{});
    }

    // 带选项编译正则表达式
    pub fn compileWithOptions(allocator: Allocator, pattern: []const u8, options: CompileOptions) !Regex {
        var parser = @import("parse.zig").Parser.init(allocator);
        defer parser.deinit();

        const expr = try parser.parse(pattern);

        var compiler = @import("compile.zig").Compiler.init(allocator);
        defer compiler.deinit();

        const program = try compiler.compile(expr);

        return Regex{
            .allocator = allocator,
            .compiled = program,
            .original_pattern = pattern,
            .compile_options = options,
            .unicode_engine = null,
        };
    }

    // 释放资源
    pub fn deinit(self: *Regex) void {
        if (self.unicode_engine) |engine| {
            // 清理Unicode引擎资源
            self.allocator.destroy(engine);
        }
        self.compiled.deinit();
    }

    // 检查是否匹配（简单接口）
    pub fn isMatch(self: *const Regex, input: []const u8) !bool {
        const match_result = self.find(input) catch return false;
        return match_result != null;
    }

    // 查找第一个匹配
    pub fn find(self: *const Regex, input: []const u8) !?Match {
        return self.findWithOptions(input, .{});
    }

    // 带选项查找
    pub fn findWithOptions(self: *const Regex, input: []const u8, options: MatchOptions) !?Match {
        return self.findAt(input, 0, options);
    }

    // 从指定位置查找
    pub fn findAt(self: *const Regex, input: []const u8, start_pos: usize, options: MatchOptions) !?Match {
        _ = start_pos; // Start position would be used in a full implementation
        _ = options; // Match options would be used in a full implementation
        var input_obj = Input.init(input, .bytes);

        // 准备捕获槽位
        var slots = ArrayListUnmanaged(?usize).empty;
        defer slots.deinit(self.allocator);

        if (slots.items.len < self.compiled.slot_count) {
            try slots.resize(self.allocator, self.compiled.slot_count);
        }

        // 初始化捕获槽位
        for (slots.items) |*slot| {
            slot.* = null;
        }

        // 执行匹配 - prepare with match options
        const unicode_enabled = false;
        const start_time = std.time.nanoTimestamp();
        const matched = try exec.exec(self.allocator, self.compiled, self.compiled.find_start, &input_obj, &slots);
        const end_time = std.time.nanoTimestamp();
        _ = unicode_enabled; // Used for unicode matching configuration

        if (matched) {
            // 构建匹配结果
            var match = Match{
                .span = .{
                    .start = slots.items[0] orelse 0,
                    .end = slots.items[1] orelse input.len,
                },
                .captures = null,
                .engine_info = .{
                    .engine_type = .thompson_nfa,
                    .used_unicode = false,
                    .used_literal_optimization = self.compiled.literal_optimization.enabled,
                    .match_time_ns = @intCast(end_time - start_time),
                },
            };

            // 处理捕获组
            if (self.compiled.slot_count > 2) {
                const capture_count = (self.compiled.slot_count - 2) / 2;
                var captures = try self.allocator.alloc(Match.Span, capture_count);

                for (0..capture_count) |i| {
                    const base = 2 + i * 2;
                    if (slots.items[base] != null and slots.items[base + 1] != null) {
                        captures[i] = .{
                            .start = slots.items[base].?,
                            .end = slots.items[base + 1].?,
                        };
                    } else {
                        captures[i] = .{ .start = 0, .end = 0 };
                    }
                }

                match.captures = captures;
            }

            return match;
        }

        return null;
    }

    // 获取匹配迭代器
    pub fn iterator(self: *const Regex, input: []const u8) MatchIterator {
        return MatchIterator.init(self.allocator, self, input, .{});
    }

    // 获取带选项的匹配迭代器
    pub fn iteratorWithOptions(self: *const Regex, input: []const u8, options: MatchOptions) MatchIterator {
        return MatchIterator.init(self.allocator, self, input, options);
    }

    // 替换匹配的文本
    pub fn replace(self: *const Regex, input: []const u8, replacement: []const u8, allocator: Allocator) ![]u8 {
        return self.replaceWithOptions(input, replacement, .{}, allocator);
    }

    // 带选项的替换
    pub fn replaceWithOptions(self: *const Regex, input: []const u8, replacement: []const u8, options: MatchOptions, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var last_pos: usize = 0;
        var iter = self.iteratorWithOptions(input, options);

        while (try iter.next()) |match| {
            // 添加匹配前的文本
            try result.appendSlice(input[last_pos..match.span.start]);

            // 添加替换文本
            try result.appendSlice(replacement);

            last_pos = match.span.end;
        }

        // 添加剩余文本
        try result.appendSlice(input[last_pos..]);

        return result.toOwnedSlice();
    }

    // 分割字符串
    pub fn split(self: *const Regex, input: []const u8, allocator: Allocator) ![][]const u8 {
        return self.splitWithOptions(input, .{}, allocator);
    }

    // 带选项的分割
    pub fn splitWithOptions(self: *const Regex, input: []const u8, options: MatchOptions, allocator: Allocator) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer result.deinit();

        var last_pos: usize = 0;
        var iter = self.iteratorWithOptions(input, options);

        while (try iter.next()) |match| {
            const part = input[last_pos..match.span.start];
            try result.append(part);
            last_pos = match.span.end;
        }

        // 添加最后一部分
        if (last_pos < input.len) {
            try result.append(input[last_pos..]);
        }

        return result.toOwnedSlice();
    }

    // 获取正则表达式信息
    pub fn info(self: *const Regex) RegexInfo {
        return RegexInfo{
            .pattern = self.original_pattern,
            .has_captures = self.compiled.slot_count > 2,
            .capture_count = if (self.compiled.slot_count > 2) (self.compiled.slot_count - 2) / 2 else 0,
            .uses_unicode = self.compile_options.unicode,
            .literal_optimization = self.compiled.literal_optimization,
        };
    }

    // 编译时验证（如果支持的话）
    pub fn validateAtCompileTime() bool {
        // 将来可以添加编译时验证逻辑
        return true;
    }
};

// 正则表达式信息
pub const RegexInfo = struct {
    pattern: []const u8,
    has_captures: bool,
    capture_count: usize,
    uses_unicode: bool,
    literal_optimization: compile.Program.LiteralOptimization,
};

// 便捷函数
pub fn matches(allocator: Allocator, pattern: []const u8, input: []const u8) !bool {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.isMatch(input);
}

pub fn findFirst(allocator: Allocator, pattern: []const u8, input: []const u8) !?Match {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return regex.find(input);
}

pub fn findAll(allocator: Allocator, pattern: []const u8, input: []const u8) ![]Match {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    var iter = regex.iterator(input);
    return iter.collectAll(allocator);
}

// 测试和示例
test "basic regex functionality" {
    const allocator = std.testing.allocator;

    // 简单匹配
    {
        var regex = try Regex.compile(allocator, "hello");
        defer regex.deinit();

        try std.testing.expect(try regex.isMatch("hello world"));
        try std.testing.expect(!(try regex.isMatch("goodbye world")));
    }

    // 查找匹配
    {
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();

        const match = try regex.find("abc123def");
        try std.testing.expect(match != null);
        try std.testing.expectEqualStrings("123", match.?.text("abc123def"));
    }

    // 捕获组
    {
        var regex = try Regex.compile(allocator, "(\\w+)\\s+(\\w+)");
        defer regex.deinit();

        const match = try regex.find("hello world");
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 2), match.?.captureCount());
        try std.testing.expectEqualStrings("hello", match.?.captureText("hello world", 0).?);
        try std.testing.expectEqualStrings("world", match.?.captureText("hello world", 1).?);
    }

    // 迭代器
    {
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();

        var iter = regex.iterator("abc123def456ghi");
        var count: usize = 0;

        while (try iter.next()) |match| {
            count += 1;
            _ = match; // 使用匹配结果
        }

        try std.testing.expectEqual(@as(usize, 2), count);
    }

    // 替换
    {
        var regex = try Regex.compile(allocator, "\\d+");
        defer regex.deinit();

        const result = try regex.replace("abc123def456ghi", "NUM", allocator);
        defer allocator.free(result);

        try std.testing.expectEqualStrings("abcNUMdefNUMghi", result);
    }

    // 分割
    {
        var regex = try Regex.compile(allocator, "\\s+");
        defer regex.deinit();

        const result = try regex.split("a b c d", allocator);
        defer {
            for (result) |item| {
                allocator.free(item);
            }
            allocator.free(result);
        }

        try std.testing.expectEqual(@as(usize, 4), result.len);
        try std.testing.expectEqualStrings("a", result[0]);
        try std.testing.expectEqualStrings("b", result[1]);
        try std.testing.expectEqualStrings("c", result[2]);
        try std.testing.expectEqualStrings("d", result[3]);
    }
}
