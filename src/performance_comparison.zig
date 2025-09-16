// Zig vs Rust Regex 性能对比评测套件
// 本文件包含标准化的性能测试用例，用于对比两个正则表达式引擎的性能

const std = @import("std");
const Allocator = std.mem.Allocator;
const time = std.time;

const zig_regex = @import("regex.zig");
const ZigRegex = zig_regex.Regex;

// 性能测试用例结构
pub const PerfTestCase = struct {
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
    category: PerfCategory,
    description: []const u8,
};

// 性能测试类别
pub const PerfCategory = enum {
    simple_literal,
    character_classes,
    quantifiers,
    unicode,
    complex_patterns,
    backtracking,
    large_input,
    memory_intensive,
};

// 性能测试结果结构
pub const PerfResult = struct {
    test_case: *const PerfTestCase,
    zig_time_ns: i64,
    zig_ops_per_sec: f64,
    zig_memory_bytes: usize,
    rust_time_ns: i64,
    rust_ops_per_sec: f64,
    rust_memory_bytes: usize,
    speedup_ratio: f64,
    zig_error: ?[]const u8,
    rust_error: ?[]const u8,
};

// 简单字面量匹配测试
const simple_literal_tests = [_]PerfTestCase{
    .{
        .name = "short_match",
        .pattern = "hello",
        .input = "hello world",
        .iterations = 100000,
        .category = .simple_literal,
        .description = "短字符串简单匹配",
    },
    .{
        .name = "long_match",
        .pattern = "hello",
        .input = ("This is a very long string that contains the word hello at the end. " ** 100) ++ "hello",
        .iterations = 10000,
        .category = .simple_literal,
        .description = "长字符串简单匹配",
    },
    .{
        .name = "multiple_matches",
        .pattern = "hello",
        .input = "hello world hello there hello again hello test",
        .iterations = 50000,
        .category = .simple_literal,
        .description = "多次匹配",
    },
    .{
        .name = "no_match",
        .pattern = "hello",
        .input = "this string does not contain the target word",
        .iterations = 100000,
        .category = .simple_literal,
        .description = "无匹配情况",
    },
};

// 字符类性能测试
const character_class_tests = [_]PerfTestCase{
    .{
        .name = "digit_class",
        .pattern = "\\d+",
        .input = "1234567890" ** 100,
        .iterations = 50000,
        .category = .character_classes,
        .description = "数字字符类匹配",
    },
    .{
        .name = "word_class",
        .pattern = "\\w+",
        .input = "hello_world123" ** 100,
        .iterations = 50000,
        .category = .character_classes,
        .description = "单词字符类匹配",
    },
    .{
        .name = "range_class",
        .pattern = "[a-z]+",
        .input = "abcdefghijklmnopqrstuvwxyz" ** 100,
        .iterations = 50000,
        .category = .character_classes,
        .description = "范围字符类匹配",
    },
    .{
        .name = "negated_class",
        .pattern = "[^0-9]+",
        .input = "abcdefghijklmnopqrstuvwxyz" ** 100,
        .iterations = 50000,
        .category = .character_classes,
        .description = "否定字符类匹配",
    },
};

// 量词性能测试
const quantifier_tests = [_]PerfTestCase{
    .{
        .name = "star_quantifier",
        .pattern = "a*",
        .input = "a" ** 1000,
        .iterations = 20000,
        .category = .quantifiers,
        .description = "*量词性能",
    },
    .{
        .name = "plus_quantifier",
        .pattern = "a+",
        .input = "a" ** 1000,
        .iterations = 20000,
        .category = .quantifiers,
        .description = "+量词性能",
    },
    .{
        .name = "exact_quantifier",
        .pattern = "a{100}",
        .input = "a" ** 100,
        .iterations = 30000,
        .category = .quantifiers,
        .description = "精确量词性能",
    },
    .{
        .name = "range_quantifier",
        .pattern = "a{50,100}",
        .input = "a" ** 75,
        .iterations = 25000,
        .category = .quantifiers,
        .description = "范围量词性能",
    },
};

// Unicode性能测试
const unicode_tests = [_]PerfTestCase{
    .{
        .name = "chinese_chars",
        .pattern = "世界",
        .input = "你好世界" ** 200,
        .iterations = 20000,
        .category = .unicode,
        .description = "中文字符匹配",
    },
    .{
        .name = "emoji_chars",
        .pattern = "😊",
        .input = "Hello 😊 " ** 200,
        .iterations = 20000,
        .category = .unicode,
        .description = "Emoji字符匹配",
    },
    .{
        .name = "unicode_combining",
        .pattern = "café",
        .input = "café restaurant café café café",
        .iterations = 30000,
        .category = .unicode,
        .description = "组合Unicode字符匹配",
    },
    .{
        .name = "mixed_script",
        .pattern = "[\\u4e00-\\u9fff]+",
        .input = "Hello 你好 world 世界 test 测试" ** 50,
        .iterations = 20000,
        .category = .unicode,
        .description = "混合脚本匹配",
    },
};

// 复杂模式性能测试
const complex_pattern_tests = [_]PerfTestCase{
    .{
        .name = "email_pattern",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "test@example.com user@domain.org admin@mail.net " ** 100,
        .iterations = 20000,
        .category = .complex_patterns,
        .description = "邮箱地址模式匹配",
    },
    .{
        .name = "ipv4_pattern",
        .pattern = "\\b(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b",
        .input = "192.168.1.1 10.0.0.1 172.16.0.1 " ** 100,
        .iterations = 15000,
        .category = .complex_patterns,
        .description = "IPv4地址模式匹配",
    },
    .{
        .name = "html_tag_pattern",
        .pattern = "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*>(.*?)</\\1>",
        .input = "<div>content</div> <span>text</span> <p>paragraph</p>" ** 100,
        .iterations = 15000,
        .category = .complex_patterns,
        .description = "HTML标签模式匹配",
    },
    .{
        .name = "quoted_string_pattern",
        .pattern = "\"([^\"]*)\"",
        .input = "\"hello\" \"world\" \"test\" \"regex\" " ** 100,
        .iterations = 30000,
        .category = .complex_patterns,
        .description = "引号字符串模式匹配",
    },
};

// 回溯性能测试（灾难性回溯）
const backtracking_tests = [_]PerfTestCase{
    .{
        .name = "catastrophic_backtracking",
        .pattern = "(a+)+b",
        .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .iterations = 1000,
        .category = .backtracking,
        .description = "灾难性回溯测试",
    },
    .{
        .name = "nested_quantifiers",
        .pattern = "((a+)*)+b",
        .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .iterations = 1000,
        .category = .backtracking,
        .description = "嵌套量词回溯测试",
    },
    .{
        .name = "alternation_backtrack",
        .pattern = "a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?aaaaaaaaaaaaaaaaaaaa",
        .input = "aaaaaaaaaaaaaaaaaaaa",
        .iterations = 5000,
        .category = .backtracking,
        .description = "选择回溯测试",
    },
};

// 大输入性能测试
const large_input_tests = [_]PerfTestCase{
    .{
        .name = "huge_text_search",
        .pattern = "needle",
        .input = ("haystack haystack haystack " ** 10000) ++ "needle",
        .iterations = 1000,
        .category = .large_input,
        .description = "大文本搜索",
    },
    .{
        .name = "mega_pattern_match",
        .pattern = "\\d+",
        .input = "1234567890" ** 10000,
        .iterations = 1000,
        .category = .large_input,
        .description = "超大模式匹配",
    },
    .{
        .name = "large_unicode_text",
        .pattern = "世界",
        .input = ("你好世界" ** 10000) ++ "世界",
        .iterations = 1000,
        .category = .large_input,
        .description = "大Unicode文本搜索",
    },
};

// 内存密集型测试
const memory_intensive_tests = [_]PerfTestCase{
    .{
        .name = "many_captures",
        .pattern = "(\\d+)(\\w+)(\\s+)(\\p{L}+)(\\S+)",
        .input = "123 abc   你好!" ** 1000,
        .iterations = 5000,
        .category = .memory_intensive,
        .description = "多捕获组内存测试",
    },
    .{
        .name = "large_backreferences",
        .pattern = "(\\d+)\\1",
        .input = "123123 456456 789789 " ** 1000,
        .iterations = 10000,
        .category = .memory_intensive,
        .description = "反向引用内存测试",
    },
    .{
        .name = "complex_nested_groups",
        .pattern = "((\\w+)\\s+(\\d+))\\s+((\\p{L}+)\\s+(\\S+))",
        .input = "hello 123 world 456 你好 789 test 000 " ** 500,
        .iterations = 5000,
        .category = .memory_intensive,
        .description = "复杂嵌套组内存测试",
    },
};

// 运行所有性能测试
pub fn runAllPerfTests(allocator: Allocator) ![]PerfResult {
    var results = std.ArrayList(PerfResult).init(allocator);
    defer results.deinit();

    // 简单字面量测试
    for (simple_literal_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 字符类测试
    for (character_class_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 量词测试
    for (quantifier_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // Unicode测试
    for (unicode_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 复杂模式测试
    for (complex_pattern_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 回溯测试
    for (backtracking_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 大输入测试
    for (large_input_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    // 内存密集型测试
    for (memory_intensive_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});
        const result = try runZigPerfTest(allocator, &test_case);
        try results.append(result);
    }

    return results.toOwnedSlice();
}

// Zig regex性能测试执行器
pub fn runZigPerfTest(allocator: Allocator, test_case: *const PerfTestCase) !PerfResult {
    var result = PerfResult{
        .test_case = test_case,
        .zig_time_ns = 0,
        .zig_ops_per_sec = 0,
        .zig_memory_bytes = 0,
        .rust_time_ns = 0,
        .rust_ops_per_sec = 0,
        .rust_memory_bytes = 0,
        .speedup_ratio = 0,
        .zig_error = null,
        .rust_error = null,
    };

    // 获取基线内存使用情况
    const baseline_memory = getMemoryUsage();

    // 编译正则表达式
    var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Compilation error: {}", .{err}) catch unreachable;
        result.zig_error = err_msg;
        return result;
    };
    defer re.deinit();

    // 预热
    for (0..100) |_| {
        _ = re.match(test_case.input) catch continue;
    }

    // 性能测试
    const start_time = time.nanoTimestamp();
    var matches: usize = 0;

    for (0..test_case.iterations) |_| {
        if (re.match(test_case.input) catch false) {
            matches += 1;
        }
    }

    const end_time = time.nanoTimestamp();
    const execution_time = end_time - start_time;

    // 计算性能指标
    result.zig_time_ns = @as(i64, @truncate(execution_time));
    result.zig_ops_per_sec = @as(f64, @floatFromInt(test_case.iterations)) / @as(f64, @floatFromInt(execution_time)) * 1e9;

    // 获取内存使用情况
    const final_memory = getMemoryUsage();
    result.zig_memory_bytes = if (final_memory > baseline_memory) final_memory - baseline_memory else 0;

    return result;
}

// 辅助函数：获取当前内存使用情况（简化版本）
fn getMemoryUsage() usize {
    // 在实际实现中，这里应该使用系统特定的API来获取内存使用情况
    // 这里返回一个模拟值
    return 0;
}

// 性能统计
pub const PerfStats = struct {
    total_tests: usize,
    zig_total_time_ns: i64,
    rust_total_time_ns: i64,
    zig_avg_time_ns: i64,
    rust_avg_time_ns: i64,
    zig_total_ops_per_sec: f64,
    rust_total_ops_per_sec: f64,
    avg_speedup_ratio: f64,
    zig_total_memory: usize,
    rust_total_memory: usize,

    pub fn calculate(results: []const PerfResult) PerfStats {
        var stats = PerfStats{
            .total_tests = results.len,
            .zig_total_time_ns = 0,
            .rust_total_time_ns = 0,
            .zig_avg_time_ns = 0,
            .rust_avg_time_ns = 0,
            .zig_total_ops_per_sec = 0,
            .rust_total_ops_per_sec = 0,
            .avg_speedup_ratio = 0,
            .zig_total_memory = 0,
            .rust_total_memory = 0,
        };

        var total_speedup: f64 = 0;
        var valid_results: usize = 0;

        for (results) |result| {
            if (result.zig_error == null) {
                stats.zig_total_time_ns += result.zig_time_ns;
                stats.zig_total_ops_per_sec += result.zig_ops_per_sec;
                stats.zig_total_memory += result.zig_memory_bytes;
            }
            if (result.rust_error == null) {
                stats.rust_total_time_ns += result.rust_time_ns;
                stats.rust_total_ops_per_sec += result.rust_ops_per_sec;
                stats.rust_total_memory += result.rust_memory_bytes;
            }
            if (result.zig_error == null and result.rust_error == null) {
                total_speedup += result.speedup_ratio;
                valid_results += 1;
            }
        }

        if (results.len > 0) {
            stats.zig_avg_time_ns = stats.zig_total_time_ns / @as(i64, @intCast(results.len));
            stats.rust_avg_time_ns = stats.rust_total_time_ns / @as(i64, @intCast(results.len));
        }

        if (valid_results > 0) {
            stats.avg_speedup_ratio = total_speedup / @as(f64, @floatFromInt(valid_results));
        }

        return stats;
    }
};

// 按类别统计
pub const CategoryPerfStats = struct {
    category: PerfCategory,
    total_tests: usize,
    zig_avg_time_ns: i64,
    rust_avg_time_ns: i64,
    zig_avg_ops_per_sec: f64,
    rust_avg_ops_per_sec: f64,
    speedup_ratio: f64,

    pub fn calculate(results: []const PerfResult, category: PerfCategory) CategoryPerfStats {
        var stats = CategoryPerfStats{
            .category = category,
            .total_tests = 0,
            .zig_avg_time_ns = 0,
            .rust_avg_time_ns = 0,
            .zig_avg_ops_per_sec = 0,
            .rust_avg_ops_per_sec = 0,
            .speedup_ratio = 0,
        };

        var zig_total_time: i64 = 0;
        var rust_total_time: i64 = 0;
        var zig_total_ops: f64 = 0;
        var rust_total_ops: f64 = 0;
        var total_speedup: f64 = 0;
        var valid_results: usize = 0;

        for (results) |result| {
            if (result.test_case.category == category) {
                stats.total_tests += 1;
                if (result.zig_error == null) {
                    zig_total_time += result.zig_time_ns;
                    zig_total_ops += result.zig_ops_per_sec;
                }
                if (result.rust_error == null) {
                    rust_total_time += result.rust_time_ns;
                    rust_total_ops += result.rust_ops_per_sec;
                }
                if (result.zig_error == null and result.rust_error == null) {
                    total_speedup += result.speedup_ratio;
                    valid_results += 1;
                }
            }
        }

        if (stats.total_tests > 0) {
            stats.zig_avg_time_ns = zig_total_time / @as(i64, @intCast(stats.total_tests));
            stats.rust_avg_time_ns = rust_total_time / @as(i64, @intCast(stats.total_tests));
            stats.zig_avg_ops_per_sec = zig_total_ops / @as(f64, @floatFromInt(stats.total_tests));
            stats.rust_avg_ops_per_sec = rust_total_ops / @as(f64, @floatFromInt(stats.total_tests));
        }

        if (valid_results > 0) {
            stats.speedup_ratio = total_speedup / @as(f64, @floatFromInt(valid_results));
        }

        return stats;
    }
};

// 辅助函数：格式化性能结果
pub fn formatPerfResult(result: PerfResult, writer: anytype) !void {
    const zig_status = if (result.zig_error != null) "ERROR" else "OK";
    const rust_status = if (result.rust_error != null) "ERROR" else "OK";

    try writer.print(
        \\Test: {s}
        \\Category: {s}
        \\Iterations: {}
        \\Zig: {}ns ({d:.0} ops/sec) {} ({} bytes)
        \\Rust: {}ns ({d:.0} ops/sec) {} ({} bytes)
        \\Speedup: {d:.2}x
        \\Description: {s}
        \\
    , .{
        result.test_case.name,
        @tagName(result.test_case.category),
        result.test_case.iterations,
        result.zig_time_ns,
        result.zig_ops_per_sec,
        zig_status,
        result.zig_memory_bytes,
        result.rust_time_ns,
        result.rust_ops_per_sec,
        rust_status,
        result.rust_memory_bytes,
        result.speedup_ratio,
        result.test_case.description,
    });

    if (result.zig_error != null) {
        try writer.print("Zig Error: {s}\n", .{result.zig_error.?});
    }

    if (result.rust_error != null) {
        try writer.print("Rust Error: {s}\n", .{result.rust_error.?});
    }
}

// 测试性能评测套件
test "performance comparison test suite" {
    const allocator = std.testing.allocator;

    // 测试简单的性能测试用例
    const simple_test = PerfTestCase{
        .name = "simple_perf_test",
        .pattern = "hello",
        .input = "hello world",
        .iterations = 1000,
        .category = .simple_literal,
        .description = "简单性能测试",
    };

    const result = try runZigPerfTest(allocator, &simple_test);

    try std.testing.expect(result.zig_error == null);
    try std.testing.expect(result.zig_time_ns > 0);
    try std.testing.expect(result.zig_ops_per_sec > 0);
}

// 运行性能测试的主函数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try runPerformanceComparison(gpa.allocator());
}

pub fn runPerformanceComparison(allocator: Allocator) !void {
    std.debug.print("=== Zig vs Rust Regex 性能对比评测 ===\n\n", .{});

    const results = try runAllPerfTests(allocator);
    defer allocator.free(results);

    // 计算总体统计
    const overall_stats = PerfStats.calculate(results);

    std.debug.print(
        \\=== 总体性能统计 ===
        \\总测试用例数: {}
        \\Zig总时间: {}ns
        \\Rust总时间: {}ns
        \\Zig平均时间: {}ns
        \\Rust平均时间: {}ns
        \\Zig总性能: {d:.0} ops/sec
        \\Rust总性能: {d:.0} ops/sec
        \\平均加速比: {d:.2}x
        \\Zig总内存: {} bytes
        \\Rust总内存: {} bytes
        \\
    , .{
        overall_stats.total_tests,
        overall_stats.zig_total_time_ns,
        overall_stats.rust_total_time_ns,
        overall_stats.zig_avg_time_ns,
        overall_stats.rust_avg_time_ns,
        overall_stats.zig_total_ops_per_sec,
        overall_stats.rust_total_ops_per_sec,
        overall_stats.avg_speedup_ratio,
        overall_stats.zig_total_memory,
        overall_stats.rust_total_memory,
    });

    // 按类别输出统计
    inline for (std.meta.tags(PerfCategory)) |category| {
        const category_stats = CategoryPerfStats.calculate(results, category);
        if (category_stats.total_tests > 0) {
            std.debug.print(
                \\=== {s} 类别性能统计 ===
                \\测试用例数: {}
                \\Zig平均时间: {}ns
                \\Rust平均时间: {}ns
                \\Zig平均性能: {d:.0} ops/sec
                \\Rust平均性能: {d:.0} ops/sec
                \\平均加速比: {d:.2}x
                \\
            , .{
                @tagName(category),
                category_stats.total_tests,
                category_stats.zig_avg_time_ns,
                category_stats.rust_avg_time_ns,
                category_stats.zig_avg_ops_per_sec,
                category_stats.rust_avg_ops_per_sec,
                category_stats.speedup_ratio,
            });
        }
    }

    // 输出详细结果
    std.debug.print("\n=== 详细测试结果 ===\n", .{});
    for (results) |result| {
        try formatPerfResult(result, std.io.getStdOut().writer());
    }
}
