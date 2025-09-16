// 编译时正则表达式优化和验证
// 利用Zig的编译时计算能力提供零开销的优化

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const compile = @import("compile.zig");
const Program = compile.Program;
const literal_engine = @import("literal_engine.zig");

// 编译时正则表达式分析结果
pub const CompileTimeAnalysis = struct {
    is_valid: bool = true,
    error_message: ?[]const u8 = null,
    has_errors: bool = false,

    // 性能特征
    complexity: Complexity = .simple,
    has_captures: bool = false,
    capture_count: usize = 0,
    is_anchored: bool = false,
    is_unicode: bool = false,

    // 优化机会
    literal_prefix: ?[]const u8 = null,
    literal_suffix: ?[]const u8 = null,
    is_literal_only: bool = false,

    // 内存估算
    estimated_instructions: usize = 0,
    estimated_memory_bytes: usize = 0,

    pub const Complexity = enum {
        trivial, // 简单字面量匹配
        simple, // 简单正则表达式
        moderate, // 中等复杂度
        complex, // 复杂正则表达式
        extreme, // 极端复杂（可能存在性能问题）
    };
};

// 编译时正则表达式验证器
pub const CompileTimeValidator = struct {
    const Self = @This();

    pattern: []const u8,
    analysis: CompileTimeAnalysis,

    pub fn init(pattern: []const u8) Self {
        return Self{
            .pattern = pattern,
            .analysis = .{},
        };
    }

    // 编译时验证正则表达式语法
    pub fn validateSyntax(self: *Self) CompileTimeAnalysis {
        // 基本语法检查
        if (self.pattern.len == 0) {
            self.analysis.is_valid = false;
            self.analysis.error_message = "Empty pattern";
            return self.analysis;
        }

        // 检查括号匹配
        var paren_count: i32 = 0;
        var bracket_count: i32 = 0;
        var brace_count: i32 = 0;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '(' => paren_count += 1,
                ')' => {
                    paren_count -= 1;
                    if (paren_count < 0) {
                        self.analysis.is_valid = false;
                        self.analysis.error_message = "Unmatched closing parenthesis";
                        return self.analysis;
                    }
                },
                '[' => bracket_count += 1,
                ']' => {
                    bracket_count -= 1;
                    if (bracket_count < 0) {
                        self.analysis.is_valid = false;
                        self.analysis.error_message = "Unmatched closing bracket";
                        return self.analysis;
                    }
                },
                '{' => {
                    // 检查是否是量词而不是字面量
                    if (i > 0 and isQuantifierPreceding(self.pattern[i - 1])) {
                        brace_count += 1;
                    }
                },
                '}' => {
                    if (brace_count > 0) {
                        brace_count -= 1;
                    }
                },
                // 检查无效的转义序列
                '\\' => {
                    if (i + 1 >= self.pattern.len) {
                        self.analysis.is_valid = false;
                        self.analysis.error_message = "Dangling escape character";
                        return self.analysis;
                    }

                    const next_char = self.pattern[i + 1];
                    if (!isValidEscapeChar(next_char)) {
                        self.analysis.is_valid = false;
                        self.analysis.error_message = "Invalid escape sequence";
                        return self.analysis;
                    }

                    // 跳过下一个字符
                    i += 1;
                },
                // 检查重复的量词
                '*', '+', '?', '{' => {
                    if (i > 0 and isQuantifierChar(self.pattern[i - 1])) {
                        self.analysis.is_valid = false;
                        self.analysis.error_message = "Repeated quantifier";
                        return self.analysis;
                    }
                },
                else => {},
            }
        }

        if (paren_count != 0) {
            self.analysis.is_valid = false;
            self.analysis.error_message = "Unmatched opening parenthesis";
            return self.analysis;
        }

        if (bracket_count != 0) {
            self.analysis.is_valid = false;
            self.analysis.error_message = "Unmatched opening bracket";
            return self.analysis;
        }

        // 检查字符类语法
        if (!self.validateCharacterClasses()) {
            return self.analysis;
        }

        // 分析复杂度
        self.analyzeComplexity();

        return self.analysis;
    }

    // 验证字符类语法
    fn validateCharacterClasses(self: *Self) bool {
        var in_char_class = false;
        var range_start: ?u8 = null;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '[' => {
                    if (!in_char_class) {
                        in_char_class = true;
                        // 检查是否是负向字符类
                        if (i + 1 < self.pattern.len and self.pattern[i + 1] == '^') {
                            i += 1; // 跳过^
                        }
                    }
                },
                ']' => {
                    if (in_char_class) {
                        if (range_start != null) {
                            self.analysis.is_valid = false;
                            self.analysis.error_message = "Incomplete character range";
                            return false;
                        }
                        in_char_class = false;
                    }
                },
                '-' => {
                    if (in_char_class and i > 0 and i + 1 < self.pattern.len) {
                        if (self.pattern[i - 1] != '[' and self.pattern[i + 1] != ']') {
                            range_start = self.pattern[i - 1];
                        }
                    }
                },
                else => {
                    range_start = null;
                },
            }
        }

        return true;
    }

    // 分析复杂度
    fn analyzeComplexity(self: *Self) void {
        var complexity_score: u32 = 0;
        var capture_count: usize = 0;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '(' => {
                    // 检查是否是捕获组
                    if (i + 1 < self.pattern.len and self.pattern[i + 1] != '?') {
                        capture_count += 1;
                        complexity_score += 2;
                    } else {
                        complexity_score += 1; // 非捕获组
                    }
                },
                '*', '+', '?' => complexity_score += 1,
                '{' => complexity_score += 3, // 量词
                '[' => complexity_score += 2, // 字符类
                '\\' => {
                    if (i + 1 < self.pattern.len) {
                        const next_char = self.pattern[i + 1];
                        switch (next_char) {
                            'd', 'D', 'w', 'W', 's', 'S' => complexity_score += 1,
                            'b', 'B' => complexity_score += 1,
                            'p', 'P' => complexity_score += 5, // Unicode属性
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // 设置复杂度等级
        self.analysis.complexity = if (complexity_score <= 2)
            .trivial
        else if (complexity_score <= 10)
            .simple
        else if (complexity_score <= 25)
            .moderate
        else if (complexity_score <= 50)
            .complex
        else
            .extreme;

        self.analysis.has_captures = capture_count > 0;
        self.analysis.capture_count = capture_count;

        // 估算资源使用
        self.analysis.estimated_instructions = @max(1, complexity_score * 3);
        self.analysis.estimated_memory_bytes = self.analysis.estimated_instructions * @sizeOf(compile.Instruction);

        // 分析字面量前缀
        self.analyzeLiteralOptimizations();
    }

    // 分析字面量优化机会
    fn analyzeLiteralOptimizations(self: *Self) void {
        // 寻找字面量前缀
        var literal_prefix_len: usize = 0;

        for (self.pattern) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', ' ', '_', '-', '.' => {
                    literal_prefix_len += 1;
                },
                '\\', '(', ')', '[', ']', '{', '}', '*', '+', '?', '^', '$', '|' => {
                    break;
                },
                else => {
                    if (c >= 128) {
                        // Unicode字符，可能需要特殊处理
                        break;
                    }
                    literal_prefix_len += 1;
                },
            }
        }

        if (literal_prefix_len > 0) {
            self.analysis.literal_prefix = self.pattern[0..literal_prefix_len];
        }

        // 检查是否是纯字面量
        if (literal_prefix_len == self.pattern.len) {
            self.analysis.is_literal_only = true;
            self.analysis.complexity = .trivial;
        }

        // 检查是否锚定
        if (self.pattern.len > 0 and self.pattern[0] == '^') {
            self.analysis.is_anchored = true;
        }
    }
};

// 编译时优化器
pub const CompileTimeOptimizer = struct {
    const Self = @This();

    // 编译时优化建议
    pub const OptimizationSuggestion = struct {
        strategy: []const u8,
        reason: []const u8,
        expected_improvement: f32, // 性能提升倍数
        memory_saving: f32, // 内存节省百分比
    };

    // 获取编译时优化建议
    pub fn getSuggestions(pattern: []const u8, analysis: CompileTimeAnalysis) []const OptimizationSuggestion {
        var suggestions: [4]OptimizationSuggestion = undefined;
        var count: usize = 0;

        // 字面量优化建议
        if (analysis.is_literal_only and pattern.len >= 3) {
            suggestions[count] = .{
                .strategy = "literal_fixed_string",
                .reason = "Pattern is a literal string",
                .expected_improvement = 100.0,
                .memory_saving = 90.0,
            };
            count += 1;
        }

        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 5) {
            suggestions[count] = .{
                .strategy = "literal_prefix_optimization",
                .reason = "Long literal prefix detected",
                .expected_improvement = 10.0,
                .memory_saving = 20.0,
            };
            count += 1;
        }

        // Boyer-Moore建议
        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 10) {
            suggestions[count] = .{
                .strategy = "boyer_moore",
                .reason = "Long pattern suitable for Boyer-Moore",
                .expected_improvement = 50.0,
                .memory_saving = 30.0,
            };
            count += 1;
        }

        // 复杂模式建议
        if (analysis.complexity == .extreme) {
            suggestions[count] = .{
                .strategy = "simplify_pattern",
                .reason = "Pattern is too complex, consider simplifying",
                .expected_improvement = 0.0,
                .memory_saving = 0.0,
            };
            count += 1;
        }

        return suggestions[0..count];
    }

    // 编译时常量折叠
    pub fn foldConstants(pattern: []const u8) []const u8 {
        // 简单的常量折叠：移除不必要的分组和转义
        var folded = std.ArrayList(u8).init(std.heap.page_allocator);
        defer folded.deinit();

        for (pattern, 0..) |c, i| {
            switch (c) {
                '\\' => {
                    if (i + 1 < pattern.len) {
                        const next = pattern[i + 1];
                        // 一些转义序列可以简化
                        switch (next) {
                            'd', 'D', 'w', 'W', 's', 'S', 'b', 'B' => {
                                // 保留这些转义序列
                                folded.append('\\') catch break;
                                folded.append(next) catch break;
                            },
                            // 简单字符转义
                            'n' => folded.append('\n') catch break,
                            'r' => folded.append('\r') catch break,
                            't' => folded.append('\t') catch break,
                            else => {
                                // 其他情况保持原样
                                folded.append('\\') catch break;
                                folded.append(next) catch break;
                            },
                        }
                        // 跳过下一个字符
                        i += 1;
                    }
                },
                // 移除非捕获组的括号
                '(', ')' => {
                    // 简化：保留所有括号，实际实现需要更复杂的分析
                    folded.append(c) catch break;
                },
                else => {
                    folded.append(c) catch break;
                },
            }
        }

        const result = folded.toOwnedSlice() catch pattern;
        return result;
    }
};

// 编译时正则表达式包装器
pub fn ComptimeRegex(comptime pattern: []const u8) type {
    return struct {
        const Self = @This();

        // 编译时分析结果
        pub const analysis = comptime blk: {
            var validator = CompileTimeValidator.init(pattern);
            break :blk validator.validateSyntax();
        };

        // 编译时优化建议
        pub const optimizations = comptime blk: {
            var suggestions = CompileTimeOptimizer.getSuggestions(pattern, analysis);
            break :blk suggestions;
        };

        // 编译时折叠后的模式
        pub const folded_pattern = comptime CompileTimeOptimizer.foldConstants(pattern);

        // 编译时验证
        comptime {
            if (!analysis.is_valid) {
                @compileError(std.fmt.comptimePrint("Invalid regex pattern: {s}", .{analysis.error_message orelse "unknown error"}));
            }

            if (analysis.complexity == .extreme) {
                std.log.warn("Complex regex pattern may have performance issues", .{});
            }
        }

        allocator: Allocator,
        inner_regex: ?*RegexNew = null,

        const RegexNew = @import("regex_new.zig").Regex;

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .allocator = allocator,
                .inner_regex = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.inner_regex) |regex| {
                regex.deinit();
                self.allocator.destroy(regex);
            }
        }

        // 懒加载内部正则表达式
        fn ensureRegex(self: *Self) !*RegexNew {
            if (self.inner_regex == null) {
                const regex = try self.allocator.create(RegexNew);
                regex.* = try RegexNew.compileWithOptions(self.allocator, folded_pattern, .{
                    .enable_literal_optimization = true,
                    .unicode = analysis.is_unicode,
                    .optimization_level = if (analysis.complexity == .extreme) .default else .aggressive,
                });
                self.inner_regex = regex;
            }
            return self.inner_regex.?;
        }

        pub fn isMatch(self: *Self, input: []const u8) !bool {
            const regex = try self.ensureRegex();
            return regex.isMatch(input);
        }

        pub fn find(self: *Self, input: []const u8) !?RegexNew.Match {
            const regex = try self.ensureRegex();
            return regex.find(input);
        }

        // 获取编译时信息
        pub fn getAnalysis() CompileTimeAnalysis {
            return analysis;
        }

        pub fn getOptimizations() []const CompileTimeOptimizer.OptimizationSuggestion {
            return optimizations;
        }
    };
}

// 辅助函数
fn isQuantifierChar(c: u8) bool {
    return switch (c) {
        '*', '+', '?', '{' => true,
        else => false,
    };
}

fn isQuantifierPreceding(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', ')', ']', '}', '.', '_' => true,
        else => false,
    };
}

fn isValidEscapeChar(c: u8) bool {
    // 特殊字符
    if (c == 'n' or c == 'r' or c == 't' or c == 'f' or c == 'v' or c == 'a' or c == 'e') {
        return true;
    }
    // 字符类
    if (c == 'd' or c == 'D' or c == 'w' or c == 'W' or c == 's' or c == 'S') {
        return true;
    }
    // 边界
    if (c == 'b' or c == 'B') {
        return true;
    }
    // Unicode属性
    if (c == 'p' or c == 'P') {
        return true;
    }
    // 十六进制/Unicode
    if (c == 'x' or c == 'u' or c == 'U') {
        return true;
    }
    // 八进制
    if (c >= '0' and c <= '7') {
        return true;
    }
    // 保留字面量
    if (c == '\\\\' or c == '.' or c == '^' or c == '$' or c == '*' or c == '+' or
        c == '?' or c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}')
    {
        return true;
    }
    // 其他字符直接转义
    return true;
}

// 测试编译时功能
test "compile-time validation" {
    // 有效的正则表达式
    const valid_analysis = comptime blk: {
        var validator = CompileTimeValidator.init("hello");
        break :blk validator.validateSyntax();
    };
    try std.testing.expect(valid_analysis.is_valid);

    // 无效的正则表达式（未闭合的括号）
    const invalid_analysis = comptime blk: {
        var validator = CompileTimeValidator.init("hello(");
        break :blk validator.validateSyntax();
    };
    try std.testing.expect(!invalid_analysis.is_valid);
    try std.testing.expectEqualStrings("Unmatched opening parenthesis", invalid_analysis.error_message.?);
}

test "complexity analysis" {
    // 简单模式
    const simple_analysis = comptime blk: {
        var validator = CompileTimeValidator.init("hello");
        break :blk validator.validateSyntax();
    };
    try std.testing.expectEqual(CompileTimeAnalysis.Complexity.trivial, simple_analysis.complexity);

    // 复杂模式
    const complex_analysis = comptime blk: {
        var validator = CompileTimeValidator.init(@"(a|b|c)*\d+(?:foo|bar){1,3}");
        break :blk validator.validateSyntax();
    };
    try std.testing.expectEqual(CompileTimeAnalysis.Complexity.moderate, complex_analysis.complexity);
}

test "comptime regex wrapper" {
    // 这个测试应该能编译，说明正则表达式在编译时是有效的
    const ComptimeHelloRegex = ComptimeRegex("hello");

    const allocator = std.testing.allocator;
    var regex = try ComptimeHelloRegex.init(allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello world"));
    try std.testing.expect(!(try regex.isMatch("goodbye world")));
}

test "compile-time optimizations" {
    const literal_analysis = comptime blk: {
        var validator = CompileTimeValidator.init("helloworld");
        break :blk validator.validateSyntax();
    };

    const suggestions = CompileTimeOptimizer.getSuggestions("helloworld", literal_analysis);
    try std.testing.expect(suggestions.len > 0);

    // 应该建议使用字面量优化
    try std.testing.expectEqualStrings("literal_fixed_string", suggestions[0].strategy);
    try std.testing.expectEqual(100.0, suggestions[0].expected_improvement);
}
