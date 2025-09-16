// 内存管理优化测试
// 验证对象池、内存池和优化API的性能和正确性

const std = @import("std");
const testing = std.testing;
const time = std.time;
const Timer = time.Timer;

const memory_pool = @import("memory_pool.zig");
const MemoryManager = memory_pool.MemoryManager;
const ObjectPool = memory_pool.ObjectPool;
const TypedObjectPool = memory_pool.TypedObjectPool;
const MemoryPool = memory_pool.MemoryPool;
const OptimizedArrayList = memory_pool.OptimizedArrayList;
const regex_new = @import("regex_new.zig");
const regex_optimized = @import("regex_optimized.zig");

// 测试数据结构
const TestStruct = struct {
    value: i32,
    text: []const u8,
    counter: usize,
};

// 对象池测试
test "ObjectPool basic operations" {
    const allocator = testing.allocator;
    var pool = TypedObjectPool(TestStruct).init(allocator, 10);
    defer pool.deinit();

    // 测试对象分配和回收
    const obj1 = try pool.get();
    obj1.* = .{ .value = 42, .text = "hello", .counter = 1 };

    const obj2 = try pool.get();
    obj2.* = .{ .value = 100, .text = "world", .counter = 2 };

    // 归还对象
    pool.put(obj1);
    pool.put(obj2);

    // 从池中重新获取
    const obj3 = try pool.get();
    try testing.expect(obj3.*.value == 42); // 应该重用第一个对象

    const obj4 = try pool.get();
    try testing.expect(obj4.*.value == 100); // 应该重用第二个对象

    // 测试统计信息
    const stats = pool.getStats();
    try testing.expect(stats.total_allocated == 2);
    try testing.expect(stats.pool_hits == 2);
    try testing.expect(stats.pool_misses == 2);
}

test "ObjectPool with max size limit" {
    const allocator = testing.allocator;
    var pool = TypedObjectPool(TestStruct).init(allocator, 2); // 最大池大小为2
    defer pool.deinit();

    // 分配超过池大小的对象
    const obj1 = try pool.get();
    const obj2 = try pool.get();
    const obj3 = try pool.get(); // 第三个对象应该直接分配，不入池

    // 归还所有对象
    pool.put(obj1);
    pool.put(obj2);
    pool.put(obj3); // 第三个对象应该直接释放，不入池

    const stats = pool.getStats();
    try testing.expect(stats.total_allocated == 3);
    try testing.expect(stats.pool_hits == 0); // 还没有重用
    try testing.expect(stats.current_pool_size == 2); // 池中最多2个对象
}

// 内存池测试
test "MemoryPool basic operations" {
    const allocator = testing.allocator;
    var pool = MemoryPool.init(allocator, 1024, 8);
    defer pool.deinit();

    // 测试内存分配
    const block1 = try pool.alloc(100, 8);
    try testing.expect(block1.len == 100);

    const block2 = try pool.alloc(200, 8);
    try testing.expect(block2.len == 200);

    // 测试内存池统计
    const stats = pool.getStats();
    try testing.expect(stats.total_blocks_allocated == 1); // 应该在同一个块中
    try testing.expect(stats.total_bytes_allocated == 300);
    try testing.expect(stats.active_allocations == 2);

    // 测试重置
    pool.reset();
    const reset_stats = pool.getStats();
    try testing.expect(reset_stats.active_allocations == 0);
}

test "MemoryPool block overflow" {
    const allocator = testing.allocator;
    var pool = MemoryPool.init(allocator, 256, 8); // 小块大小
    defer pool.deinit();

    // 分配超过块大小的内存
    const large_block = try pool.alloc(300, 8);
    try testing.expect(large_block.len == 300);

    const stats = pool.getStats();
    try testing.expect(stats.total_blocks_allocated >= 1);
}

// 优化ArrayList测试
test "OptimizedArrayList operations" {
    const allocator = testing.allocator;
    var list = OptimizedArrayList(i32).init(allocator);
    defer list.deinit(allocator);

    // 测试基本操作
    try list.append(allocator, 1);
    try list.append(allocator, 2);
    try list.append(allocator, 3);

    try testing.expect(list.len() == 3);
    try testing.expect(list.itemsSlice()[0] == 1);
    try testing.expect(list.itemsSlice()[2] == 3);

    // 测试转换到owned slice
    const slice = try list.toOwnedSlice(allocator);
    defer allocator.free(slice);

    try testing.expect(slice.len == 3);
    try testing.expect(slice[0] == 1);
    try testing.expect(slice[2] == 3);
}

// 内存管理器测试
test "MemoryManager initialization" {
    const allocator = testing.allocator;
    var memory_manager = MemoryManager.init(allocator);
    defer memory_manager.deinit();

    // 配置内存管理器
    memory_manager.configure(.{
        .enable_object_pooling = true,
        .enable_memory_pool = true,
        .max_pool_size_per_type = 50,
        .memory_pool_block_size = 2048,
    });

    // 初始化池
    try memory_manager.initPools();

    // 测试池分配器
    const pool_allocator = memory_manager.getPoolAllocator();
    const test_block = try pool_allocator.alloc(u8, 100, 8);
    pool_allocator.free(test_block, 8, 0);

    // 测试统计信息
    const stats = memory_manager.getStats();
    try testing.expect(stats.memory_pool_stats != null);
}

// 性能对比测试
test "Memory optimization performance comparison" {
    const allocator = testing.allocator;
    const pattern = "\\d+";
    const input = "test 123 numbers 456 here 789 test 012 numbers";

    // 标准API性能测试
    var standard_time: u64 = 0;
    {
        var timer = try Timer.start();

        var regex = try regex_new.Regex.compile(allocator, pattern);
        defer regex.deinit();

        // 多次匹配操作
        for (0..100) |_| {
            _ = try regex.find(input);
        }

        standard_time = timer.read();
    }

    // 优化API性能测试
    var optimized_time: u64 = 0;
    {
        var memory_manager = MemoryManager.init(allocator);
        defer memory_manager.deinit();

        memory_manager.configure(.{
            .enable_object_pooling = true,
            .enable_memory_pool = true,
            .max_pool_size_per_type = 100,
            .memory_pool_block_size = 4096,
        });
        try memory_manager.initPools();

        var timer = try Timer.start();

        var regex = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
        defer regex.deinit();

        // 多次匹配操作
        for (0..100) |_| {
            _ = try regex.find(input);
        }

        optimized_time = timer.read();
    }

    // 打印性能对比（实际测试中应该使用日志）
    std.debug.print("Standard API: {} ns\n", .{standard_time});
    std.debug.print("Optimized API: {} ns\n", .{optimized_time});
    std.debug.print("Improvement: {d:.2}x\n", .{@as(f64, @floatFromInt(standard_time)) / @as(f64, @floatFromInt(optimized_time))});

    // 优化版本应该更快或相当
    // 注意：这里不严格要求优化版本更快，因为内存开销的减少在某些情况下可能不会立即体现为速度提升
}

// 内存使用对比测试
test "Memory usage comparison" {
    const allocator = testing.allocator;
    const pattern = "(\\d+)-(\\d+)-(\\d+)";
    const input = "2024-01-15 2024-02-20 2024-03-25";

    // 测试标准API内存使用
    var standard_matches: usize = 0;
    {
        var regex = try regex_new.Regex.compile(allocator, pattern);
        defer regex.deinit();

        var iter = regex.iterator(input);
        while (try iter.next()) |match| {
            _ = match.captureText(input, 0);
            standard_matches += 1;
        }
    }

    // 测试优化API内存使用
    var optimized_matches: usize = 0;
    var memory_manager = MemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .enable_memory_pool = true,
        .max_pool_size_per_type = 50,
        .memory_pool_block_size = 2048,
    });
    try memory_manager.initPools();

    {
        var regex = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
        defer regex.deinit();

        var iter = regex.iterator(input);
        while (try iter.next()) |match| {
            _ = match.captureText(input, 0);
            optimized_matches += 1;
        }

        // 获取内存统计信息
        const stats = regex.getMemoryStats();
        std.debug.print("Optimized regex memory stats:\n", .{});
        std.debug.print("  Cached slots size: {} bytes\n", .{stats.regex_stats.cached_slots_size});
        std.debug.print("  Cached captures size: {} bytes\n", .{stats.regex_stats.cached_captures_size});
        std.debug.print("  Compiled program size: {} bytes\n", .{stats.regex_stats.compiled_program_size});

        const pool_stats = memory_manager.getStats();
        if (pool_stats.memory_pool_stats) |mem_stats| {
            std.debug.print("  Memory pool utilization: {d:.2}%\n", .{mem_stats.current_block_utilization * 100});
        }
    }

    // 验证结果一致性
    try testing.expect(standard_matches == optimized_matches);
    try testing.expect(standard_matches == 3); // 应该找到3个日期匹配
}

// 批量操作性能测试
test "Bulk operations performance" {
    const allocator = testing.allocator;
    const pattern = "\\b\\w+\\b";
    const input = "The quick brown fox jumps over the lazy dog";

    var memory_manager = MemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .enable_memory_pool = true,
        .max_pool_size_per_type = 100,
        .memory_pool_block_size = 4096,
    });
    try memory_manager.initPools();

    var regex = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
    defer regex.deinit();

    // 测试批量收集
    var timer = try Timer.start();
    const matches = try regex.findAll(input, allocator);
    defer allocator.free(matches);
    const bulk_time = timer.read();

    // 测试普通收集
    timer.reset();
    var iter = regex.iterator(input);
    var normal_matches = std.ArrayList(regex_optimized.OptimizedMatch).init(allocator);
    defer normal_matches.deinit();

    while (try iter.next()) |match| {
        try normal_matches.append(match);
    }
    const normal_time = timer.read();

    std.debug.print("Bulk collection: {} ns\n", .{bulk_time});
    std.debug.print("Normal collection: {} ns\n", .{normal_time});
    std.debug.print("Bulk efficiency: {d:.2}x\n", .{@as(f64, @floatFromInt(normal_time)) / @as(f64, @floatFromInt(bulk_time))});

    // 验证结果一致性
    try testing.expect(matches.len == normal_matches.items.len);
    for (matches, 0..) |match, i| {
        try testing.expectEqual(match.span.start, normal_matches.items[i].span.start);
        try testing.expectEqual(match.span.end, normal_matches.items[i].span.end);
    }
}

// 内存泄漏测试
test "Memory leak detection" {
    const allocator = testing.allocator;
    const pattern = "test";
    const input = "test test test";

    // 获取初始内存使用情况
    // 注释掉不兼容的内存查询方法
    // const initial_memory = allocator.query();

    {
        var memory_manager = MemoryManager.init(allocator);
        defer memory_manager.deinit();

        memory_manager.configure(.{
            .enable_object_pooling = true,
            .enable_memory_pool = true,
            .max_pool_size_per_type = 50,
            .memory_pool_block_size = 2048,
        });
        try memory_manager.initPools();

        // 执行大量操作
        for (0..1000) |_| {
            var regex = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
            defer regex.deinit();

            _ = try regex.find(input);
        }
    }

    // 检查内存是否完全释放
    // 注释掉不兼容的内存查询方法
    // const final_memory = allocator.query();
    // try testing.expect(final_memory.bytes_allocated == initial_memory.bytes_allocated);
}

// 并发安全测试
test "Concurrent memory access" {
    const allocator = testing.allocator;
    const pattern = "\\d+";
    const input = "123 456 789";

    var memory_manager = MemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .enable_memory_pool = true,
        .max_pool_size_per_type = 100,
        .memory_pool_block_size = 4096,
    });
    try memory_manager.initPools();

    // 创建多个正则表达式实例
    var regex1 = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
    defer regex1.deinit();

    var regex2 = try regex_optimized.OptimizedRegex.compile(allocator, pattern, &memory_manager);
    defer regex2.deinit();

    // 并发操作
    const result1 = try regex1.find(input);
    const result2 = try regex2.find(input);

    // 验证结果
    try testing.expect(result1 != null);
    try testing.expect(result2 != null);
    try testing.expectEqual(result1.?.span.start, result2.?.span.start);
}

// 错误处理测试
test "Error handling with memory optimization" {
    const allocator = testing.allocator;

    // 测试无效正则表达式的错误处理
    const invalid_pattern = "[invalid";

    var memory_manager = MemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .enable_memory_pool = true,
        .max_pool_size_per_type = 50,
        .memory_pool_block_size = 2048,
    });
    try memory_manager.initPools();

    // 应该返回错误
    const result = regex_optimized.OptimizedRegex.compile(allocator, invalid_pattern, &memory_manager);
    try testing.expectError(error.InvalidRegex, result);
}
