// 简化的性能测试运行器
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
    description: []const u8,
};

// 性能测试结果结构
pub const PerfResult = struct {
    test_case: *const PerfTestCase,
    zig_time_ns: i64,
    zig_ops_per_sec: f64,
    zig_memory_bytes: usize,
    zig_error: ?[]const u8,
};

// 简单字面量测试
const simple_literal_tests = [_]PerfTestCase{
    .{
        .name = "short_match",
        .pattern = "hello",
        .input = "hello world",
        .iterations = 100000,
        .description = "短字符串简单匹配",
    },
    .{
        .name = "long_match",
        .pattern = "hello",
        .input = ("This is a very long string that contains the word hello at the end. " ** 100) ++ "hello",
        .iterations = 10000,
        .description = "长字符串简单匹配",
    },
    .{
        .name = "multiple_matches",
        .pattern = "hello",
        .input = "hello world hello there hello again hello test",
        .iterations = 50000,
        .description = "多次匹配",
    },
    .{
        .name = "no_match",
        .pattern = "hello",
        .input = "this string does not contain the target word",
        .iterations = 100000,
        .description = "无匹配情况",
    },
};

// Zig regex性能测试执行器
pub fn runZigPerfTest(allocator: Allocator, test_case: *const PerfTestCase) !PerfResult {
    var result = PerfResult{
        .test_case = test_case,
        .zig_time_ns = 0,
        .zig_ops_per_sec = 0,
        .zig_memory_bytes = 0,
        .zig_error = null,
    };

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

    return result;
}

// 运行性能测试的主函数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig Regex 性能评测 ===\n\n", .{});

    // 运行简单字面量测试
    for (simple_literal_tests) |test_case| {
        std.debug.print("Running performance test: {s}...\n", .{test_case.name});

        const result = runZigPerfTest(allocator, &test_case) catch |err| {
            std.debug.print("❌ {s}: 测试失败: {}\n", .{ test_case.name, err });
            continue;
        };

        if (result.zig_error != null) {
            std.debug.print("❌ {s}: {s}\n", .{ test_case.name, result.zig_error.? });
        } else {
            std.debug.print("✅ {s}: {}ns ({d:.0} ops/sec)\n", .{
                test_case.name,
                result.zig_time_ns,
                result.zig_ops_per_sec,
            });
        }
    }

    std.debug.print("\n性能测试完成！\n", .{});
}
