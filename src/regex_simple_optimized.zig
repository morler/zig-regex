// 简化的优化正则表达式API
// 使用简化的内存池，提供基本的性能优化

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const regex_new = @import("regex_new.zig");
const simple_memory_pool = @import("simple_memory_pool.zig");
const SimpleMemoryManager = simple_memory_pool.SimpleMemoryManager;

pub const SimpleOptimizedRegex = struct {
    const Self = @This();

    allocator: Allocator,
    memory_manager: *SimpleMemoryManager,
    regex: regex_new.Regex,

    pub fn compile(allocator: Allocator, pattern: []const u8, memory_manager: *SimpleMemoryManager) !Self {
        const regex = try regex_new.Regex.compile(allocator, pattern);

        return Self{
            .allocator = allocator,
            .memory_manager = memory_manager,
            .regex = regex,
        };
    }

    pub fn deinit(self: *Self) void {
        self.regex.deinit();
    }

    pub fn find(self: *const Self, input: []const u8) !?regex_new.Match {
        return self.regex.find(input);
    }

    pub fn isMatch(self: *const Self, input: []const u8) !bool {
        return self.regex.isMatch(input);
    }

    pub fn iterator(self: *const Self, input: []const u8) regex_new.MatchIterator {
        return self.regex.iterator(input);
    }

    pub fn findAll(self: *const Self, input: []const u8, allocator: Allocator) ![]regex_new.Match {
        var iter = self.iterator(input);
        var matches = ArrayList(regex_new.Match).init(allocator);
        defer matches.deinit();

        while (try iter.next()) |match| {
            try matches.append(match);
        }

        return matches.toOwnedSlice();
    }

    pub fn replace(self: *const Self, input: []const u8, replacement: []const u8, allocator: Allocator) ![]u8 {
        return self.regex.replace(input, replacement, allocator);
    }

    pub fn split(self: *const Self, input: []const u8, allocator: Allocator) ![]const []const u8 {
        return self.regex.split(input, allocator);
    }

    // 简单的内存统计
    pub fn getMemoryStats(self: *const Self) struct {
        total_matches: usize,
        total_spans: usize,
    } {
        return .{
            .total_matches = if (self.memory_manager.getMatchPool()) |pool|
                pool.free_objects.items.len
            else
                0,
            .total_spans = if (self.memory_manager.getSpanPool()) |pool|
                pool.free_objects.items.len
            else
                0,
        };
    }
};

// 便捷函数
pub fn compile(allocator: Allocator, pattern: []const u8, memory_manager: *SimpleMemoryManager) !SimpleOptimizedRegex {
    return SimpleOptimizedRegex.compile(allocator, pattern, memory_manager);
}
