// 性能基准测试 - 对比新旧输入抽象层的性能

const std = @import("std");
const time = std.time;
const testing = std.testing;

const input_old = @import("input.zig");
const input_new = @import("input_new.zig");

const InputOld = input_old.Input;
const InputBytesOld = input_old.InputBytes;
const InputBytesNew = input_new.InputBytes;
const InputUtf8New = input_new.InputUtf8;

// 性能测试结果结构
pub const BenchmarkResult = struct {
    name: []const u8,
    duration_ns: i64,
    operations_per_second: f64,
};

// 运行性能基准测试
pub fn runBenchmark(allocator: std.mem.Allocator) ![]BenchmarkResult {
    var results: [5]BenchmarkResult = undefined;

    // 测试数据
    const ascii_text = "The quick brown fox jumps over the lazy dog. " ** 20;
    const utf8_text = "你好世界こんにちは안녕하세요こんにちは안녕하세요 " ** 10;
    const iterations = 10000;

    // 1. 旧InputBytes性能测试
    const old_bytes_start = time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var input = InputBytesOld.init(ascii_text);
        while (!input.input.isConsumed()) {
            _ = input.input.current();
            input.input.advance();
        }
    }
    const old_bytes_time = time.nanoTimestamp() - old_bytes_start;

    results[0] = BenchmarkResult{
        .name = "Old InputBytes",
        .duration_ns = @as(i64, @truncate(old_bytes_time)),
        .operations_per_second = @as(f64, @floatFromInt(iterations * ascii_text.len)) / @as(f64, @floatFromInt(old_bytes_time)) * 1e9,
    };

    // 2. 新InputBytes性能测试
    const new_bytes_start = time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        var input = InputBytesNew.init(ascii_text);
        while (!input.isConsumed()) {
            _ = input.current();
            input.advance();
        }
    }
    const new_bytes_time = time.nanoTimestamp() - new_bytes_start;

    results[1] = BenchmarkResult{
        .name = "New InputBytes",
        .duration_ns = @as(i64, @truncate(new_bytes_time)),
        .operations_per_second = @as(f64, @floatFromInt(iterations * ascii_text.len)) / @as(f64, @floatFromInt(new_bytes_time)) * 1e9,
    };

    // 3. 新InputUtf8性能测试 (ASCII文本)
    const new_utf8_ascii_start = time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        var input = InputUtf8New.init(ascii_text);
        while (!input.isConsumed()) {
            _ = input.current();
            input.advance();
        }
    }
    const new_utf8_ascii_time = time.nanoTimestamp() - new_utf8_ascii_start;

    results[2] = BenchmarkResult{
        .name = "New InputUtf8 (ASCII)",
        .duration_ns = @as(i64, @truncate(new_utf8_ascii_time)),
        .operations_per_second = @as(f64, @floatFromInt(iterations * ascii_text.len)) / @as(f64, @floatFromInt(new_utf8_ascii_time)) * 1e9,
    };

    // 4. 新InputUtf8性能测试 (UTF-8文本)
    const new_utf8_unicode_start = time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        var input = InputUtf8New.init(utf8_text);
        while (!input.isConsumed()) {
            _ = input.current();
            input.advance();
        }
    }
    const new_utf8_unicode_time = time.nanoTimestamp() - new_utf8_unicode_start;

    results[3] = BenchmarkResult{
        .name = "New InputUtf8 (Unicode)",
        .duration_ns = @as(i64, @truncate(new_utf8_unicode_time)),
        .operations_per_second = @as(f64, @floatFromInt(iterations * utf8_text.len)) / @as(f64, @floatFromInt(new_utf8_unicode_time)) * 1e9,
    };

    // 5. 单词字符检测性能测试
    const word_char_start = time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        var input = InputBytesNew.init(ascii_text);
        while (!input.isConsumed()) {
            _ = input.isCurrentWordChar();
            _ = input.isPreviousWordChar();
            _ = input.isNextWordChar();
            input.advance();
        }
    }
    const word_char_time = time.nanoTimestamp() - word_char_start;

    results[4] = BenchmarkResult{
        .name = "Word Char Detection",
        .duration_ns = @as(i64, @truncate(word_char_time)),
        .operations_per_second = @as(f64, @floatFromInt(iterations * ascii_text.len * 3)) / @as(f64, @floatFromInt(word_char_time)) * 1e9,
    };

    return allocator.dupe(BenchmarkResult, results[0..5]);
}

// 打印性能测试结果
pub fn printBenchmarkResults(results: []BenchmarkResult) void {
    std.debug.print("\n=== 性能基准测试结果 ===\n", .{});
    std.debug.print("{s:<25} {s:>15} {s:>20}\n", .{ "测试名称", "耗时 (ns)", "操作数/秒" });
    std.debug.print("=================================================================\n", .{});

    for (results) |result| {
        std.debug.print("{s:<25} {d:>15} {d:>20.2}\n", .{
            result.name,
            result.duration_ns,
            result.operations_per_second,
        });
    }

    // 计算性能提升
    if (results.len >= 2) {
        const old_time = results[0].duration_ns;
        const new_time = results[1].duration_ns;
        const improvement = if (old_time > 0) @as(f64, @floatFromInt(old_time)) / @as(f64, @floatFromInt(new_time)) else 0;

        std.debug.print("\n性能提升: {:.2}x\n", .{improvement});
        std.debug.print("时间节省: {:.2}%\n", .{(1.0 - 1.0 / improvement) * 100.0});
    }

    std.debug.print("\n", .{});
}

test "Performance benchmark" {
    const allocator = testing.allocator;
    const results = try runBenchmark(allocator);
    defer allocator.free(results);

    // 验证性能测试完成
    try testing.expect(results.len >= 2);

    // 新实现应该比旧实现更快（或者至少不慢太多）
    const old_time = results[0].duration_ns;
    const new_time = results[1].duration_ns;

    // 允许10%的性能波动（由于系统负载等因素）
    const max_regression = @divTrunc(old_time * 11, 10);
    try testing.expect(new_time <= max_regression);

    // 打印结果
    printBenchmarkResults(results);
}
