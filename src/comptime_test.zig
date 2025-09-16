// 编译时优化测试和验证
// 全面的编译时优化功能测试

const std = @import("std");
const testing = std.testing;

const comptime_optimizer = @import("comptime_optimizer.zig");
const ComptimeOptimizer = comptime_optimizer.ComptimeOptimizer;
const ComptimeConfig = comptime_optimizer.ComptimeConfig;
const ComptimeAnalysis = comptime_optimizer.ComptimeAnalysis;

const comptime_literals = @import("comptime_literals.zig");
const ComptimeLiteralAnalyzer = comptime_literals.ComptimeLiteralAnalyzer;
const ComptimeLiteralOptimizer = comptime_literals.ComptimeLiteralOptimizer;
const ComptimeLiteralMatcher = comptime_literals.ComptimeLiteralMatcher;

const comptime_nfa_simplifier = @import("comptime_nfa_simplifier.zig");
const ComptimeNFASimplifier = comptime_nfa_simplifier.ComptimeNFASimplifier;
const SimplificationStrategy = comptime_nfa_simplifier.SimplificationStrategy;

const compile = @import("compile.zig");
const Program = compile.Program;
const Instruction = compile.Instruction;
const InstructionData = compile.InstructionData;

// 基础编译时优化测试
test "comptime optimizer - simple literal pattern" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("hello", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expectEqual(ComptimeAnalysis.Complexity.trivial, analysis.complexity);
    try testing.expect(analysis.is_literal_only);
    try testing.expectEqual(@as(usize, 0), analysis.capture_count);
    try testing.expect(!analysis.is_unicode);

    // 检查字面量前缀
    try testing.expect(analysis.literal_prefix != null);
    try testing.expectEqualStrings("hello", analysis.literal_prefix.?);

    // 检查优化建议
    try testing.expect(analysis.optimizations.len > 0);
    try testing.expectEqual(ComptimeAnalysis.Strategy.literal_string, analysis.optimizations[0].strategy);
}

test "comptime optimizer - complex pattern" {
    const config = ComptimeConfig{};
    const pattern = @"(a|b|c)*\d+(?:foo|bar){1,3}";
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init(pattern, config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.complexity == .moderate or analysis.complexity == .complex);
    try testing.expect(analysis.has_captures);
    try testing.expect(analysis.capture_count > 0);

    // 检查复杂度分数
    try testing.expect(analysis.complexity_score > 10);

    // 检查资源估算
    try testing.expect(analysis.estimated_instructions > 0);
    try testing.expect(analysis.estimated_memory_bytes > 0);
}

test "comptime optimizer - unicode pattern" {
    const config = ComptimeConfig{};
    const pattern = @"\p{L}+\s*\d+";
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init(pattern, config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.is_unicode);
    try testing.expect(analysis.complexity_score > 5);
}

test "comptime optimizer - invalid patterns" {
    const config = ComptimeConfig{};

    // 测试未闭合的括号
    const invalid1 = comptime blk: {
        var optimizer = ComptimeOptimizer.init("hello(", config);
        break :blk optimizer.analyze();
    };
    try testing.expect(!invalid1.is_valid);
    try testing.expect(invalid1.error_message != null);

    // 测试无效的转义序列
    const invalid2 = comptime blk: {
        var optimizer = ComptimeOptimizer.init(@"hello\x", config);
        break :blk optimizer.analyze();
    };
    try testing.expect(!invalid2.is_valid);
}

test "comptime optimizer - constant folding" {
    const input = @"hello\nworld\ttest";
    const folded = comptime ComptimeOptimizer.foldConstants(input);

    try testing.expectEqualStrings("hello\nworld\ttest", folded);
}

// 编译时字面量分析测试
test "comptime literal analyzer - basic" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello world 123");
        break :blk analyzer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.literals.len >= 1);
    try testing.expect(analysis.longest_literal != null);
}

test "comptime literal analyzer - with special chars" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello.*world");
        break :blk analyzer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(!analysis.is_literal_only);
    try testing.expect(analysis.literal_prefix != null);
    try testing.expectEqualStrings("hello", analysis.literal_prefix.?);
}

test "comptime literal analyzer - escape sequences" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("hello\\nworld\\t");
        break :blk analyzer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.literals.len >= 2);
}

test "comptime literal matcher" {
    const TestMatcher = ComptimeLiteralMatcher("hello");

    const allocator = testing.allocator;
    var matcher = try TestMatcher.init(allocator);
    defer matcher.deinit();

    try testing.expect(matcher.isMatchLiteral("hello world"));
    try testing.expect(!matcher.isMatchLiteral("goodbye world"));

    const match_pos = matcher.findBestMatch("hello world");
    try testing.expect(match_pos != null);
    try testing.expectEqual(@as(usize, 0), match_pos.?);
}

test "comptime literal optimization suggestions" {
    const analysis = comptime blk: {
        var analyzer = ComptimeLiteralAnalyzer.init("helloworld123");
        break :blk analyzer.analyze();
    };

    const suggestions = ComptimeLiteralOptimizer.getOptimizationSuggestions(analysis);
    try testing.expect(suggestions.len > 0);

    // 检查字面量优化建议
    var found_literal_optimization = false;
    for (suggestions) |suggestion| {
        if (suggestion.strategy == .literal_string) {
            found_literal_optimization = true;
            try testing.expect(suggestion.speedup_factor > 1.0);
            break;
        }
    }
    try testing.expect(found_literal_optimization);
}

// 编译时NFA简化测试
test "comptime NFA simplifier - basic analysis" {
    // 创建一个简单的测试程序
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'h' }),
        Instruction.new(2, InstructionData{ .Char = 'e' }),
        Instruction.new(3, InstructionData{ .Char = 'l' }),
        Instruction.new(4, InstructionData{ .Char = 'l' }),
        Instruction.new(5, InstructionData{ .Char = 'o' }),
        Instruction.new(6, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.basic;
    const analysis = comptime blk: {
        var simplifier = ComptimeNFASimplifier.init(strategy);
        break :blk simplifier.analyzeSimplificationOpportunities(&test_program);
    };

    try testing.expect(analysis.original_complexity > 0);
    try testing.expect(analysis.estimated_instruction_reduction >= 0);
}

test "comptime NFA simplifier - redundant jumps" {
    // 创建包含冗余跳转的测试程序
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'a' }),
        Instruction.new(2, InstructionData.Jump), // 冗余跳转
        Instruction.new(3, InstructionData{ .Char = 'b' }),
        Instruction.new(4, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.aggressive;
    const analysis = comptime blk: {
        var simplifier = ComptimeNFASimplifier.init(strategy);
        break :blk simplifier.analyzeSimplificationOpportunities(&test_program);
    };

    try testing.expect(analysis.redundant_instructions > 0);
    analysis.calculateWorth();
    try testing.expect(analysis.is_worth_simplifying);
}

test "comptime NFA simplifier - actual simplification" {
    // 创建一个可以简化的程序
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'a' }),
        Instruction.new(2, InstructionData.Jump), // 冗余跳转到下一条
        Instruction.new(3, InstructionData{ .Char = 'b' }),
        Instruction.new(4, InstructionData.Jump), // 另一个冗余跳转
        Instruction.new(5, InstructionData{ .Char = 'c' }),
        Instruction.new(6, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.aggressive;
    var simplifier = ComptimeNFASimplifier.init(strategy);
    const simplified = try simplifier.simplifyProgram(&test_program);
    defer simplified.deinit();

    try testing.expect(simplified.original_count > simplified.instructions.items.len);
    try testing.expect(simplified.removed_count > 0);
    try testing.expect(simplified.getOptimizationRatio() > 0.0);
}

test "comptime NFA simplifier wrapper" {
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'h' }),
        Instruction.new(2, InstructionData.Jump), // 冗余跳转
        Instruction.new(3, InstructionData{ .Char = 'e' }),
        Instruction.new(4, InstructionData.Jump), // 另一个冗余跳转
        Instruction.new(5, InstructionData{ .Char = 'l' }),
        Instruction.new(6, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const TestSimplifier = ComptimeNFASimplifierWrapper(&test_program, SimplificationStrategy.basic);

    const analysis = TestSimplifier.getAnalysis();
    try testing.expect(analysis.redundant_instructions > 0);

    const simplified = TestSimplifier.getSimplifiedProgram();
    defer simplified.deinit();

    try testing.expect(simplified.original_count >= simplified.instructions.items.len);
}

// 编译时正则表达式包装器测试
test "comptime regex wrapper" {
    const config = ComptimeConfig{};
    const TestRegex = comptime_optimizer.ComptimeRegex("hello", config);

    const allocator = testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    try testing.expect(try regex.isMatch("hello world"));
    try testing.expect(!(try regex.isMatch("goodbye world")));

    // 检查编译时分析
    const analysis = TestRegex.getAnalysis();
    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.is_literal_only);

    // 检查优化建议
    try testing.expect(analysis.optimizations.len > 0);
}

test "comptime regex with complex pattern" {
    const config = ComptimeConfig{ .level = .aggressive };
    const TestRegex = comptime_optimizer.ComptimeRegex(@"\d+\s*\w+", config);

    const allocator = testing.allocator;
    var regex = try TestRegex.init(allocator);
    defer regex.deinit();

    try testing.expect(try regex.isMatch("123   test"));
    try testing.expect(!(try regex.isMatch("abc def")));

    const analysis = TestRegex.getAnalysis();
    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.complexity != .trivial);
}

// 性能基准测试
test "comptime optimization performance" {
    const config = ComptimeConfig{ .level = .extreme };

    const start_time = std.time.nanoTimestamp();

    // 编译时分析应该在编译时完成，运行时几乎没有开销
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init(@"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}", config);
        break :blk optimizer.analyze();
    };

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns = end_time - start_time;

    // 运行时开销应该极小（< 1ms）
    try testing.expect(elapsed_ns < 1_000_000);

    // 分析应该正确识别邮件模式
    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.complexity == .moderate or analysis.complexity == .complex);
}

// 内存使用测试
test "comptime optimization memory usage" {
    const allocator = testing.allocator;

    // 测试编译时字面量匹配器的内存使用
    const TestMatcher = ComptimeLiteralMatcher("test_pattern");
    var matcher = try TestMatcher.init(allocator);
    defer matcher.deinit();

    // 基本操作不应分配额外内存
    const match_result = matcher.isMatchLiteral("test_pattern_here");
    try testing.expect(match_result);
}

// 边界情况测试
test "comptime optimization edge cases" {
    // 空模式
    const config = ComptimeConfig{};
    const empty_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("", config);
        break :blk optimizer.analyze();
    };
    try testing.expect(!empty_analysis.is_valid);

    // 单字符模式
    const single_char_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("a", config);
        break :blk optimizer.analyze();
    };
    try testing.expect(single_char_analysis.is_valid);
    try testing.expect(single_char_analysis.is_literal_only);

    // 极长模式
    const long_pattern = "a" ** 100;
    const long_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init(long_pattern, config);
        break :blk optimizer.analyze();
    };
    try testing.expect(long_analysis.is_valid);
    try testing.expect(long_analysis.is_literal_only);
}

// 复杂度限制测试
test "comptime complexity limits" {
    const strict_config = ComptimeConfig{
        .max_complexity_score = 10,
        .fail_on_complex_patterns = true,
    };

    // 简单模式应该通过
    const simple_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("hello", strict_config);
        break :blk optimizer.analyze();
    };
    try testing.expect(simple_analysis.is_valid);

    // 复杂模式应该失败
    const complex_pattern = @"(a|b|c)*(?:\d+\w+){2,5}[a-z]+";
    const complex_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init(complex_pattern, strict_config);
        break :blk optimizer.analyze();
    };
    try testing.expect(!complex_analysis.is_valid);
    try testing.expect(complex_analysis.error_message != null);
}

// 多策略优化测试
test "comptime multi-strategy optimization" {
    const config = ComptimeConfig{ .level = .extreme };
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("helloworld123", config);
        break :blk optimizer.analyze();
    };

    // 应该有多个优化策略
    try testing.expect(analysis.optimizations.len > 1);

    // 检查策略多样性
    var strategies: [4]bool = undefined;
    for (&strategies) |*s| s.* = false;

    for (analysis.optimizations) |opt| {
        switch (opt.strategy) {
            .literal_string => strategies[0] = true,
            .literal_prefix => strategies[1] = true,
            .boyer_moore => strategies[2] = true,
            .early_rejection => strategies[3] = true,
            else => {},
        }
    }

    // 应该至少有2种不同的策略
    var strategy_count: usize = 0;
    for (strategies) |s| {
        if (s) strategy_count += 1;
    }
    try testing.expect(strategy_count >= 2);
}

// 编译时错误处理测试
test "comptime error handling" {
    const config = ComptimeConfig{};

    // 测试各种错误情况
    const error_cases = [_][]const u8{
        "hello(", // 未闭合括号
        "[a-z", // 未闭合字符类
        "*", // 孤立量词
        "a**", // 重复量词
        @"\x", // 无效转义
    };

    for (error_cases) |pattern| {
        const analysis = comptime blk: {
            var optimizer = ComptimeOptimizer.init(pattern, config);
            break :blk optimizer.analyze();
        };
        try testing.expect(!analysis.is_valid);
        try testing.expect(analysis.error_message != null);
    }
}

// 编译时优化回归测试
test "comptime optimization regression" {
    // 确保已知好的模式仍然能正确处理
    const good_patterns = [_][]const u8{
        "hello",
        @"\d+",
        @"[a-z]+",
        @"(hello)+",
        @"a{1,3}",
        @"hello.*world",
        @"\b\w+\b",
    };

    const config = ComptimeConfig{};
    for (good_patterns) |pattern| {
        const analysis = comptime blk: {
            var optimizer = ComptimeOptimizer.init(pattern, config);
            break :blk optimizer.analyze();
        };
        try testing.expect(analysis.is_valid, "Pattern should be valid: {s}", .{pattern});
    }
}
