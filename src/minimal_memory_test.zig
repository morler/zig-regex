// 最小内存测试
// 仅测试基本的内存分配功能

const std = @import("std");
const testing = std.testing;

test "minimal memory test" {
    const allocator = testing.allocator;

    std.debug.print("=== 最小内存测试 ===\n", .{});

    // 测试单个内存分配
    const obj = try allocator.alloc(u8, 10);
    defer allocator.free(obj);

    // 填充数据
    @memset(obj, 0x55);

    // 验证数据
    for (obj) |byte| {
        try testing.expect(byte == 0x55);
    }

    std.debug.print("✓ 基本内存分配测试通过\n", .{});

    // 测试多个分配
    const start_time = std.time.nanoTimestamp();

    var total_allocated: usize = 0;
    for (0..50) |i| {
        const size = i % 32 + 1;
        const temp_obj = try allocator.alloc(u8, size);
        defer allocator.free(temp_obj);

        @memset(temp_obj, @as(u8, @intCast(i % 256)));
        total_allocated += size;
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns = end_time - start_time;

    std.debug.print("分配50个对象耗时: {} ns\n", .{elapsed_ns});
    std.debug.print("总共分配: {} 字节\n", .{total_allocated});

    std.debug.print("✓ 批量内存分配测试通过\n", .{});
}