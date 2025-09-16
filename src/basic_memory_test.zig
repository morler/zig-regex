// 基本内存测试
// 测试基本的内存分配和释放

const std = @import("std");
const testing = std.testing;

test "basic memory allocation" {
    const allocator = testing.allocator;

    std.debug.print("=== 基本内存分配测试 ===\n", .{});

    // 测试简单的内存分配
    const start_time = std.time.nanoTimestamp();

    var objects = std.ArrayList([]u8).init(allocator);
    defer {
        for (objects.items) |obj| {
            allocator.free(obj);
        }
        objects.deinit();
    }

    // 分配一些对象
    for (0..100) |i| {
        const size = i % 64 + 1;
        const obj = try allocator.alloc(u8, size);
        @memset(obj, @as(u8, @intCast(i % 256)));
        try objects.append(obj);
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns = end_time - start_time;

    std.debug.print("分配100个对象耗时: {} ns\n", .{elapsed_ns});
    std.debug.print("平均每个对象: {} ns\n", .{elapsed_ns / 100});

    // 验证对象内容
    for (objects.items, 0..) |obj, i| {
        const expected_value = @as(u8, @intCast(i % 256));
        for (obj) |byte| {
            try testing.expect(byte == expected_value);
        }
    }

    std.debug.print("✓ 所有对象验证通过\n", .{});
}

test "memory efficiency test" {
    const allocator = testing.allocator;

    std.debug.print("=== 内存效率测试 ===\n", .{});

    // 测试内存重用
    var reused_obj: []u8 = undefined;

    // 第一次分配
    reused_obj = try allocator.alloc(u8, 100);
    @memset(reused_obj, 0xAA);

    // 释放
    allocator.free(reused_obj);

    // 第二次分配（可能会重用内存）
    reused_obj = try allocator.alloc(u8, 100);
    @memset(reused_obj, 0xBB);

    // 验证内容
    try testing.expect(reused_obj[0] == 0xBB);
    try testing.expect(reused_obj[99] == 0xBB);

    allocator.free(reused_obj);

    std.debug.print("✓ 内存重用测试通过\n", .{});
}