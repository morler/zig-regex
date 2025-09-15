// 编译时字面量提取和优化
// 提供零开销的字面量分析和优化

const std = @import("std");
const Allocator = std.mem.Allocator;

const literal_extractor = @import("literal_extractor.zig");
const LiteralExtractor = literal_extractor.LiteralExtractor;
const LiteralCandidate = literal_extractor.LiteralCandidate;
const LiteralStrategy = literal_extractor.LiteralStrategy;
const boyer_moore = @import("boyer_moore.zig");
const BoyerMoore = boyer_moore.BoyerMoore;

// 编译时字面量分析器
pub const ComptimeLiteralAnalyzer = struct {
    const Self = @This();

    pattern: []const u8,

    pub fn init(pattern: []const u8) Self {
        return Self{
            .pattern = pattern,
        };
    }

    // 执行编译时字面量分析
    pub fn analyze(self: *const Self) ComptimeLiteralAnalysis {
        var analysis = ComptimeLiteralAnalysis{};

        // 1. 基本字面量提取
        self.extractBasicLiterals(&analysis);

        // 2. 前缀和后缀分析
        self.analyzePrefixSuffix(&analysis);

        // 3. 重复模式检测
        self.detectRepeatedPatterns(&analysis);

        // 4. 优化策略确定
        self.determineOptimizationStrategy(&analysis);

        // 5. 性能评估
        self.evaluatePerformance(&analysis);

        return analysis;
    }

    // 提取基本字面量
    fn extractBasicLiterals(self: *const Self, analysis: *ComptimeLiteralAnalysis) void {
        var i: usize = 0;
        var current_literal = std.ArrayList(u8).init(std.heap.page_allocator);
        defer current_literal.deinit();

        while (i < self.pattern.len) {
            const c = self.pattern[i];

            switch (c) {
                '\\' => {
                    // 处理转义序列
                    if (i + 1 < self.pattern.len) {
                        const next = self.pattern[i + 1];
                        const literal_char = self.getLiteralFromEscape(next);

                        if (literal_char != null) {
                            current_literal.append(literal_char.?) catch {};
                            i += 2;
                            continue;
                        } else {
                            // 非字面量转义序列，结束当前字面量
                            self.finishCurrentLiteral(&current_literal, analysis);
                            i += 2;
                            continue;
                        }
                    }
                },
                '(', ')', '[', ']', '{', '}', '*', '+', '?', '^', '$', '|' => {
                    // 特殊字符，结束当前字面量
                    self.finishCurrentLiteral(&current_literal, analysis);
                    i += 1;
                    continue;
                },
                'a'...'z', 'A'...'Z', '0'...'9', ' ', '_', '-', '.', '!', '@', '#', '$', '%', '&', '=', ';', ':', ',', '<', '>', '/', '\\', '\'', '\'' => {
                    // 字面量字符
                    current_literal.append(c) catch {};
                },
                else => {
                    // 其他字符，如果ASCII且可打印则视为字面量
                    if (c >= 32 and c <= 126) {
                        current_literal.append(c) catch {};
                    } else {
                        // 非ASCII字符，结束当前字面量
                        self.finishCurrentLiteral(&current_literal, analysis);
                    }
                },
            }

            i += 1;
        }

        // 完成最后一个字面量
        self.finishCurrentLiteral(&current_literal, analysis);
    }

    // 分析前缀和后缀
    fn analyzePrefixSuffix(self: *const Self, analysis: *ComptimeLiteralAnalysis) void {
        if (analysis.literals.len == 0) return;

        // 找最长的字面量作为前缀候选
        var best_prefix: ?[]const u8 = null;
        var best_prefix_len: usize = 0;

        for (analysis.literals) |literal| {
            if (literal.len > best_prefix_len) {
                best_prefix_len = literal.len;
                best_prefix = literal;
            }
        }

        if (best_prefix != null) {
            analysis.longest_literal = best_prefix;
            analysis.literal_prefix = best_prefix;
        }

        // 检查是否可以作为前缀（必须出现在模式开始）
        if (best_prefix != null) {
            const prefix = best_prefix.?;
            if (self.pattern.len >= prefix.len) {
                const pattern_start = self.pattern[0..prefix.len];
                if (std.mem.eql(u8, pattern_start, prefix)) {
                    analysis.is_prefix_at_start = true;
                }
            }
        }

        // 后缀分析
        var best_suffix: ?[]const u8 = null;
        var best_suffix_len: usize = 0;

        for (analysis.literals) |literal| {
            if (literal.len > best_suffix_len) {
                best_suffix_len = literal.len;
                best_suffix = literal;
            }
        }

        if (best_suffix != null) {
            analysis.literal_suffix = best_suffix;

            // 检查是否可以作为后缀
            const suffix = best_suffix.?;
            if (self.pattern.len >= suffix.len) {
                const pattern_end = self.pattern[self.pattern.len - suffix.len ..];
                if (std.mem.eql(u8, pattern_end, suffix)) {
                    analysis.is_suffix_at_end = true;
                }
            }
        }
    }

    // 检测重复模式
    fn detectRepeatedPatterns(self: *const Self, analysis: *ComptimeLiteralAnalysis) void {
        // 检测连续重复的字面量
        for (analysis.literals, 0..) |literal, i| {
            if (literal.len >= 2) {
                // 检查是否在模式中重复出现
                var count: usize = 0;
                var search_start: usize = 0;

                while (search_start < self.pattern.len) {
                    const found = std.mem.indexOfPos(u8, self.pattern, search_start, literal);
                    if (found != null) {
                        count += 1;
                        search_start = found.? + literal.len;
                    } else {
                        break;
                    }
                }

                if (count >= 2) {
                    analysis.has_repeated_patterns = true;
                    analysis.repeated_patterns = analysis.repeated_patterns ++ .{literal};
                }
            }
        }

        // 检测量词模式
        for (self.pattern, 0..) |c, i| {
            if (c == '*' or c == '+' or c == '?') {
                if (i > 0) {
                    const prev_char = self.pattern[i - 1];
                    if (prev_char >= 'a' and prev_char <= 'z' or prev_char >= 'A' and prev_char <= 'Z' or prev_char >= '0' and prev_char <= '9') {
                        analysis.has_quantified_literals = true;
                    }
                }
            }
        }
    }

    // 确定优化策略
    fn determineOptimizationStrategy(self: *const Self, analysis: *ComptimeLiteralAnalysis) void {
        var strategies: [4]OptimizationStrategy = undefined;
        var strategy_count: usize = 0;

        // 纯字面量匹配
        if (analysis.is_literal_only and analysis.literal_prefix != null) {
            strategies[strategy_count] = .literal_string;
            strategy_count += 1;
        }

        // 前缀优化
        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 3) {
            strategies[strategy_count] = .prefix_search;
            strategy_count += 1;
        }

        // Boyer-Moore算法
        if (analysis.longest_literal != null and analysis.longest_literal.?.len >= 5) {
            strategies[strategy_count] = .boyer_moore;
            strategy_count += 1;
        }

        // 多模式匹配
        if (analysis.literals.len >= 2) {
            strategies[strategy_count] = .multi_pattern;
            strategy_count += 1;
        }

        // 复制策略
        const arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const strategies_slice = allocator.alloc(OptimizationStrategy, strategy_count) catch return;
        @memcpy(strategies_slice, strategies[0..strategy_count]);

        analysis.optimization_strategies = strategies_slice;

        // 确定主要策略
        if (strategy_count > 0) {
            analysis.primary_strategy = strategies[0];
        }
    }

    // 性能评估
    fn evaluatePerformance(self: *const Self, analysis: *ComptimeLiteralAnalysis) void {
        var score: f32 = 0;

        // 字面量长度得分
        if (analysis.longest_literal) |literal| {
            score += @as(f32, @floatFromInt(literal.len)) * 2.0;
        }

        // 前缀位置得分
        if (analysis.is_prefix_at_start) {
            score += 10.0;
        }

        // 重复模式得分
        if (analysis.has_repeated_patterns) {
            score += 5.0;
        }

        // 字面量数量得分
        score += @as(f32, @floatFromInt(analysis.literals.len)) * 1.5;

        // 优化策略得分
        for (analysis.optimization_strategies) |strategy| {
            switch (strategy) {
                .literal_string => score += 20.0,
                .prefix_search => score += 8.0,
                .boyer_moore => score += 15.0,
                .multi_pattern => score += 10.0,
            }
        }

        analysis.optimization_score = score;

        // 评估预期性能提升
        if (analysis.is_literal_only) {
            analysis.expected_speedup = 100.0; // 100倍提升
            analysis.expected_memory_saving = 95.0; // 95%内存节省
        } else if (analysis.is_prefix_at_start) {
            analysis.expected_speedup = 15.0;
            analysis.expected_memory_saving = 10.0;
        } else if (analysis.primary_strategy == .boyer_moore) {
            analysis.expected_speedup = 25.0;
            analysis.expected_memory_saving = 5.0;
        } else {
            analysis.expected_speedup = 5.0;
            analysis.expected_memory_saving = 0.0;
        }
    }

    // 完成当前字面量
    fn finishCurrentLiteral(self: *const Self, current_literal: *std.ArrayList(u8), analysis: *ComptimeLiteralAnalysis) void {
        if (current_literal.items.len > 0) {
            const literal = current_literal.toOwnedSlice() catch return;

            // 添加到字面量列表
            const arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const new_literals = allocator.alloc([]const u8, analysis.literals.len + 1) catch {
                std.heap.page_allocator.free(literal);
                return;
            };

            @memcpy(new_literals[0..analysis.literals.len], analysis.literals);
            new_literals[analysis.literals.len] = literal;

            analysis.literals = new_literals;
        }
    }

    // 从转义序列获取字面量字符
    fn getLiteralFromEscape(self: *const Self, escape_char: u8) ?u8 {
        return switch (escape_char) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'f' => '\f',
            'v' => '\v',
            'a' => '\a',
            'e' => '\x1B',
            // 可以添加更多字面量转义序列
            else => null,
        };
    }
};

// 编译时字面量分析结果
pub const ComptimeLiteralAnalysis = struct {
    is_valid: bool = true,

    // 字面量信息
    literals: []const []const u8 = &.{},
    longest_literal: ?[]const u8 = null,
    is_literal_only: bool = false,

    // 位置信息
    literal_prefix: ?[]const u8 = null,
    literal_suffix: ?[]const u8 = null,
    is_prefix_at_start: bool = false,
    is_suffix_at_end: bool = false,

    // 模式信息
    has_repeated_patterns: bool = false,
    repeated_patterns: []const []const u8 = &.{},
    has_quantified_literals: bool = false,

    // 优化信息
    optimization_strategies: []const OptimizationStrategy = &.{},
    primary_strategy: ?OptimizationStrategy = null,
    optimization_score: f32 = 0,
    expected_speedup: f32 = 1.0,
    expected_memory_saving: f32 = 0.0,
};

// 优化策略
pub const OptimizationStrategy = enum {
    literal_string,    // 纯字面量匹配
    prefix_search,     // 前缀搜索
    boyer_moore,       // Boyer-Moore算法
    multi_pattern,     // 多模式匹配
};

// 编译时字面量优化器
pub const ComptimeLiteralOptimizer = struct {
    const Self = @This();

    // 优化建议
    pub const OptimizationSuggestion = struct {
        strategy: OptimizationStrategy,
        implementation: []const u8,
        reason: []const u8,
        speedup_factor: f32,
        memory_factor: f32,
        confidence: f32,
    };

    // 获取优化建议
    pub fn getOptimizationSuggestions(analysis: ComptimeLiteralAnalysis) []const OptimizationSuggestion {
        var suggestions: [8]OptimizationSuggestion = undefined;
        var count: usize = 0;

        // 纯字面量优化
        if (analysis.is_literal_only) {
            suggestions[count] = .{
                .strategy = .literal_string,
                .implementation = "Use direct string comparison",
                .reason = "Pattern is a literal string",
                .speedup_factor = 100.0,
                .memory_factor = 0.05,
                .confidence = 1.0,
            };
            count += 1;
        }

        // 前缀优化
        if (analysis.literal_prefix != null and analysis.literal_prefix.?.len >= 3) {
            suggestions[count] = .{
                .strategy = .prefix_search,
                .implementation = "Use prefix search for quick rejection",
                .reason = "Long prefix available for fast rejection",
                .speedup_factor = 15.0,
                .memory_factor = 0.9,
                .confidence = 0.9,
            };
            count += 1;
        }

        // Boyer-Moore优化
        if (analysis.longest_literal != null and analysis.longest_literal.?.len >= 5) {
            suggestions[count] = .{
                .strategy = .boyer_moore,
                .implementation = "Use Boyer-Moore string search algorithm",
                .reason = "Long literal suitable for Boyer-Moore",
                .speedup_factor = 25.0,
                .memory_factor = 0.95,
                .confidence = 0.8,
            };
            count += 1;
        }

        // 多模式优化
        if (analysis.literals.len >= 2) {
            suggestions[count] = .{
                .strategy = .multi_pattern,
                .implementation = "Use multi-pattern search algorithm",
                .reason = "Multiple literals can be searched simultaneously",
                .speedup_factor = 8.0,
                .memory_factor = 0.8,
                .confidence = 0.7,
            };
            count += 1;
        }

        // 复制到返回结果
        const arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const result = allocator.alloc(OptimizationSuggestion, count) catch return &[0]OptimizationSuggestion{};
        @memcpy(result, suggestions[0..count]);

        return result;
    }

    // 编译时字面量匹配器
    pub fn ComptimeLiteralMatcher(comptime pattern: []const u8) type {
        return struct {
            const Self = @This();

            // 编译时分析
            pub const analysis = comptime blk: {
                var analyzer = ComptimeLiteralAnalyzer.init(pattern);
                break :blk analyzer.analyze();
            };

            // 编译时优化建议
            pub const suggestions = comptime blk: {
                break :blk getOptimizationSuggestions(analysis);
            };

            // 编译时验证
            comptime {
                if (!analysis.is_valid) {
                    @compileError("Invalid pattern for literal analysis");
                }

                if (analysis.is_literal_only) {
                    @compileLog("Pattern is literal-only, maximum optimization possible");
                }
            }

            allocator: Allocator,
            boyer_moore: ?BoyerMoore = null,

            pub fn init(allocator: Allocator) !Self {
                var self = Self{
                    .allocator = allocator,
                    .boyer_moore = null,
                };

                // 如果适合，初始化Boyer-Moore
                if (analysis.longest_literal != null and analysis.longest_literal.?.len >= 5) {
                    self.boyer_moore = BoyerMoore.init(allocator, analysis.longest_literal.?) catch null;
                }

                return self;
            }

            pub fn deinit(self: *Self) void {
                if (self.boyer_moore) |*bm| {
                    bm.deinit();
                }
            }

            // 快速匹配（纯字面量）
            pub fn isMatchLiteral(self: *const Self, input: []const u8) bool {
                if (comptime analysis.is_literal_only) {
                    return std.mem.indexOf(u8, input, pattern) != null;
                }

                // 前缀匹配
                if (comptime analysis.is_prefix_at_start and analysis.literal_prefix != null) {
                    if (input.len < analysis.literal_prefix.?.len) {
                        return false;
                    }
                    if (!std.mem.eql(u8, input[0..analysis.literal_prefix.?.len], analysis.literal_prefix.?)) {
                        return false;
                    }
                }

                // Boyer-Moore匹配
                if (self.boyer_moore) |*bm| {
                    return bm.search(input) != null;
                }

                // 回退到标准搜索
                return std.mem.indexOf(u8, input, pattern) != null;
            }

            // 获取最佳匹配位置
            pub fn findBestMatch(self: *const Self, input: []const u8) ?usize {
                if (comptime analysis.is_literal_only) {
                    return std.mem.indexOf(u8, input, pattern);
                }

                if (self.boyer_moore) |*bm| {
                    return bm.search(input);
                }

                return std.mem.indexOf(u8, input, pattern);
            }

            // 获取分析结果
            pub fn getAnalysis() ComptimeLiteralAnalysis {
                return analysis;
            }

            // 获取优化建议
            pub fn getSuggestions() []const OptimizationSuggestion {
                return suggestions;
            }
        };
    }
};

// 测试
test "comptime literal analysis basic" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello");
        break :blk analyzer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(analysis.is_literal_only);
    try std.testing.expect(analysis.literals.len == 1);
    try std.testing.expect(std.mem.eql(u8, analysis.literals[0], "hello"));
}

test "comptime literal analysis with escape sequences" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello\\nworld");
        break :blk analyzer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(!analysis.is_literal_only);
    try std.testing.expect(analysis.literals.len == 2);
}

test "comptime literal analysis prefix detection" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello.*world");
        break :blk analyzer.analyze();
    };

    try std.testing.expect(analysis.is_valid);
    try std.testing.expect(analysis.literal_prefix != null);
    try std.testing.expect(std.mem.eql(u8, analysis.literal_prefix.?, "hello"));
}

test "comptime literal matcher" {
    const TestMatcher = ComptimeLiteralMatcher("hello");

    const allocator = std.testing.allocator;
    var matcher = try TestMatcher.init(allocator);
    defer matcher.deinit();

    try std.testing.expect(matcher.isMatchLiteral("hello world"));
    try std.testing.expect(!matcher.isMatchLiteral("goodbye world"));
}

test "comptime optimization suggestions" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("helloworld123");
        break :blk analyzer.analyze();
    };

    const suggestions = ComptimeLiteralOptimizer.getOptimizationSuggestions(analysis);
    try std.testing.expect(suggestions.len > 0);

    // 应该有字面量优化建议
    var found_literal_suggestion = false;
    for (suggestions) |suggestion| {
        if (suggestion.strategy == .literal_string) {
            found_literal_suggestion = true;
            break;
        }
    }
    try std.testing.expect(found_literal_suggestion);
}