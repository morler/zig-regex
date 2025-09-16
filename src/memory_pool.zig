// 内存管理优化系统
// 提供对象池、内存池和分配器包装功能

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// 对象池接口
pub const ObjectPool = struct {
    const Self = @This();

    allocator: Allocator,
    free_objects: ArrayListUnmanaged(*anyopaque),
    object_size: usize,
    alignment: usize,
    max_pool_size: usize,

    // 统计信息
    stats: struct {
        total_allocated: usize = 0,
        pool_hits: usize = 0,
        pool_misses: usize = 0,
        total_freed: usize = 0,
    } = .{},

    pub fn init(allocator: Allocator, object_size: usize, alignment: usize, max_pool_size: usize) Self {
        return Self{
            .allocator = allocator,
            .free_objects = ArrayListUnmanaged(*anyopaque).empty,
            .object_size = object_size,
            .alignment = alignment,
            .max_pool_size = max_pool_size,
        };
    }

    pub fn deinit(self: *Self) void {
        // 释放所有池中的对象
        while (self.free_objects.items.len > 0) {
            const obj = self.free_objects.orderedRemove(0);
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
        self.free_objects.deinit(self.allocator);
    }

    // 从池中获取对象
    pub fn get(self: *Self) !*anyopaque {
        if (self.free_objects.items.len > 0) {
            const obj = self.free_objects.pop();
            self.stats.pool_hits += 1;
            return obj;
        }

        // 池中没有可用对象，分配新的
        const new_obj = try self.allocator.alloc(u8, self.object_size);
        errdefer self.allocator.free(new_obj);

        self.stats.pool_misses += 1;
        self.stats.total_allocated += 1;

        return @as(*anyopaque, @ptrCast(new_obj.ptr));
    }

    // 归还对象到池中
    pub fn put(self: *Self, obj: *anyopaque) void {
        if (self.free_objects.items.len < self.max_pool_size) {
            self.free_objects.append(self.allocator, obj) catch {
                // 如果池已满，直接释放对象
                self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
                return;
            };
            self.stats.total_freed += 1;
        } else {
            // 池已满，直接释放
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
    }

    // 清空池
    pub fn clear(self: *Self) void {
        while (self.free_objects.items.len > 0) {
            const obj = self.free_objects.pop();
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
        self.free_objects.clearRetainingCapacity();
    }

    // 获取统计信息
    pub fn getStats(self: *const Self) struct {
        total_allocated: usize,
        pool_hits: usize,
        pool_misses: usize,
        total_freed: usize,
        hit_rate: f64,
        current_pool_size: usize,
    } {
        const total_requests = self.stats.pool_hits + self.stats.pool_misses;
        const hit_rate = if (total_requests > 0)
            @as(f64, @floatFromInt(self.stats.pool_hits)) / @as(f64, @floatFromInt(total_requests))
        else
            0.0;

        return .{
            .total_allocated = self.stats.total_allocated,
            .pool_hits = self.stats.pool_hits,
            .pool_misses = self.stats.pool_misses,
            .total_freed = self.stats.total_freed,
            .hit_rate = hit_rate,
            .current_pool_size = self.free_objects.items.len,
        };
    }
};

// 类型安全的对象池包装器
pub fn TypedObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();
        pool: ObjectPool,

        pub fn init(allocator: Allocator, max_pool_size: usize) Self {
            return Self{
                .pool = ObjectPool.init(allocator, @sizeOf(T), @alignOf(T), max_pool_size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn get(self: *Self) !*T {
            const obj = try self.pool.get();
            return @as(*T, @ptrCast(obj));
        }

        pub fn put(self: *Self, obj: *T) void {
            self.pool.put(@as(*anyopaque, @ptrCast(obj)));
        }

        pub fn clear(self: *Self) void {
            self.pool.clear();
        }

        pub fn getStats(self: *const Self) ObjectPool.Stats {
            return self.pool.getStats();
        }
    };
}

// 内存池分配器
pub const MemoryPool = struct {
    const Self = @This();

    allocator: Allocator,
    blocks: ArrayListUnmanaged([]u8),
    current_block: []u8,
    current_offset: usize,
    block_size: usize,
    alignment: usize,

    // 统计信息
    stats: struct {
        total_blocks_allocated: usize = 0,
        total_bytes_allocated: usize = 0,
        active_allocations: usize = 0,
        peak_memory_usage: usize = 0,
    } = .{},

    pub fn init(allocator: Allocator, block_size: usize, alignment: usize) Self {
        return Self{
            .allocator = allocator,
            .blocks = ArrayListUnmanaged([]u8).empty,
            .current_block = &[_]u8{},
            .current_offset = 0,
            .block_size = block_size,
            .alignment = alignment,
        };
    }

    pub fn deinit(self: *Self) void {
        // 释放所有内存块
        for (self.blocks.items) |block| {
            self.allocator.free(block);
        }
        self.blocks.deinit(self.allocator);

        if (self.current_block.len > 0) {
            self.allocator.free(self.current_block);
        }
    }

    // 分配内存
    pub fn alloc(self: *Self, size: usize, alignment: usize) ![]u8 {
        const actual_alignment = @max(alignment, self.alignment);
        const adjusted_size = std.mem.alignForward(usize, size, actual_alignment);

        // 检查当前块是否有足够空间
        if (self.current_offset + adjusted_size <= self.current_block.len) {
            const result = self.current_block[self.current_offset .. self.current_offset + adjusted_size];
            self.current_offset += adjusted_size;

            self.stats.total_bytes_allocated += adjusted_size;
            self.stats.active_allocations += 1;
            self.stats.peak_memory_usage = @max(self.stats.peak_memory_usage, self.stats.total_bytes_allocated);

            return result;
        }

        // 需要分配新块
        const new_block_size = @max(self.block_size, adjusted_size);
        const new_block = try self.allocator.alloc(u8, new_block_size);
        errdefer self.allocator.free(new_block);

        // 保存当前块（如果还有内容）
        if (self.current_block.len > 0 and self.current_offset > 0) {
            try self.blocks.append(self.allocator, self.current_block);
        }

        // 切换到新块
        self.current_block = new_block;
        self.current_offset = adjusted_size;
        self.stats.total_blocks_allocated += 1;

        const result = new_block[0..adjusted_size];
        self.stats.total_bytes_allocated += adjusted_size;
        self.stats.active_allocations += 1;
        self.stats.peak_memory_usage = @max(self.stats.peak_memory_usage, self.stats.total_bytes_allocated);

        return result;
    }

    // 重置内存池（释放所有分配但不释放内存块）
    pub fn reset(self: *Self) void {
        self.current_offset = 0;
        self.stats.active_allocations = 0;

        // 如果有多个块，保留第一个块，释放其余的
        if (self.blocks.items.len > 0) {
            // 释放第一个块以外的所有块
            for (self.blocks.items[1..]) |block| {
                self.allocator.free(block);
            }

            // 保留第一个块作为当前块
            if (self.blocks.items.len > 0) {
                self.current_block = self.blocks.items[0];
                self.blocks.items.len = 1;
            }
        }
    }

    // 获取统计信息
    pub fn getStats(self: *const Self) struct {
        total_blocks_allocated: usize,
        total_bytes_allocated: usize,
        active_allocations: usize,
        peak_memory_usage: usize,
        current_block_size: usize,
        current_block_used: usize,
        current_block_utilization: f64,
    } {
        const utilization = if (self.current_block.len > 0)
            @as(f64, @floatFromInt(self.current_offset)) / @as(f64, @floatFromInt(self.current_block.len))
        else
            0.0;

        return .{
            .total_blocks_allocated = self.stats.total_blocks_allocated,
            .total_bytes_allocated = self.stats.total_bytes_allocated,
            .active_allocations = self.stats.active_allocations,
            .peak_memory_usage = self.stats.peak_memory_usage,
            .current_block_size = self.current_block.len,
            .current_block_used = self.current_offset,
            .current_block_utilization = utilization,
        };
    }
};

// 内存池分配器包装器
pub const PoolAllocator = struct {
    const Self = @This();

    parent_allocator: Allocator,
    pool: *MemoryPool,

    pub fn init(parent_allocator: Allocator, pool: *MemoryPool) Self {
        return Self{
            .parent_allocator = parent_allocator,
            .pool = pool,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self = @as(*Self, @ptrCast(@alignCast(ctx)));
        const alignment = @as(usize, 1) << @as(u6, @intFromEnum(ptr_align));

        const result = self.pool.alloc(len, alignment) catch return null;
        return result.ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        // 内存池不支持调整大小
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // 内存池不支持单独释放，通过reset()批量释放
    }

    fn remap(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = old_mem;
        _ = new_len;
        _ = alignment;
        _ = ret_addr;
        // 内存池不支持重映射
        return null;
    }
};

// 缓存友好的ArrayList优化
pub fn OptimizedArrayList(comptime T: type) type {
    return struct {
        const Self = @This();

        items: ArrayListUnmanaged(T),
        pool: ?*TypedObjectPool(T) = null,

        pub fn init(allocator: Allocator) Self {
            _ = allocator;
            return Self{
                .items = ArrayListUnmanaged(T).empty,
            };
        }

        pub fn initWithPool(pool: *TypedObjectPool(T)) Self {
            return Self{
                .items = ArrayListUnmanaged(T).empty,
                .pool = pool,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.pool == null) {
                self.items.deinit(allocator);
            } else {
                // 如果使用对象池，清空数组但不释放内存
                self.items.clearAndFree(allocator);
            }
        }

        pub fn append(self: *Self, allocator: Allocator, item: T) !void {
            try self.items.append(allocator, item);
        }

        pub fn toOwnedSlice(self: *Self, allocator: Allocator) ![]T {
            return self.items.toOwnedSlice(allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.items.clearRetainingCapacity();
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn itemsSlice(self: *const Self) []T {
            return self.items.items;
        }
    };
}

// 全局内存管理器
pub const MemoryManager = struct {
    const Self = @This();

    allocator: Allocator,

    // 预定义的对象池 - 使用usize作为占位符类型
    match_pool: ?*TypedObjectPool(usize) = null,
    span_pool: ?*TypedObjectPool(usize) = null,
    iterator_pool: ?*TypedObjectPool(usize) = null,

    // 内存池
    memory_pool: ?*MemoryPool = null,
    pool_allocator: PoolAllocator = undefined,

    // 配置
    config: Config = .{},

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn configure(self: *Self, config: Config) void {
        self.config = config;
    }

    const Config = struct {
        enable_object_pooling: bool = true,
        enable_memory_pool: bool = true,
        max_pool_size_per_type: usize = 100,
        memory_pool_block_size: usize = 4096,
    };

    pub fn initPools(self: *Self) !void {
        if (self.config.enable_object_pooling) {
            // 简化对象池初始化
            // 简化对象池初始化 - 使用具体类型而不是anyopaque
            // 对于通用对象池，我们使用usize作为占位符类型
            const PoolPlaceholder = usize;
            self.match_pool = try self.allocator.create(TypedObjectPool(PoolPlaceholder));
            self.match_pool.?.* = TypedObjectPool(PoolPlaceholder).init(self.allocator, self.config.max_pool_size_per_type);

            self.span_pool = try self.allocator.create(TypedObjectPool(PoolPlaceholder));
            self.span_pool.?.* = TypedObjectPool(PoolPlaceholder).init(self.allocator, self.config.max_pool_size_per_type * 10);

            self.iterator_pool = try self.allocator.create(TypedObjectPool(PoolPlaceholder));
            self.iterator_pool.?.* = TypedObjectPool(PoolPlaceholder).init(self.allocator, self.config.max_pool_size_per_type / 2);
        }

        if (self.config.enable_memory_pool) {
            // 初始化内存池
            self.memory_pool = try self.allocator.create(MemoryPool);
            self.memory_pool.?.* = MemoryPool.init(self.allocator, self.config.memory_pool_block_size, 8);

            self.pool_allocator = PoolAllocator.init(self.allocator, self.memory_pool.?);
        }
    }

    pub fn deinit(self: *Self) void {
        // 清理对象池
        if (self.match_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        if (self.span_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        if (self.iterator_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        // 清理内存池
        if (self.memory_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        if (self.memory_pool != null) {
            self.allocator.destroy(self.memory_pool.?);
        }
    }

    // 获取池化分配器
    pub fn getPoolAllocator(self: *Self) Allocator {
        if (self.memory_pool != null) {
            return self.pool_allocator.allocator();
        }
        return self.allocator;
    }

    // 获取Match对象池
    pub fn getMatchPool(self: *Self) ?*TypedObjectPool(usize) {
        return self.match_pool;
    }

    // 获取Span对象池
    pub fn getSpanPool(self: *Self) ?*TypedObjectPool(usize) {
        return self.span_pool;
    }

    // 获取迭代器对象池
    pub fn getIteratorPool(self: *Self) ?*TypedObjectPool(usize) {
        return self.iterator_pool;
    }

    // 重置所有池
    pub fn resetAll(self: *Self) void {
        if (self.match_pool) |pool| {
            pool.clear();
        }

        if (self.span_pool) |pool| {
            pool.clear();
        }

        if (self.iterator_pool) |pool| {
            pool.clear();
        }

        if (self.memory_pool) |pool| {
            pool.reset();
        }
    }

    // 获取统计信息
    pub fn getStats(self: *const Self) void {
        // 简化版本，只打印统计信息
        if (self.match_pool) |pool| {
            const stats = pool.getStats();
            std.debug.print("Match Pool: {} hits, {} misses, {d:.1f}% hit rate\n", .{
                stats.pool_hits, stats.pool_misses, stats.hit_rate * 100,
            });
        }
    }
};
