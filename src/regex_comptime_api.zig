// 集成编译时优化的正则表达式API
// 结合comptime_optimizer提供的零开销优化

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const regex_new = @import("regex_new.zig");
const Match = regex_new.Match;
const MatchOptions = regex_new.MatchOptions;
const MatchIterator = regex_new.MatchIterator;

const comptime_optimizer = @import("comptime_optimizer.zig");
const ComptimeOptimizer = comptime_optimizer.ComptimeOptimizer;
const ComptimeConfig = comptime_optimizer.ComptimeConfig;
const ComptimeAnalysis = comptime_optimizer.ComptimeAnalysis;

const comptime_literals = @import("comptime_literals.zig");
const ComptimeLiteralMatcher = comptime_literals.ComptimeLiteralMatcher;

const comptime_nfa_simplifier = @import("comptime_nfa_simplifier.zig");
const ComptimeNFASimplifier = comptime_nfa_simplifier.ComptimeNFASimplifier;
const SimplificationStrategy = comptime_nfa_simplifier.SimplificationStrategy;

// 编译时优化的正则表达式API
pub fn ComptimeRegex(comptime pattern: []const u8) type {
    return struct {
        const Self = @This();

    // 编译时分析结果
    pub const analysis = comptime blk: {
        var config = ComptimeConfig{};
        var optimizer = ComptimeOptimizer.init(comptime_pattern, config);
        break :blk optimizer.analyze();
    };

    // 编译时字面量分析
    pub const literal_analysis = comptime blk: {
        var analyzer = comptime_literals.ComptimeLiteralAnalyzer.init(comptime_pattern);
        break :blk analyzer.analyze();
    };

    // 编译时优化后的模式
    pub const optimized_pattern = comptime ComptimeOptimizer.foldConstants(comptime_pattern);

    // 编译时优化建议
    pub const optimizations = comptime blk: {
        break :blk comptime_optimizer.ComptimeOptimizer.getSuggestions(comptime_pattern, analysis);
    };

    // 编译时验证
    comptime {
        if (!analysis.is_valid) {
            @compileError(std.fmt.comptimePrint("Invalid regex pattern: {s}", .{
                analysis.error_message orelse "unknown error"
            }));
        }

        if (analysis.complexity == .extreme) {
            std.log.warn("Complex regex pattern may have performance issues: {s}", .{comptime_pattern});
        }
    }

    allocator: Allocator,
    inner_regex: ?*regex_new.Regex = null,
    literal_matcher: ?ComptimeLiteralMatcher(comptime_pattern) = null,

    // 编译时确定的优化策略
    const use_literal_only = comptime analysis.is_literal_only;
    const use_literal_prefix = comptime (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 3);
    const use_aggressive_optimization = comptime (analysis.complexity_score > 15);

    pub fn init(allocator: Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .inner_regex = null,
            .literal_matcher = null,
        };

        // 根据编译时分析决定初始化策略
        if (comptime use_literal_only or comptime use_literal_prefix) {
            self.literal_matcher = try ComptimeLiteralMatcher(comptime_pattern).init(allocator);
        }

        // 初始化标准正则表达式引擎
        const regex = try allocator.create(regex_new.Regex);
        const compile_options = comptime self.getCompileOptions();
        regex.* = try regex_new.Regex.compileWithOptions(allocator, optimized_pattern, compile_options);
        self.inner_regex = regex;

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.inner_regex) |regex| {
            regex.deinit();
            self.allocator.destroy(regex);
        }

        if (self.literal_matcher) |*matcher| {
            matcher.deinit();
        }
    }

    // 快速匹配（使用编译时优化）
    pub fn isMatch(self: *Self, input: []const u8) !bool {
        // 如果是纯字面量，使用快速匹配
        if (comptime use_literal_only) {
            if (self.literal_matcher) |*matcher| {
                return matcher.isMatchLiteral(input);
            }
        }

        // 使用前缀优化进行快速拒绝
        if (comptime use_literal_prefix) {
            if (self.literal_matcher) |*matcher| {
                if (!matcher.isMatchLiteral(input)) {
                    return false;
                }
            }
        }

        // 回退到标准匹配
        return self.inner_regex.?.isMatch(input);
    }

    // 查找匹配（优化版本）
    pub fn find(self: *Self, input: []const u8) !?Match {
        return self.findWithOptions(input, .{});
    }

    // 带选项的查找（使用编译时优化）
    pub fn findWithOptions(self: *Self, input: []const u8, options: MatchOptions) !?Match {
        var optimized_options = options;

        // 应用编译时优化的选项
        if (comptime analysis.is_unicode) {
            optimized_options.unicode = true;
        }

        // 使用字面量匹配进行初步检查
        if (comptime use_literal_only) {
            if (self.literal_matcher) |*matcher| {
                const literal_pos = matcher.findBestMatch(input);
                if (literal_pos == null) {
                    return null;
                }
            }
        }

        return self.inner_regex.?.findWithOptions(input, optimized_options);
    }

    // 从指定位置查找
    pub fn findAt(self: *Self, input: []const u8, start_pos: usize, options: MatchOptions) !?Match {
        // 如果是纯字面量，可以直接使用字符串搜索
        if (comptime use_literal_only) {
            const pos = std.mem.indexOfPos(u8, input, start_pos, comptime_pattern);
            if (pos != null) {
                // 构造匹配结果
                var match = Match{
                    .span = .{
                        .start = pos.?,
                        .end = pos.? + comptime_pattern.len,
                    },
                    .captures = null,
                    .engine_info = .{
                        .engine_type = .literal_fixed_string,
                        .used_unicode = false,
                        .used_literal_optimization = true,
                        .match_time_ns = 0, // 编译时优化，运行时开销极小
                    },
                };
                return match;
            }
            return null;
        }

        return self.inner_regex.?.findAt(input, start_pos, options);
    }

    // 获取匹配迭代器
    pub fn iterator(self: *Self, input: []const u8) MatchIterator {
        return self.inner_regex.?.iterator(input);
    }

    // 获取带选项的匹配迭代器
    pub fn iteratorWithOptions(self: *Self, input: []const u8, options: MatchOptions) MatchIterator {
        return self.inner_regex.?.iteratorWithOptions(input, options);
    }

    // 替换操作
    pub fn replace(self: *Self, input: []const u8, replacement: []const u8, allocator: Allocator) ![]u8 {
        return self.inner_regex.?.replace(input, replacement, allocator);
    }

    // 带选项的替换操作
    pub fn replaceWithOptions(self: *Self, input: []const u8, replacement: []const u8, options: MatchOptions, allocator: Allocator) ![]u8 {
        return self.inner_regex.?.replaceWithOptions(input, replacement, options, allocator);
    }

    // 分割操作
    pub fn split(self: *Self, input: []const u8, allocator: Allocator) ![]const []const u8 {
        return self.inner_regex.?.split(input, allocator);
    }

    // 获取编译时分析信息
    pub fn getAnalysis() ComptimeAnalysis {
        return analysis;
    }

    // 获取字面量分析信息
    pub fn getLiteralAnalysis() comptime_literals.ComptimeLiteralAnalysis {
        return literal_analysis;
    }

    // 获取优化建议
    pub fn getOptimizations() []const ComptimeAnalysis.OptimizationSuggestion {
        return optimizations;
    }

    // 获取优化后的模式
    pub fn getOptimizedPattern() []const u8 {
        return optimized_pattern;
    }

    // 获取性能统计信息
    pub fn getPerformanceStats() PerformanceStats {
        return PerformanceStats{
            .is_literal_only = comptime use_literal_only,
            .uses_literal_prefix = comptime use_literal_prefix,
            .complexity_score = comptime analysis.complexity_score,
            .estimated_instructions = comptime analysis.estimated_instructions,
            .estimated_memory_bytes = comptime analysis.estimated_memory_bytes,
            .optimization_strategies_count = comptime optimizations.len,
        };
    }

    // 获取编译时确定的编译选项
    fn getCompileOptions() comptime regex_new.CompileOptions {
        return .{
            .enable_literal_optimization = comptime analysis.literal_prefix != null,
            .unicode = comptime analysis.is_unicode,
            .optimization_level = if (comptime use_aggressive_optimization)
                .aggressive else .basic,
            .enable_unicode_categories = comptime analysis.is_unicode,
            .enable_dot_matches_newline = true,
            .enable_multiline = true,
        };
    }

    // 性能统计信息
    const PerformanceStats = struct {
        is_literal_only: bool,
        uses_literal_prefix: bool,
        complexity_score: u32,
        estimated_instructions: usize,
        estimated_memory_bytes: usize,
        optimization_strategies_count: usize,
    };

    // 便捷函数：创建编译时优化的正则表达式
    pub fn compile(allocator: Allocator) !Self {
        return Self.init(allocator);
    }

    // 便捷函数：带配置的编译
    pub fn compileWithOptions(allocator: Allocator, comptime config: ComptimeConfig) !Self {
        // 注意：配置在编译时应用，但API结构保持一致
        return Self.init(allocator);
    }
};

// Comptime regex factory
pub fn ComptimeRegexFactory(comptime pattern: []const u8, comptime config: ComptimeConfig) type {
    return struct {
        const RegexType = ComptimeRegex(pattern);

        pub fn create(allocator: Allocator) !RegexType.Self {
            return RegexType.init(allocator);
        }

        // 编译时访问分析结果
        pub fn getAnalysis() ComptimeAnalysis {
            return RegexType.analysis;
        }

        pub fn getOptimizedPattern() []const u8 {
            return RegexType.optimized_pattern;
        }

        pub fn getPerformanceStats() PerformanceStats {
            return PerformanceStats{
                .is_literal_only = comptime RegexType.use_literal_only,
                .uses_literal_prefix = comptime RegexType.use_literal_prefix,
                .complexity_score = comptime RegexType.analysis.complexity_score,
                .estimated_instructions = comptime RegexType.analysis.estimated_instructions,
                .estimated_memory_bytes = comptime RegexType.analysis.estimated_memory_bytes,
                .optimization_strategies_count = comptime RegexType.optimizations.len,
            };
        }
    }
}

// 编译时批量优化器
pub const ComptimeBatchOptimizer = struct {
    const Self = @This();

    // 批量分析多个模式
    pub fn analyzePatterns(comptime patterns: []const []const u8) []const PatternAnalysis {
        comptime {
            var analyses: [patterns.len]PatternAnalysis = undefined;

            for (patterns, 0..) |pattern, i| {
                var config = ComptimeConfig{};
                var optimizer = ComptimeOptimizer.init(pattern, config);
                analyses[i] = PatternAnalysis{
                    .pattern = pattern,
                    .analysis = optimizer.analyze(),
                };
            }

            return &analyses;
        }
    }

    // 找到最优的编译时优化策略
    pub fn recommendOptimizationStrategy(comptime patterns: []const []const u8) OptimizationStrategy {
        comptime {
            var total_score: f32 = 0;
            var max_complexity: u32 = 0;
            var has_unicode = false;

            for (patterns) |pattern| {
                var config = ComptimeConfig{};
                var optimizer = ComptimeOptimizer.init(pattern, config);
                const analysis = optimizer.analyze();

                total_score += @as(f32, @floatFromInt(analysis.complexity_score));
                max_complexity = @max(max_complexity, analysis.complexity_score);
                has_unicode = has_unicode or analysis.is_unicode;
            }

            const avg_score = total_score / @as(f32, @floatFromInt(patterns.len));

            return if (avg_score < 5)
                .literal_only
            else if (avg_score < 15 and !has_unicode)
                .basic_optimization
            else if (max_complexity < 30)
                .aggressive_optimization
            else
                .extreme_optimization;
        }
    }
};

// 模式分析结果
pub const PatternAnalysis = struct {
    pattern: []const u8,
    analysis: ComptimeAnalysis,
};

// 批量优化策略
pub const OptimizationStrategy = enum {
    literal_only,
    basic_optimization,
    aggressive_optimization,
    extreme_optimization,
};

// 测试
test "comptime regex API basic" {
    const TestRegex = ComptimeRegex("hello");

    const allocator = std.testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello world"));
    try std.testing.expect(!(try regex.isMatch("goodbye world")));

    // 检查编译时分析
    const analysis = TestRegex.analysis;
    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(analysis.is_literal_only);

    // 检查性能统计
    const stats = TestRegex.getPerformanceStats();
    try std.testing.expect(stats.is_literal_only);
}

test "comptime regex API with complex pattern" {
    const TestRegex = ComptimeRegex(@"\d+\s*\w+");

    const allocator = std.testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("123   test"));
    try std.testing.expect(!(try regex.isMatch("abc def")));

    const analysis = TestRegex.analysis;
    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(!analysis.is_literal_only);
}

test "comptime regex API find method" {
    const TestRegex = ComptimeRegex("hello");

    const allocator = std.testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    const match = try regex.find("hello world");
    try std.testing.expect(match != null);
    try std.testing.expectEqualStrings("hello", match.?.text("hello world"));

    // 检查引擎信息
    try std.testing.expectEqual(Match.EngineType.literal_fixed_string, match.?.engine_info.engine_type);
}

test "comptime regex factory" {
    const factory = ComptimeRegexFactory("test", .{});

    const allocator = std.testing.allocator;
    var regex = try factory.create(allocator);
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("test string"));

    // 编译时访问
    const analysis = factory.getAnalysis();
    try std.testing.expect(analysis.is_valid);
}

test "comptime batch optimizer" {
    const patterns = [_][]const u8{
        "hello",
        @"\d+",
        @"[a-z]+",
    };

    const analyses = ComptimeBatchOptimizer.analyzePatterns(&patterns);
    try std.testing.expectEqual(patterns.len, analyses.len);

    for (analyses) |analysis| {
        try std.testing.expect(analysis.analysis.is_valid);
    }

    const strategy = ComptimeBatchOptimizer.recommendOptimizationStrategy(&patterns);
    try std.testing.expect(strategy == .basic_optimization or strategy == .literal_only);
}

test "comptime regex performance optimization" {
    // 测试字面量优化
    const LiteralRegex = ComptimeRegex("helloworld");

    const allocator = std.testing.allocator;
    var regex = try LiteralRegex.init(allocator);
    defer regex.deinit();

    const start_time = std.time.nanoTimestamp();
    const result = try regex.isMatch("helloworld123");
    const end_time = std.time.nanoTimestamp();

    try std.testing.expect(result);
    try std.testing.expect(end_time - start_time < 1_000_000); // 应该很快

    const stats = regex.getPerformanceStats();
    try std.testing.expect(stats.is_literal_only);
}

test "comptime regex replace operation" {
    const TestRegex = ComptimeRegex(@"\d+");

    const allocator = std.testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    const result = try regex.replace("test 123 numbers 456", "NUM", allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("test NUM numbers NUM", result);
}