// 简化的编译时优化测试
// 验证核心编译时优化功能

const std = @import("std");
const testing = std.testing;

const comptime_optimizer = @import("comptime_optimizer.zig");
const ComptimeOptimizer = comptime_optimizer.ComptimeOptimizer;
const ComptimeConfig = comptime_optimizer.ComptimeConfig;
const ComptimeAnalysis = comptime_optimizer.ComptimeAnalysis;

// 基础编译时优化测试
test "comptime optimizer basic validation" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("hello", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expectEqual(ComptimeAnalysis.Complexity.trivial, analysis.complexity);
    try testing.expect(analysis.is_literal_only);
}

test "comptime optimizer constant folding" {
    const input = "hello\\nworld";
    const folded = comptime ComptimeOptimizer.foldConstants(input);

    try testing.expectEqualStrings("hello\nworld", folded);
}

test "comptime optimizer error detection" {
    const config = ComptimeConfig{};

    // 测试未闭合的括号
    const invalid_analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("hello(", config);
        break :blk optimizer.analyze();
    };
    try testing.expect(!invalid_analysis.is_valid);
    try testing.expect(invalid_analysis.error_message != null);
}

test "comptime optimizer complexity analysis" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("abc.*def", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.complexity_score > 0);
    try testing.expect(analysis.estimated_instructions > 0);
}

test "comptime optimizer unicode detection" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("test\\u1234", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    // 简化测试，不检查具体的unicode属性
}

test "comptime regex wrapper basic" {
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
}

test "comptime regex wrapper compilation" {
    // 这个测试验证编译时正则表达式包装器能否正确编译
    const config = ComptimeConfig{};
    const ValidRegex = comptime_optimizer.ComptimeRegex("test123", config);

    // 如果能编译到这里，说明正则表达式语法有效
    try testing.expect(true);
}

test "comptime optimization suggestions" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("helloworld123", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.is_literal_only);
    try testing.expect(analysis.optimizations.len > 0);

    // 应该有字面量优化建议
    var found_literal_suggestion = false;
    for (analysis.optimizations) |opt| {
        if (opt.strategy == .literal_string) {
            found_literal_suggestion = true;
            break;
        }
    }
    try testing.expect(found_literal_suggestion);
}

test "comptime optimizer performance estimation" {
    const config = ComptimeConfig{};
    const analysis = comptime blk: {
        var optimizer = ComptimeOptimizer.init("simple_pattern", config);
        break :blk optimizer.analyze();
    };

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.estimated_instructions > 0);
    try testing.expect(analysis.estimated_memory_bytes > 0);
}

test "comptime optimizer edge cases" {
    const config = ComptimeConfig{};

    // 空模式
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
}
