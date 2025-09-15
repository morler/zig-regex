const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

/// Boyer-Moore字符串匹配算法实现
pub const BoyerMoore = struct {
    allocator: Allocator,
    pattern: []const u8,
    /// 坏字符规则表：对于每个字符，存储它在模式中最右边的位置
    bad_char: [256]isize,
    /// 好后缀规则预处理数据（简化版，仅实现坏字符规则）
    pattern_len: usize,

    const BAD_CHAR_INIT: isize = -1;

    pub fn init(allocator: Allocator, pattern: []const u8) !BoyerMoore {
        var bm = BoyerMoore{
            .allocator = allocator,
            .pattern = try allocator.dupe(u8, pattern),
            .bad_char = undefined,
            .pattern_len = pattern.len,
        };

        // 预处理坏字符表
        bm.preprocessBadChar();

        return bm;
    }

    pub fn deinit(self: *BoyerMoore) void {
        self.allocator.free(self.pattern);
    }

    /// 预处理坏字符规则表
    fn preprocessBadChar(self: *BoyerMoore) void {
        // 初始化所有字符为-1
        for (&self.bad_char) |*entry| {
            entry.* = BAD_CHAR_INIT;
        }

        // 记录每个字符在模式中最右边的位置
        for (self.pattern, 0..) |c, i| {
            self.bad_char[c] = @intCast(i);
        }
    }

    /// 在文本中搜索模式
    pub fn search(self: *const BoyerMoore, text: []const u8) ?usize {
        if (self.pattern_len == 0) return 0;
        if (text.len < self.pattern_len) return null;

        var i: usize = 0; // 文本中的当前位置
        const n = text.len;
        const m = self.pattern_len;

        while (i <= n - m) {
            var j: isize = @intCast(m - 1); // 从模式末尾开始比较

            // 从右向左匹配
            while (j >= 0 and text[i + @as(usize, @intCast(j))] == self.pattern[@as(usize, @intCast(j))]) {
                j -= 1;
            }

            if (j < 0) {
                // 找到匹配
                return i;
            } else {
                // 计算坏字符跳跃距离
                const bad_char_shift = self.badCharShift(text[i + @as(usize, @intCast(j))], @as(usize, @intCast(j)));
                i += bad_char_shift;
            }
        }

        return null; // 未找到匹配
    }

    /// 查找所有匹配位置
    pub fn findAll(self: *const BoyerMoore, text: []const u8, allocator: Allocator) ![]usize {
        var positions = std.ArrayListUnmanaged(usize){};
        defer positions.deinit(allocator);

        if (self.pattern_len == 0) {
            // 空模式匹配每个位置
            var i: usize = 0;
            while (i <= text.len) : (i += 1) {
                try positions.append(allocator, i);
            }
            return positions.toOwnedSlice(allocator);
        }

        if (text.len < self.pattern_len) {
            return allocator.alloc(usize, 0);
        }

        var i: usize = 0;
        const n = text.len;
        const m = self.pattern_len;

        while (i <= n - m) {
            var j: isize = @intCast(m - 1);

            while (j >= 0 and text[i + @as(usize, @intCast(j))] == self.pattern[@as(usize, @intCast(j))]) {
                j -= 1;
            }

            if (j < 0) {
                // 找到匹配
                try positions.append(allocator, i);
                // 跳到下一个可能的位置
                i += 1;
            } else {
                const bad_char_shift = self.badCharShift(text[i + @as(usize, @intCast(j))], @as(usize, @intCast(j)));
                i += bad_char_shift;
            }
        }

        return positions.toOwnedSlice(allocator);
    }

    /// 计算坏字符规则的跳跃距离
    fn badCharShift(self: *const BoyerMoore, char: u8, pos_in_pattern: usize) usize {
        const char_pos_in_pattern = self.bad_char[char];

        if (char_pos_in_pattern == BAD_CHAR_INIT) {
            // 字符不在模式中，安全跳过整个模式
            return pos_in_pattern + 1;
        }

        const char_pos = @as(usize, @intCast(char_pos_in_pattern));
        if (char_pos < pos_in_pattern) {
            // 字符在模式中出现在当前位置左边
            return pos_in_pattern - char_pos;
        } else {
            // 字符出现在当前位置右边，安全跳过
            return pos_in_pattern + 1;
        }
    }

    /// 检查模式是否为空
    pub fn isEmpty(self: *const BoyerMoore) bool {
        return self.pattern_len == 0;
    }

    /// 获取模式长度
    pub fn patternLength(self: *const BoyerMoore) usize {
        return self.pattern_len;
    }

    /// 克隆Boyer-Moore实例
    pub fn clone(self: *const BoyerMoore) !BoyerMoore {
        return init(self.allocator, self.pattern);
    }
};

/// 简化的Boyer-Moore算法（仅坏字符规则）
pub const SimpleBoyerMoore = struct {
    pattern: []const u8,
    bad_char: [256]isize,
    pattern_len: usize,

    const BAD_CHAR_INIT: isize = -1;

    /// 初始化简化的Boyer-Moore算法
    pub fn init(pattern: []const u8) SimpleBoyerMoore {
        var bm = SimpleBoyerMoore{
            .pattern = pattern,
            .bad_char = undefined,
            .pattern_len = pattern.len,
        };

        // 预处理坏字符表
        for (&bm.bad_char) |*entry| {
            entry.* = BAD_CHAR_INIT;
        }

        for (pattern, 0..) |c, i| {
            bm.bad_char[c] = @intCast(i);
        }

        return bm;
    }

    /// 搜索第一个匹配位置
    pub fn search(self: *const SimpleBoyerMoore, text: []const u8) ?usize {
        if (self.pattern_len == 0) return 0;
        if (text.len < self.pattern_len) return null;

        var i: usize = 0;
        const n = text.len;
        const m = self.pattern_len;

        while (i <= n - m) {
            var j: isize = @intCast(m - 1);

            while (j >= 0 and text[i + @as(usize, @intCast(j))] == self.pattern[@as(usize, @intCast(j))]) {
                j -= 1;
            }

            if (j < 0) {
                return i;
            } else {
                const shift = self.badCharShift(text[i + @as(usize, @intCast(j))], @as(usize, @intCast(j)));
                i += shift;
            }
        }

        return null;
    }

    /// 检查是否存在匹配
    pub fn contains(self: *const SimpleBoyerMoore, text: []const u8) bool {
        return self.search(text) != null;
    }

    /// 计算坏字符跳跃距离
    fn badCharShift(self: *const SimpleBoyerMoore, char: u8, pos_in_pattern: usize) usize {
        const char_pos_in_pattern = self.bad_char[char];

        if (char_pos_in_pattern == BAD_CHAR_INIT) {
            // 字符不在模式中，安全跳过整个模式
            return pos_in_pattern + 1;
        }

        const char_pos = @as(usize, @intCast(char_pos_in_pattern));
        if (char_pos < pos_in_pattern) {
            return pos_in_pattern - char_pos;
        } else {
            return pos_in_pattern + 1;
        }
    }
};

// 测试用例
test "Boyer-Moore basic functionality" {
    const allocator = std.testing.allocator;

    // 简单测试
    {
        const pattern = "ABABC";
        var bm = try BoyerMoore.init(allocator, pattern);
        defer bm.deinit();

        const text = "ABABABABC";
        const pos = bm.search(text);
        try std.testing.expect(pos != null);
        try std.testing.expectEqual(@as(usize, 4), pos.?);
    }

    // 空模式测试
    {
        var bm = try BoyerMoore.init(allocator, "");
        defer bm.deinit();

        const text = "hello";
        const pos = bm.search(text);
        try std.testing.expect(pos != null);
        try std.testing.expectEqual(@as(usize, 0), pos.?);
    }

    // 未找到测试
    {
        const pattern = "XYZ";
        var bm = try BoyerMoore.init(allocator, pattern);
        defer bm.deinit();

        const text = "ABCDEFG";
        const pos = bm.search(text);
        try std.testing.expect(pos == null);
    }

    // 重复模式测试
    {
        const pattern = "AAA";
        var bm = try BoyerMoore.init(allocator, pattern);
        defer bm.deinit();

        const text = "AAAAA";
        const pos = bm.search(text);
        try std.testing.expect(pos != null);
        try std.testing.expectEqual(@as(usize, 0), pos.?);
    }
}

test "SimpleBoyerMoore functionality" {
    // 测试简化版本
    const pattern = "hello";
    const bm = SimpleBoyerMoore.init(pattern);

    const text1 = "say hello to the world";
    const pos1 = bm.search(text1);
    try std.testing.expect(pos1 != null);
    try std.testing.expectEqual(@as(usize, 4), pos1.?);

    const text2 = "goodbye world";
    const pos2 = bm.search(text2);
    try std.testing.expect(pos2 == null);

    // 测试包含检查
    try std.testing.expect(bm.contains(text1));
    try std.testing.expect(!bm.contains(text2));
}

test "Boyer-Moore findAll" {
    const allocator = std.testing.allocator;

    const pattern = "AB";
    var bm = try BoyerMoore.init(allocator, pattern);
    defer bm.deinit();

    const text = "ABABABAB";
    const positions = try bm.findAll(text, allocator);
    defer allocator.free(positions);

    try std.testing.expectEqual(@as(usize, 4), positions.len);
    try std.testing.expectEqual(@as(usize, 0), positions[0]);
    try std.testing.expectEqual(@as(usize, 2), positions[1]);
    try std.testing.expectEqual(@as(usize, 4), positions[2]);
    try std.testing.expectEqual(@as(usize, 6), positions[3]);
}