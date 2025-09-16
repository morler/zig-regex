// 简化的内存优化测试
// 测试基本的内存池功能

const std = @import("std");
const testing = std.testing;

const simple_memory_pool = @import("simple_memory_pool.zig");
const SimpleObjectPool = simple_memory_pool.SimpleObjectPool;
const SimpleMemoryManager = simple_memory_pool.SimpleMemoryManager;
const regex_simple_optimized = @import("regex_simple_optimized.zig");
const SimpleOptimizedRegex = regex_simple_optimized.SimpleOptimizedRegex;

test "SimpleObjectPool basic operations" {
    const allocator = testing.allocator;
    var pool = SimpleObjectPool.init(allocator, 64, 10);
    defer pool.deinit();

    // 测试对象分配和回收
    const obj1 = try pool.get();
    const obj2 = try pool.get();

    // 归还对象
    pool.put(obj1);
    pool.put(obj2);

    // 从池中重新获取
    const obj3 = try pool.get();
    const obj4 = try pool.get();

    // 验证对象数量
    try testing.expect(pool.free_objects.items.len == 8); // 10 - 2
}

test "SimpleMemoryManager basic operations" {
    const allocator = testing.allocator;
    var memory_manager = SimpleMemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .max_pool_size_per_type = 50,
    });
    try memory_manager.initPools();

    // 验证池已创建
    try testing.expect(memory_manager.getMatchPool() != null);
    try testing.expect(memory_manager.getSpanPool() != null);
}

test "SimpleOptimizedRegex basic operations" {
    const allocator = testing.allocator;
    var memory_manager = SimpleMemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .max_pool_size_per_type = 50,
    });
    try memory_manager.initPools();

    var regex = try SimpleOptimizedRegex.compile(allocator, "\\d+", &memory_manager);
    defer regex.deinit();

    const match = try regex.find("test 123 numbers");
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?.text("test 123 numbers"), "123"));

    // 测试内存统计
    const stats = regex.getMemoryStats();
    try testing.expect(stats.total_matches >= 0);
    try testing.expect(stats.total_spans >= 0);
}

test "SimpleOptimizedRegex findAll" {
    const allocator = testing.allocator;
    var memory_manager = SimpleMemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .max_pool_size_per_type = 50,
    });
    try memory_manager.initPools();

    var regex = try SimpleOptimizedRegex.compile(allocator, "\\d+", &memory_manager);
    defer regex.deinit();

    const matches = try regex.findAll("test 123 numbers 456 here", allocator);
    defer allocator.free(matches);

    try testing.expect(matches.len == 2);
    try testing.expect(std.mem.eql(u88, matches[0].text("test 123 numbers 456 here"), "123"));
    try testing.expect(std.mem.eql(u88, matches[1].text("test 123 numbers 456 here"), "456"));
}

test "SimpleOptimizedRegex replace" {
    const allocator = testing.allocator;
    var memory_manager = SimpleMemoryManager.init(allocator);
    defer memory_manager.deinit();

    memory_manager.configure(.{
        .enable_object_pooling = true,
        .max_pool_size_per_type = 50,
    });
    try memory_manager.initPools();

    var regex = try SimpleOptimizedRegex.compile(allocator, "\\d+", &memory_manager);
    defer regex.deinit();

    const result = try regex.replace("test 123 numbers 456", "NUM", allocator);
    defer allocator.free(result);

    try testing.expect(std.mem.eql(u8, result, "test NUM numbers NUM"));
}
