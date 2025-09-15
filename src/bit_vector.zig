const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;

// 位向量数据结构，用于高效管理NFA线程集合
pub const BitVector = struct {
    // 位向量数据，每个bit代表一个状态
    data: []usize,
    // 位向量容量（最大状态数）
    capacity: usize,
    // 分配器
    allocator: Allocator,

    // 每个usize的位数
    const BITS_PER_USIZE = @bitSizeOf(usize);

    // 初始化位向量
    pub fn init(allocator: Allocator, capacity: usize) !BitVector {
        const words_needed = (capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        const data = try allocator.alloc(usize, words_needed);
        @memset(data, 0);

        return BitVector{
            .data = data,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    // 释放位向量
    pub fn deinit(self: *BitVector) void {
        self.allocator.free(self.data);
    }

    // 清空所有位
    pub fn clear(self: *BitVector) void {
        @memset(self.data, 0);
    }

    // 设置指定位为1
    pub fn set(self: *BitVector, index: usize) void {
        std.debug.assert(index < self.capacity);
        const word_index = index / BITS_PER_USIZE;
        const bit_index: u6 = @intCast(index % BITS_PER_USIZE);
        self.data[word_index] |= @as(usize, 1) << bit_index;
    }

    // 清除指定位为0
    pub fn unset(self: *BitVector, index: usize) void {
        std.debug.assert(index < self.capacity);
        const word_index = index / BITS_PER_USIZE;
        const bit_index: u6 = @intCast(index % BITS_PER_USIZE);
        self.data[word_index] &= ~(@as(usize, 1) << bit_index);
    }

    // 检查指定位是否为1
    pub fn get(self: *const BitVector, index: usize) bool {
        std.debug.assert(index < self.capacity);
        const word_index = index / BITS_PER_USIZE;
        const bit_index: u6 = @intCast(index % BITS_PER_USIZE);
        return (self.data[word_index] & (@as(usize, 1) << bit_index)) != 0;
    }

    // 克隆位向量
    pub fn clone(self: *const BitVector) !BitVector {
        const new_data = try self.allocator.alloc(usize, self.data.len);
        @memcpy(new_data, self.data);

        return BitVector{
            .data = new_data,
            .capacity = self.capacity,
            .allocator = self.allocator,
        };
    }

    // 获取位向量的底层数据
    pub fn getBits(self: *const BitVector) []usize {
        return self.data;
    }

    // 获取第一个为1的位的索引
    pub fn firstSet(self: *const BitVector) ?usize {
        for (self.data, 0..) |word, word_index| {
            if (word != 0) {
                const bit_index = @ctz(word);
                return word_index * BITS_PER_USIZE + bit_index;
            }
        }
        return null;
    }

    // 获取下一个为1的位的索引
    pub fn nextSet(self: *const BitVector, start: usize) ?usize {
        // 从start+1开始查找
        const search_start = start + 1;
        if (search_start >= self.capacity) return null;

        const word_index = search_start / BITS_PER_USIZE;
        const bit_index: u6 = @intCast(search_start % BITS_PER_USIZE);

        // 检查当前word的剩余位
        const current_word = self.data[word_index] >> bit_index;
        if (current_word != 0) {
            const offset = @ctz(current_word);
            const result = search_start + offset;
            if (result < self.capacity) {
                return result;
            }
        }

        // 检查后续的word
        for (self.data[word_index + 1 ..], 0..) |word, offset| {
            if (word != 0) {
                const found_bit_index = @ctz(word);
                const result = (word_index + 1 + offset) * BITS_PER_USIZE + found_bit_index;
                if (result < self.capacity) {
                    return result;
                }
            }
        }

        return null;
    }

    // 计算为1的位的数量
    pub fn count(self: *const BitVector) usize {
        var total: usize = 0;
        for (self.data) |word| {
            total += @popCount(word);
        }
        return total;
    }

    // 检查是否为空
    pub fn isEmpty(self: *const BitVector) bool {
        for (self.data) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    // 复制另一个位向量
    pub fn copyFrom(self: *BitVector, other: *const BitVector) void {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_copy = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        @memcpy(self.data[0..words_to_copy], other.data[0..words_to_copy]);

        // 清除剩余的word
        if (self.data.len > words_to_copy) {
            @memset(self.data[words_to_copy..], 0);
        }
    }

    // 并集操作：self = self OR other
    pub fn unionWith(self: *BitVector, other: *const BitVector) void {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_operate = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        for (self.data[0..words_to_operate], other.data[0..words_to_operate]) |*self_word, other_word| {
            self_word.* |= other_word;
        }
    }

    // 交集操作：self = self AND other
    pub fn intersectWith(self: *BitVector, other: *const BitVector) void {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_operate = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        for (self.data[0..words_to_operate], other.data[0..words_to_operate]) |*self_word, other_word| {
            self_word.* &= other_word;
        }

        // 清除剩余的word
        if (self.data.len > words_to_operate) {
            @memset(self.data[words_to_operate..], 0);
        }
    }

    // 差集操作：self = self AND (NOT other)
    pub fn differenceWith(self: *BitVector, other: *const BitVector) void {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_operate = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        for (self.data[0..words_to_operate], other.data[0..words_to_operate]) |*self_word, other_word| {
            self_word.* &= ~other_word;
        }
    }

    // 检查是否包含另一个位向量的所有位
    pub fn containsAll(self: *const BitVector, other: *const BitVector) bool {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_check = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        for (self.data[0..words_to_check], other.data[0..words_to_check]) |self_word, other_word| {
            if ((self_word & other_word) != other_word) {
                return false;
            }
        }
        return true;
    }

    // 检查是否有交集
    pub fn intersects(self: *const BitVector, other: *const BitVector) bool {
        std.debug.assert(self.capacity >= other.capacity);
        const words_to_check = (other.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        for (self.data[0..words_to_check], other.data[0..words_to_check]) |self_word, other_word| {
            if ((self_word & other_word) != 0) {
                return true;
            }
        }
        return false;
    }

    // 调整容量
    pub fn resize(self: *BitVector, new_capacity: usize) !void {
        const new_words_needed = (new_capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;
        const old_words_needed = (self.capacity + BITS_PER_USIZE - 1) / BITS_PER_USIZE;

        if (new_words_needed != old_words_needed) {
            self.allocator.free(self.data);
            self.data = try self.allocator.alloc(usize, new_words_needed);
            @memset(self.data, 0);
        }

        self.capacity = new_capacity;
    }

    // 交换两个位向量
    pub fn swap(self: *BitVector, other: *BitVector) void {
        std.mem.swap(usize, &self.capacity, &other.capacity);
        std.mem.swap([]usize, &self.data, &other.data);
        std.mem.swap(Allocator, &self.allocator, &other.allocator);
    }
};

// 线程集合，使用位向量高效管理NFA状态
pub const ThreadSet = struct {
    // 当前活跃的线程集合
    current: BitVector,
    // 下一个状态的线程集合
    next: BitVector,
    // 临时工作用的位向量
    temp: BitVector,
    // 分配器
    allocator: Allocator,

    // 初始化线程集合
    pub fn init(allocator: Allocator, capacity: usize) !ThreadSet {
        return ThreadSet{
            .current = try BitVector.init(allocator, capacity),
            .next = try BitVector.init(allocator, capacity),
            .temp = try BitVector.init(allocator, capacity),
            .allocator = allocator,
        };
    }

    // 释放线程集合
    pub fn deinit(self: *ThreadSet) void {
        self.current.deinit();
        self.next.deinit();
        self.temp.deinit();
    }

    // 清空所有线程
    pub fn clear(self: *ThreadSet) void {
        self.current.clear();
        self.next.clear();
        self.temp.clear();
    }

    // 添加线程到当前集合
    pub fn addThread(self: *ThreadSet, state: usize) void {
        self.current.set(state);
    }

    // 检查线程是否在当前集合中
    pub fn hasThread(self: *ThreadSet, state: usize) bool {
        return self.current.get(state);
    }

    // 获取当前线程数量
    pub fn count(self: *ThreadSet) usize {
        return self.current.count();
    }

    // 检查当前集合是否为空
    pub fn isEmpty(self: *ThreadSet) bool {
        return self.current.isEmpty();
    }

    // 获取第一个线程状态
    pub fn firstThread(self: *ThreadSet) ?usize {
        return self.current.firstSet();
    }

    // 获取下一个线程状态
    pub fn nextThread(self: *ThreadSet, start: usize) ?usize {
        return self.current.nextSet(start);
    }

    // 准备下一个状态集合
    pub fn prepareNext(self: *ThreadSet) void {
        self.next.clear();
    }

    // 添加线程到下一个状态集合
    pub fn addToNext(self: *ThreadSet, state: usize) void {
        self.next.set(state);
    }

    // 切换到下一个状态集合
    pub fn switchToNext(self: *ThreadSet) void {
        self.current.swap(&self.next);
    }

    // 获取临时工作位向量
    pub fn getTemp(self: *ThreadSet) *BitVector {
        return &self.temp;
    }

    // 复制当前集合到临时位向量
    pub fn copyToTemp(self: *ThreadSet) void {
        self.temp.copyFrom(&self.current);
    }

    // 从临时位向量恢复当前集合
    pub fn restoreFromTemp(self: *ThreadSet) void {
        self.current.copyFrom(&self.temp);
    }

    // 调整容量
    pub fn resize(self: *ThreadSet, new_capacity: usize) !void {
        try self.current.resize(new_capacity);
        try self.next.resize(new_capacity);
        try self.temp.resize(new_capacity);
    }
};

test "BitVector basic operations" {
    const allocator = std.testing.allocator;
    var bv = try BitVector.init(allocator, 100);
    defer bv.deinit();

    // 测试设置和获取
    try std.testing.expect(!bv.get(0));
    try std.testing.expect(!bv.get(1));
    try std.testing.expect(!bv.get(99));

    bv.set(0);
    bv.set(1);
    bv.set(99);

    try std.testing.expect(bv.get(0));
    try std.testing.expect(bv.get(1));
    try std.testing.expect(bv.get(99));
    try std.testing.expect(!bv.get(2));

    // 测试清除
    bv.unset(1);
    try std.testing.expect(bv.get(0));
    try std.testing.expect(!bv.get(1));
    try std.testing.expect(bv.get(99));

    // 测试清空
    bv.clear();
    try std.testing.expect(!bv.get(0));
    try std.testing.expect(!bv.get(99));
    try std.testing.expect(bv.isEmpty());
}

test "BitVector set operations" {
    const allocator = std.testing.allocator;
    var bv1 = try BitVector.init(allocator, 100);
    var bv2 = try BitVector.init(allocator, 100);
    defer bv1.deinit();
    defer bv2.deinit();

    // 设置测试数据
    bv1.set(1);
    bv1.set(3);
    bv1.set(5);

    bv2.set(3);
    bv2.set(5);
    bv2.set(7);

    // 测试并集
    var bv_union = try BitVector.init(allocator, 100);
    defer bv_union.deinit();
    bv_union.copyFrom(&bv1);
    bv_union.unionWith(&bv2);

    try std.testing.expect(bv_union.get(1));
    try std.testing.expect(bv_union.get(3));
    try std.testing.expect(bv_union.get(5));
    try std.testing.expect(bv_union.get(7));

    // 测试交集
    var bv_intersect = try BitVector.init(allocator, 100);
    defer bv_intersect.deinit();
    bv_intersect.copyFrom(&bv1);
    bv_intersect.intersectWith(&bv2);

    try std.testing.expect(!bv_intersect.get(1));
    try std.testing.expect(bv_intersect.get(3));
    try std.testing.expect(bv_intersect.get(5));
    try std.testing.expect(!bv_intersect.get(7));

    // 测试差集
    var bv_diff = try BitVector.init(allocator, 100);
    defer bv_diff.deinit();
    bv_diff.copyFrom(&bv1);
    bv_diff.differenceWith(&bv2);

    try std.testing.expect(bv_diff.get(1));
    try std.testing.expect(!bv_diff.get(3));
    try std.testing.expect(!bv_diff.get(5));
    try std.testing.expect(!bv_diff.get(7));
}

test "BitVector iteration" {
    const allocator = std.testing.allocator;
    var bv = try BitVector.init(allocator, 100);
    defer bv.deinit();

    // 设置测试数据
    bv.set(5);
    bv.set(10);
    bv.set(15);
    bv.set(20);

    // 测试firstSet
    try std.testing.expectEqual(@as(usize, 5), bv.firstSet().?);

    // 测试nextSet
    try std.testing.expectEqual(@as(usize, 10), bv.nextSet(5).?);
    try std.testing.expectEqual(@as(usize, 15), bv.nextSet(10).?);
    try std.testing.expectEqual(@as(usize, 20), bv.nextSet(15).?);
    try std.testing.expectEqual(@as(?usize, null), bv.nextSet(20));

    // 测试count
    try std.testing.expectEqual(@as(usize, 4), bv.count());
}

test "ThreadSet operations" {
    const allocator = std.testing.allocator;
    var ts = try ThreadSet.init(allocator, 100);
    defer ts.deinit();

    // 测试添加线程
    ts.addThread(1);
    ts.addThread(3);
    ts.addThread(5);

    try std.testing.expect(ts.hasThread(1));
    try std.testing.expect(ts.hasThread(3));
    try std.testing.expect(ts.hasThread(5));
    try std.testing.expect(!ts.hasThread(2));

    // 测试线程数量
    try std.testing.expectEqual(@as(usize, 3), ts.count());

    // 测试迭代
    try std.testing.expectEqual(@as(usize, 1), ts.firstThread().?);
    try std.testing.expectEqual(@as(usize, 3), ts.nextThread(1).?);
    try std.testing.expectEqual(@as(usize, 5), ts.nextThread(3).?);
    try std.testing.expectEqual(@as(?usize, null), ts.nextThread(5));

    // 测试下一个状态集合
    ts.prepareNext();
    ts.addToNext(2);
    ts.addToNext(4);
    ts.addToNext(6);

    // 当前集合应该还是原来的
    try std.testing.expect(ts.hasThread(1));
    try std.testing.expect(!ts.hasThread(2));

    // 切换到下一个集合
    ts.switchToNext();
    try std.testing.expect(!ts.hasThread(1));
    try std.testing.expect(ts.hasThread(2));
    try std.testing.expect(ts.hasThread(4));
    try std.testing.expect(ts.hasThread(6));
}
