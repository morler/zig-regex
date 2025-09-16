// 简化的内存优化系统
// 提供基本的对象池功能，避免复杂的类型依赖

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// 简单的对象池
pub const SimpleObjectPool = struct {
    const Self = @This();

    allocator: Allocator,
    free_objects: ArrayListUnmanaged(*anyopaque),
    object_size: usize,
    max_pool_size: usize,

    pub fn init(allocator: Allocator, object_size: usize, max_pool_size: usize) Self {
        return Self{
            .allocator = allocator,
            .free_objects = ArrayListUnmanaged(*anyopaque).empty,
            .object_size = object_size,
            .max_pool_size = max_pool_size,
        };
    }

    pub fn deinit(self: *Self) void {
        while (self.free_objects.items.len > 0) {
            const obj = self.free_objects.pop();
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
        self.free_objects.deinit(self.allocator);
    }

    pub fn get(self: *Self) !*anyopaque {
        if (self.free_objects.items.len > 0) {
            const obj = self.free_objects.pop();
            return obj;
        }

        const new_obj = try self.allocator.alloc(u8, self.object_size);
        return @as(*anyopaque, @ptrCast(new_obj.ptr));
    }

    pub fn put(self: *Self, obj: *anyopaque) void {
        if (self.free_objects.items.len < self.max_pool_size) {
            self.free_objects.append(self.allocator, obj) catch {
                self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
                return;
            };
        } else {
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
    }

    pub fn clear(self: *Self) void {
        while (self.free_objects.items.len > 0) {
            const obj = self.free_objects.pop();
            self.allocator.free(@as([*]u8, @ptrCast(obj))[0..self.object_size]);
        }
        self.free_objects.clearRetainingCapacity();
    }
};

// 简化的内存管理器
pub const SimpleMemoryManager = struct {
    const Self = @This();

    allocator: Allocator,
    match_pool: ?*SimpleObjectPool = null,
    span_pool: ?*SimpleObjectPool = null,

    config: struct {
        enable_object_pooling: bool = true,
        max_pool_size_per_type: usize = 100,
    } = .{},

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn configure(self: *Self, config: struct {
        enable_object_pooling: bool = true,
        max_pool_size_per_type: usize = 100,
    }) void {
        self.config = config;
    }

    pub fn initPools(self: *Self) !void {
        if (self.config.enable_object_pooling) {
            self.match_pool = try self.allocator.create(SimpleObjectPool);
            self.match_pool.?.* = SimpleObjectPool.init(self.allocator, 64, self.config.max_pool_size_per_type);

            self.span_pool = try self.allocator.create(SimpleObjectPool);
            self.span_pool.?.* = SimpleObjectPool.init(self.allocator, 16, self.config.max_pool_size_per_type);
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.match_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }

        if (self.span_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
    }

    pub fn getMatchPool(self: *Self) ?*SimpleObjectPool {
        return self.match_pool;
    }

    pub fn getSpanPool(self: *Self) ?*SimpleObjectPool {
        return self.span_pool;
    }

    pub fn resetAll(self: *Self) void {
        if (self.match_pool) |pool| {
            pool.clear();
        }

        if (self.span_pool) |pool| {
            pool.clear();
        }
    }
};
