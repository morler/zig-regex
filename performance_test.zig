const std = @import("std");
const Regex = @import("src/regex.zig").Regex;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.debug.print;

    try stdout.print("Zig Regex Engine Performance Test\n", .{});
    try stdout.print("===============================\n\n", .{});

    // 测试1: 简单字面量匹配
    const simple_pattern = "hello";
    const simple_input = "hello world hello world hello world hello world";

    const simple_regex = try Regex.compile(allocator, simple_pattern);
    defer simple_regex.deinit();

    var timer = try std.time.Timer.start();
    const iterations = 10000;

    for (0..iterations) |_| {
        _ = try simple_regex.match(simple_input);
    }

    const simple_time = timer.lap();
    try stdout.print("Simple matching ({} iterations): {}ms\n", .{iterations, simple_time / std.time.ns_per_ms});

    // 测试2: 复杂模式匹配
    const complex_pattern = "[a-z]+@[a-z]+\\.[a-z]{2,}";
    const complex_input = "Emails: user@example.com, support@company.org, test@test.org";

    const complex_regex = try Regex.compile(allocator, complex_pattern);
    defer complex_regex.deinit();

    timer.reset();
    for (0..iterations) |_| {
        _ = try complex_regex.match(complex_input);
    }

    const complex_time = timer.lap();
    try stdout.print("Complex pattern ({} iterations): {}ms\n", .{iterations, complex_time / std.time.ns_per_ms});

    // 测试3: 长文本搜索
    var long_text = std.ArrayList(u8).init(allocator);
    defer long_text.deinit();

    for (0..1000) |_| {
        try long_text.appendSlice("The quick brown fox jumps over the lazy dog. ");
    }

    const search_regex = try Regex.compile(allocator, "fox");
    defer search_regex.deinit();

    timer.reset();
    _ = try search_regex.match(long_text.items);
    const search_time = timer.lap();

    try stdout.print("Long text search: {}ms\n", .{search_time / std.time.ns_per_ms});

    try stdout.print("\nAll tests completed!\n", .{});
}