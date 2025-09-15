const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const parser = @import("parse.zig");
const Expr = parser.Expr;
const Repeater = parser.Repeater;

/// 字面量匹配策略
pub const LiteralStrategy = enum {
    /// 不适用字面量优化
    None,
    /// 固定字符串匹配
    FixedString,
    /// Boyer-Moore算法
    BoyerMoore,
    /// Aho-Corasick多模式匹配
    AhoCorasick,
};

/// 字面量候选者
pub const LiteralCandidate = struct {
    /// 字面量内容
    literal: []const u8,
    /// 最小长度（用于重复表达式）
    min_len: usize,
    /// 最大长度（null表示无限制）
    max_len: ?usize,
    /// 是否贪婪匹配
    greedy: bool,
    /// 在表达式中的位置（用于前缀优化）
    position: Position,

    /// 字面量在表达式中的位置
    pub const Position = enum {
        /// 独立表达式（如 "hello"）
        Standalone,
        /// 前缀（如 "hello.*world"）
        Prefix,
        /// 后缀（如 ".*hello"）
        Suffix,
        /// 中间（如 "start.*hello.*end"）
        Middle,
    };

    /// 计算字面量的优先级分数
    pub fn score(self: *const LiteralCandidate) u32 {
        var result_score: u32 = 0;

        // 基础分数：长度越长越好
        result_score += @intCast(self.literal.len * 10);

        // 位置分数：前缀和独立最有价值
        switch (self.position) {
            .Standalone, .Prefix => result_score += 50,
            .Suffix => result_score += 20,
            .Middle => result_score += 10,
        }

        // 确定性分数：固定长度优于可变长度
        if (self.max_len != null and self.max_len.? == self.min_len) {
            result_score += 30;
        }

        // 贪婪匹配优先
        if (self.greedy) result_score += 5;

        return result_score;
    }
};

/// 字面量提取器
pub const LiteralExtractor = struct {
    allocator: Allocator,
    candidates: ArrayList(LiteralCandidate),
    max_literal_length: usize,

    const DEFAULT_MAX_LENGTH = 64;

    pub fn init(allocator: Allocator) LiteralExtractor {
        return LiteralExtractor{
            .allocator = allocator,
            .candidates = ArrayListUnmanaged(LiteralCandidate){},
            .max_literal_length = DEFAULT_MAX_LENGTH,
        };
    }

    pub fn deinit(self: *LiteralExtractor) void {
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate.literal);
        }
        self.candidates.deinit(self.allocator);
    }

    /// 设置最大字面量长度
    pub fn setMaxLength(self: *LiteralExtractor, max_len: usize) void {
        self.max_literal_length = max_len;
    }

    /// 从表达式树中提取字面量
    pub fn extract(self: *LiteralExtractor, expr: *const Expr) !void {
        try self.extractInternal(expr, .Standalone);
    }

    /// 内部提取函数
    fn extractInternal(self: *LiteralExtractor, expr: *const Expr, position: LiteralCandidate.Position) !void {
        switch (expr.*) {
            .Literal => |ch| {
                // 单个字符字面量
                var literal = try self.allocator.alloc(u8, 1);
                literal[0] = ch;
                try self.candidates.append(self.allocator, LiteralCandidate{
                    .literal = literal,
                    .min_len = 1,
                    .max_len = 1,
                    .greedy = true,
                    .position = position,
                });
            },

            .Concat => |subexprs| {
                // 连接表达式：尝试合并相邻的字面量
                var buffer = ArrayListUnmanaged(u8){};
                defer buffer.deinit(self.allocator);

                var all_literals = true;
                var total_min: usize = 0;
                var total_max: usize = 0;

                for (subexprs.items) |subexpr| {
                    switch (subexpr.*) {
                        .Literal => |ch| {
                            try buffer.append(self.allocator, ch);
                            total_min += 1;
                            total_max += 1;
                        },
                        .ByteClass => {
                            // 如果是单字符的字符类，可以尝试加入
                            if (try self.isSingleCharClass(subexpr)) {
                                const ch = self.getSingleCharFromClass(subexpr);
                                try buffer.append(self.allocator, ch);
                                total_min += 1;
                                total_max += 1;
                            } else {
                                all_literals = false;
                                break;
                            }
                        },
                        else => {
                            all_literals = false;
                            break;
                        },
                    }
                }

                if (all_literals and buffer.items.len > 0 and buffer.items.len <= self.max_literal_length) {
                    // 成功合并为一个字面量
                    const literal = try self.allocator.dupe(u8, buffer.items);
                    try self.candidates.append(self.allocator, LiteralCandidate{
                        .literal = literal,
                        .min_len = total_min,
                        .max_len = total_max,
                        .greedy = true,
                        .position = position,
                    });
                } else {
                    // 递归提取子表达式
                    if (subexprs.items.len > 0) {
                        // 第一个子表达式可能是前缀
                        try self.extractInternal(subexprs.items[0], if (position == .Standalone) .Prefix else position);

                        // 中间的子表达式
                        for (subexprs.items[1..subexprs.items.len-1]) |subexpr| {
                            try self.extractInternal(subexpr, .Middle);
                        }

                        // 最后一个子表达式可能是后缀
                        if (subexprs.items.len > 1) {
                            try self.extractInternal(subexprs.items[subexprs.items.len-1], .Suffix);
                        }
                    }
                }
            },

            .Repeat => |repeater| {
                // 重复表达式：分析是否可以优化
                if (repeater.min == 1 and repeater.max == null) {
                    // + 重复：提取一次作为前缀
                    try self.extractInternal(repeater.subexpr, if (position == .Standalone) .Prefix else position);
                } else if (repeater.min == 0 and repeater.max == null) {
                    // * 重复：可以尝试提取但不保证
                    try self.extractInternal(repeater.subexpr, .Middle);
                } else if (repeater.min == 0 and repeater.max != null and repeater.max.? == 1) {
                    // ? 重复：可以尝试提取
                    try self.extractInternal(repeater.subexpr, .Middle);
                } else if (repeater.min > 0) {
                    // {m,n} 重复：提取前m次作为前缀
                    try self.extractInternal(repeater.subexpr, if (position == .Standalone) .Prefix else position);
                }
            },

            .Capture => |subexpr| {
                // 捕获组：不影响字面量提取
                try self.extractInternal(subexpr, position);
            },

            .Alternate => |subexprs| {
                // 选择表达式：分别提取每个分支
                for (subexprs.items) |subexpr| {
                    try self.extractInternal(subexpr, .Middle);
                }
            },

            else => {
                // 其他表达式类型（AnyCharNotNL, EmptyMatch, ByteClass等）
                // 不产生字面量
            },
        }
    }

    /// 检查是否是单字符的字符类
    fn isSingleCharClass(_: *LiteralExtractor, expr: *const Expr) !bool {
        switch (expr.*) {
            .ByteClass => |byte_class| {
                // 简化检查：如果字符类只有一个范围且长度为1
                // 实际实现需要更复杂的分析
                return byte_class.ranges.items.len == 1 and
                       byte_class.ranges.items[0].min == byte_class.ranges.items[0].max;
            },
            else => return false,
        }
    }

    /// 从单字符字符类获取字符
    fn getSingleCharFromClass(_: *LiteralExtractor, expr: *const Expr) u8 {
        switch (expr.*) {
            .ByteClass => |byte_class| {
                return byte_class.ranges.items[0].min;
            },
            else => unreachable,
        }
    }

    /// 获取最佳字面量候选者（返回引用，不分配内存）
    pub fn getBestCandidate(self: *const LiteralExtractor) ?*const LiteralCandidate {
        if (self.candidates.items.len == 0) return null;

        var best_index: usize = 0;
        var best_score: u32 = 0;

        for (self.candidates.items, 0..) |candidate, i| {
            const score = candidate.score();
            if (score > best_score) {
                best_score = score;
                best_index = i;
            }
        }

        return &self.candidates.items[best_index];
    }

    /// 克隆候选者（分配新内存）
    pub fn cloneCandidate(self: *const LiteralExtractor, candidate: *const LiteralCandidate) !LiteralCandidate {
        return LiteralCandidate{
            .literal = try self.allocator.dupe(u8, candidate.literal),
            .min_len = candidate.min_len,
            .max_len = candidate.max_len,
            .greedy = candidate.greedy,
            .position = candidate.position,
        };
    }

    /// 获取所有候选者（用于调试）
    pub fn getAllCandidates(self: *const LiteralExtractor) []const LiteralCandidate {
        return self.candidates.items;
    }

    /// 确定最佳匹配策略
    pub fn determineStrategy(self: *const LiteralExtractor) LiteralStrategy {
        const best = self.getBestCandidate() orelse return .None;

        // 长度阈值
        if (best.literal.len < 3) return .None; // 太短不值得优化

        // 长字面量使用Boyer-Moore
        if (best.literal.len >= 5) return .BoyerMoore;

        // 中等长度使用固定字符串匹配
        return .FixedString;
    }
};