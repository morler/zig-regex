// 快速性能测试运行器
const std = @import("std");
const time = std.time;

const zig_regex = @import("regex.zig");
const ZigRegex = zig_regex.Regex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig Regex 快速性能评测 ===\n\n", .{});

    const test_cases = [_]struct {
        name: []const u8,
        pattern: []const u8,
        input: []const u8,
        iterations: usize,
    }{
        .{
            .name = "simple_match",
            .pattern = "hello",
            .input = "hello world",
            .iterations = 1000,
        },
        .{
            .name = "digit_class",
            .pattern = "\\d+",
            .input = "12345",
            .iterations = 1000,
        },
        .{
            .name = "unicode_match",
            .pattern = "世界",
            .input = "你好世界",
            .iterations = 1000,
        },
    };

    for (test_cases) |test_case| {
        std.debug.print("测试 {s}: ", .{test_case.name});

        // 编译正则表达式
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ 编译失败: {}\n", .{err});
            continue;
        };
        defer re.deinit();

        // 预热
        for (0..10) |_| {
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
        const ops_per_sec = @as(f64, @floatFromInt(test_case.iterations)) / @as(f64, @floatFromInt(execution_time)) * 1e9;

        std.debug.print("{d:.0} ops/sec\n", .{ops_per_sec});
    }

    std.debug.print("\n快速性能测试完成！\n", .{});
}
