// 编译时正则表达式优化器
// 提供零开销的编译时优化和验证

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const compile = @import("compile.zig");
const Program = compile.Program;
const literal_engine = @import("literal_engine.zig");
const LiteralEngine = literal_engine.LiteralEngine;
const parser = @import("parse.zig");
const Expr = parser.Expr;

// 编译时优化级别
pub const OptimizationLevel = enum {
    none, // 无优化
    basic, // 基本优化
    aggressive, // 激进优化
    extreme, // 极端优化（可能增加编译时间）
};

// 编译时优化配置
pub const ComptimeConfig = struct {
    level: OptimizationLevel = .aggressive,
    enable_literal_extraction: bool = true,
    enable_nfa_simplification: bool = true,
    enable_constant_folding: bool = true,
    enable_dead_code_elimination: bool = true,
    max_complexity_score: u32 = 100,
    enable_warnings: bool = true,
    fail_on_complex_patterns: bool = false,
};

// 编译时分析结果
pub const ComptimeAnalysis = struct {
    is_valid: bool = true,
    error_message: ?[]const u8 = null,

    // 复杂度分析
    complexity: Complexity = .simple,
    complexity_score: u32 = 0,

    // 性能特征
    is_anchored: bool = false,
    is_unicode: bool = false,
    has_captures: bool = false,
    capture_count: usize = 0,

    // 优化机会
    literal_prefix: ?[]const u8 = null,
    literal_suffix: ?[]const u8 = null,
    is_literal_only: bool = false,
    has_repeating_patterns: bool = false,

    // 内存估算
    estimated_instructions: usize = 0,
    estimated_memory_bytes: usize = 0,
    estimated_stack_depth: usize = 0,

    // 优化建议
    optimizations: []const OptimizationSuggestion = &.{},

    pub const Complexity = enum {
        trivial, // 简单字面量
        simple, // 简单正则
        moderate, // 中等复杂度
        complex, // 复杂正则
        extreme, // 极端复杂
    };

    pub const OptimizationSuggestion = struct {
        strategy: Strategy,
        reason: []const u8,
        expected_improvement: f32,
        memory_saving: f32,
        confidence: f32, // 0.0 - 1.0
    };

    pub const Strategy = enum {
        literal_string, // 使用字面量字符串匹配
        literal_prefix, // 使用字面量前缀优化
        boyer_moore, // 使用Boyer-Moore算法
        simplified_nfa, // 简化NFA
        dfa_precompiled, // 预编译DFA
        memoized_matches, // 记忆化匹配
        early_rejection, // 早期拒绝
    };
};

// 编译时优化器
pub const ComptimeOptimizer = struct {
    const Self = @This();

    config: ComptimeConfig,
    pattern: []const u8,

    pub fn init(pattern: []const u8, config: ComptimeConfig) Self {
        return Self{
            .config = config,
            .pattern = pattern,
        };
    }

    // 执行完整的编译时分析
    pub fn analyze(self: *const Self) ComptimeAnalysis {
        var analysis = ComptimeAnalysis{};

        // 1. 语法验证
        if (!self.validateSyntax(&analysis)) {
            return analysis;
        }

        // 2. 复杂度分析
        self.analyzeComplexity(&analysis);

        // 3. 字面量分析
        if (self.config.enable_literal_extraction) {
            self.analyzeLiterals(&analysis);
        }

        // 4. 优化建议生成
        self.generateOptimizations(&analysis);

        // 5. 资源估算
        self.estimateResources(&analysis);

        return analysis;
    }

    // 语法验证
    fn validateSyntax(self: *const Self, analysis: *ComptimeAnalysis) bool {
        if (self.pattern.len == 0) {
            analysis.is_valid = false;
            analysis.error_message = "Empty pattern";
            return false;
        }

        var paren_count: i32 = 0;
        var bracket_count: i32 = 0;
        var brace_count: i32 = 0;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '(' => paren_count += 1,
                ')' => {
                    paren_count -= 1;
                    if (paren_count < 0) {
                        analysis.is_valid = false;
                        analysis.error_message = "Unmatched closing parenthesis";
                        return false;
                    }
                },
                '[' => bracket_count += 1,
                ']' => {
                    bracket_count -= 1;
                    if (bracket_count < 0) {
                        analysis.is_valid = false;
                        analysis.error_message = "Unmatched closing bracket";
                        return false;
                    }
                },
                '{' => {
                    if (i > 0 and isQuantifierPreceding(self.pattern[i - 1])) {
                        brace_count += 1;
                    }
                },
                '}' => {
                    if (brace_count > 0) {
                        brace_count -= 1;
                    }
                },
                '\\' => {
                    if (i + 1 >= self.pattern.len) {
                        analysis.is_valid = false;
                        analysis.error_message = "Dangling escape character";
                        return false;
                    }

                    const next_char = self.pattern[i + 1];
                    if (!isValidEscapeChar(next_char)) {
                        analysis.is_valid = false;
                        analysis.error_message = "Invalid escape sequence";
                        return false;
                    }
                },
                '*', '+', '?' => {
                    if (i > 0 and isQuantifierChar(self.pattern[i - 1])) {
                        analysis.is_valid = false;
                        analysis.error_message = "Repeated quantifier";
                        return false;
                    }
                },
                else => {},
            }
        }

        if (paren_count != 0) {
            analysis.is_valid = false;
            analysis.error_message = "Unmatched parenthesis";
            return false;
        }

        if (bracket_count != 0) {
            analysis.is_valid = false;
            analysis.error_message = "Unmatched bracket";
            return false;
        }

        return true;
    }

    // 复杂度分析
    fn analyzeComplexity(self: *const Self, analysis: *ComptimeAnalysis) void {
        var score: u32 = 0;
        var captures: usize = 0;
        var has_unicode = false;

        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '(' => {
                    if (i + 1 < self.pattern.len and self.pattern[i + 1] != '?') {
                        captures += 1;
                        score += 2;
                    } else {
                        score += 1;
                    }
                },
                '*', '+', '?' => score += 1,
                '{' => score += 3,
                '[' => score += 2,
                '\\' => {
                    if (i + 1 < self.pattern.len) {
                        const next = self.pattern[i + 1];
                        switch (next) {
                            'd', 'D', 'w', 'W', 's', 'S' => score += 1,
                            'b', 'B' => score += 1,
                            'p', 'P' => {
                                score += 5;
                                has_unicode = true;
                            },
                            'u', 'U' => has_unicode = true,
                            else => {},
                        }
                    }
                },
                '^', '$' => score += 1,
                '|' => score += 2,
                '.' => score += 1,
                else => {
                    if (c >= 128) has_unicode = true;
                },
            }
        }

        analysis.complexity_score = score;
        analysis.has_captures = captures > 0;
        analysis.capture_count = captures;
        analysis.is_unicode = has_unicode;

        // 检查锚定
        if (self.pattern.len > 0 and self.pattern[0] == '^') {
            analysis.is_anchored = true;
        }

        // 确定复杂度等级
        analysis.complexity = if (score <= 2)
            .trivial
        else if (score <= 10)
            .simple
        else if (score <= 25)
            .moderate
        else if (score <= 50)
            .complex
        else
            .extreme;

        // 复杂度警告
        if (self.config.enable_warnings) {
            if (score > self.config.max_complexity_score) {
                if (self.config.fail_on_complex_patterns) {
                    analysis.is_valid = false;
                    analysis.error_message = "Pattern exceeds maximum complexity score";
                }
            }
        }
    }

    // 字面量分析
    fn analyzeLiterals(self: *const Self, analysis: *ComptimeAnalysis) void {
        // 寻找字面量前缀
        var prefix_len: usize = 0;

        for (self.pattern) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', ' ', '_', '-', '.' => {
                    prefix_len += 1;
                },
                '\\', '(', ')', '[', ']', '{', '}', '*', '+', '?', '^', '$', '|' => {
                    break;
                },
                else => {
                    if (c >= 128) break;
                    prefix_len += 1;
                },
            }
        }

        if (prefix_len > 0) {
            analysis.literal_prefix = self.pattern[0..prefix_len];
        }

        // 检查是否是纯字面量
        if (prefix_len == self.pattern.len) {
            analysis.is_literal_only = true;
            analysis.complexity = .trivial;
        }

        // 寻找字面量后缀
        if (!analysis.is_literal_only) {
            var suffix_start = self.pattern.len;
            while (suffix_start > 0) {
                suffix_start -= 1;
                const c = self.pattern[suffix_start];
                switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', ' ', '_', '-', '.' => {},
                    '\\', '(', ')', '[', ']', '{', '}', '*', '+', '?', '^', '$', '|' => {
                        break;
                    },
                    else => {
                        if (c >= 128) break;
                    },
                }
            }

            if (suffix_start < self.pattern.len - 1) {
                analysis.literal_suffix = self.pattern[suffix_start + 1 ..];
            }
        }

        // 检查重复模式
        analysis.has_repeating_patterns = self.detectRepeatingPatterns();
    }

    // 检测重复模式
    fn detectRepeatingPatterns(self: *const Self) bool {
        // 简单的重复模式检测
        if (self.pattern.len < 4) return false;

        // 检查像 (a)+, (a)*, a{2,} 这样的模式
        for (self.pattern, 0..) |c, i| {
            if (c == '(' and i + 2 < self.pattern.len) {
                const next_char = self.pattern[i + 1];
                if (next_char != '?' and i + 3 < self.pattern.len) {
                    const closer = std.mem.indexOfScalarPos(u8, self.pattern, i + 2, ')');
                    if (closer != null and closer.? + 1 < self.pattern.len) {
                        const quantifier = self.pattern[closer.? + 1];
                        if (quantifier == '*' or quantifier == '+' or quantifier == '{') {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    // 生成优化建议
    fn generateOptimizations(self: *const Self, analysis: *ComptimeAnalysis) void {
        var suggestions: [8]ComptimeAnalysis.OptimizationSuggestion = undefined;
        var count: usize = 0;

        // 字面量优化
        if (analysis.is_literal_only and self.pattern.len >= 2) {
            suggestions[count] = .{
                .strategy = .literal_string,
                .reason = "Pattern is a literal string",
                .expected_improvement = 100.0,
                .memory_saving = 95.0,
                .confidence = 1.0,
            };
            count += 1;
        }

        // 字面量前缀优化
        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 3) {
            suggestions[count] = .{
                .strategy = .literal_prefix,
                .reason = "Literal prefix found for quick rejection",
                .expected_improvement = 15.0,
                .memory_saving = 10.0,
                .confidence = 0.9,
            };
            count += 1;
        }

        // Boyer-Moore优化
        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 8) {
            suggestions[count] = .{
                .strategy = .boyer_moore,
                .reason = "Long pattern suitable for Boyer-Moore algorithm",
                .expected_improvement = 30.0,
                .memory_saving = 15.0,
                .confidence = 0.8,
            };
            count += 1;
        }

        // NFA简化
        if (analysis.complexity_score >= 15) {
            suggestions[count] = .{
                .strategy = .simplified_nfa,
                .reason = "Complex pattern can benefit from NFA simplification",
                .expected_improvement = 10.0,
                .memory_saving = 20.0,
                .confidence = 0.7,
            };
            count += 1;
        }

        // DFA预编译
        if (analysis.complexity == .simple or analysis.complexity == .moderate) {
            suggestions[count] = .{
                .strategy = .dfa_precompiled,
                .reason = "Simple pattern suitable for DFA compilation",
                .expected_improvement = 20.0,
                .memory_saving = -5.0, // DFA使用更多内存
                .confidence = 0.6,
            };
            count += 1;
        }

        // 早期拒绝
        if (analysis.literal_prefix != null) {
            suggestions[count] = .{
                .strategy = .early_rejection,
                .reason = "Quick rejection based on literal prefix",
                .expected_improvement = 5.0,
                .memory_saving = 0.0,
                .confidence = 0.95,
            };
            count += 1;
        }

        // 记忆化匹配
        if (analysis.has_repeating_patterns) {
            suggestions[count] = .{
                .strategy = .memoized_matches,
                .reason = "Repeating patterns can benefit from memoization",
                .expected_improvement = 8.0,
                .memory_saving = -10.0,
                .confidence = 0.5,
            };
            count += 1;
        }

        // 复杂模式警告
        if (analysis.complexity == .extreme) {
            suggestions[count] = .{
                .strategy = .simplified_nfa,
                .reason = "Pattern is extremely complex, consider simplification",
                .expected_improvement = 0.0,
                .memory_saving = 0.0,
                .confidence = 0.3,
            };
            count += 1;
        }

        // 复制建议到分析结果
        const arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const suggestions_slice = allocator.alloc(ComptimeAnalysis.OptimizationSuggestion, count) catch return;
        @memcpy(suggestions_slice, suggestions[0..count]);

        analysis.optimizations = suggestions_slice;
    }

    // 资源估算
    fn estimateResources(self: *const Self, analysis: *ComptimeAnalysis) void {
        // 指令数量估算
        analysis.estimated_instructions = @max(1, analysis.complexity_score * 2);

        // 内存估算
        analysis.estimated_memory_bytes = analysis.estimated_instructions * @sizeOf(compile.Instruction);

        // 栈深度估算（基于嵌套深度）
        var max_depth: usize = 0;
        var current_depth: usize = 0;

        for (self.pattern) |c| {
            switch (c) {
                '(' => {
                    current_depth += 1;
                    max_depth = @max(max_depth, current_depth);
                },
                ')' => {
                    if (current_depth > 0) current_depth -= 1;
                },
                else => {},
            }
        }

        analysis.estimated_stack_depth = max_depth + 5; // 缓冲区
    }

    // 编译时常量折叠
    pub fn foldConstants(pattern: []const u8) []const u8 {
        // 实现常量折叠优化
        var result = std.ArrayList(u8).init(std.heap.page_allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];
            switch (c) {
                '\\' => {
                    if (i + 1 < pattern.len) {
                        const next = pattern[i + 1];
                        // 处理可折叠的转义序列
                        switch (next) {
                            'n' => {
                                result.append('\n') catch break;
                                i += 2;
                                continue;
                            },
                            'r' => {
                                result.append('\r') catch break;
                                i += 2;
                                continue;
                            },
                            't' => {
                                result.append('\t') catch break;
                                i += 2;
                                continue;
                            },
                            else => {
                                // 保留其他转义序列
                                result.append('\\') catch break;
                                result.append(next) catch break;
                                i += 2;
                                continue;
                            },
                        }
                    }
                },
                // 移除非必要的分组
                '(', ')' => {
                    // 简化：暂时保留所有括号
                    result.append(c) catch break;
                },
                else => {
                    result.append(c) catch break;
                },
            }
            i += 1;
        }

        return result.toOwnedSlice() catch pattern;
    }
};

// 编译时正则表达式包装器
pub fn ComptimeRegex(comptime pattern: []const u8, comptime config: ComptimeConfig) type {
    return struct {
        const Self = @This();

        // 编译时分析
        pub const analysis = blk: {
            var optimizer = ComptimeOptimizer.init(pattern, config);
            break :blk optimizer.analyze();
        };

        // 编译时优化后的模式
        pub const optimized_pattern = ComptimeOptimizer.foldConstants(pattern);

        // 编译时验证
        comptime {
            if (!analysis.is_valid) {
                @compileError(std.fmt.comptimePrint("Invalid regex pattern: {s}", .{analysis.error_message orelse "unknown error"}));
            }

            if (config.enable_warnings and analysis.complexity == .extreme) {
                @compileLog("Warning: Complex regex pattern may have performance issues");
            }
        }

        allocator: Allocator,
        inner: ?*InnerRegex = null,

        const InnerRegex = @import("regex_new.zig").Regex;

        pub fn init(allocator: Allocator) !Self {
            return Self{
                .allocator = allocator,
                .inner = null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.inner) |regex| {
                regex.deinit();
                self.allocator.destroy(regex);
            }
        }

        fn ensureInner(self: *Self) !*InnerRegex {
            if (self.inner == null) {
                const regex = try self.allocator.create(InnerRegex);
                regex.* = try InnerRegex.compileWithOptions(self.allocator, optimized_pattern, .{
                    .enable_literal_optimization = config.enable_literal_extraction,
                    .unicode = analysis.is_unicode,
                    .optimization_level = switch (config.level) {
                        .none => .none,
                        .basic => .basic,
                        .aggressive, .extreme => .aggressive,
                    },
                });
                self.inner = regex;
            }
            return self.inner.?;
        }

        pub fn isMatch(self: *Self, input: []const u8) !bool {
            const regex = try self.ensureInner();
            return regex.isMatch(input);
        }

        pub fn find(self: *Self, input: []const u8) !?InnerRegex.Match {
            const regex = try self.ensureInner();
            return regex.find(input);
        }

        // 获取编译时信息
        pub fn getAnalysis() ComptimeAnalysis {
            return analysis;
        }

        pub fn getOptimizedPattern() []const u8 {
            return optimized_pattern;
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
    return switch (c) {
        'n', 'r', 't', 'f', 'v', 'a', 'e', 'd', 'D', 'w', 'W', 's', 'S', 'b', 'B', 'p', 'P', 'x', 'u', 'U', '0'...'7', '\\', '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
    };
}

// 测试
test "comptime optimizer basic analysis" {
    const config = ComptimeConfig{};
    const analysis = blk: {
        var optimizer = ComptimeOptimizer.init("hello", config);
        break :blk optimizer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expectEqual(ComptimeAnalysis.Complexity.trivial, analysis.complexity);
    try std.testing.expect(analysis.is_literal_only);
}

test "comptime optimizer complex pattern" {
    const config = ComptimeConfig{};
    const analysis = blk: {
        var optimizer = ComptimeOptimizer.init("(a|b|c)*\\\\d+(?:foo|bar){1,3}", config);
        break :blk optimizer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(analysis.complexity == .moderate or analysis.complexity == .complex);
    try std.testing.expect(analysis.has_captures);
}

test "comptime regex wrapper" {
    const config = ComptimeConfig{};
    const TestRegex = ComptimeRegex("hello", config);

    const allocator = std.testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello world"));
    try std.testing.expect(!(try regex.isMatch("goodbye world")));
}

test "comptime optimizer suggestions" {
    const config = ComptimeConfig{};
    const analysis = blk: {
        var optimizer = ComptimeOptimizer.init("helloworld123", config);
        break :blk optimizer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(analysis.is_literal_only);
    try std.testing.expect(analysis.optimizations.len > 0);

    // 应该有字面量优化建议
    var found_literal_suggestion = false;
    for (analysis.optimizations) |opt| {
        if (opt.strategy == .literal_string) {
            found_literal_suggestion = true;
            break;
        }
    }
    try std.testing.expect(found_literal_suggestion);
}
