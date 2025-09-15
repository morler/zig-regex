const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const parser = @import("parse.zig");
const Expr = parser.Expr;
const compile = @import("compile.zig");
const Program = compile.Program;
const literal_extractor = @import("literal_extractor.zig");
const LiteralExtractor = literal_extractor.LiteralExtractor;
const LiteralCandidate = literal_extractor.LiteralCandidate;
const LiteralStrategy = literal_extractor.LiteralStrategy;
const boyer_moore = @import("boyer_moore.zig");
const BoyerMoore = boyer_moore.BoyerMoore;
const SimpleBoyerMoore = boyer_moore.SimpleBoyerMoore;
const input_new = @import("input_new.zig");
const Input = input_new.Input;

/// 字面量匹配引擎
pub const LiteralEngine = struct {
    allocator: Allocator,
    strategy: LiteralStrategy,
    candidate: ?LiteralCandidate,
    boyer_moore: ?BoyerMoore,

    /// 匹配结果
    pub const MatchResult = struct {
        /// 匹配起始位置
        start: usize,
        /// 匹配结束位置
        end: usize,
        /// 是否完整匹配（用于前缀优化）
        is_complete: bool,
    };

    pub fn init(allocator: Allocator) LiteralEngine {
        return LiteralEngine{
            .allocator = allocator,
            .strategy = .None,
            .candidate = null,
            .boyer_moore = null,
        };
    }

    pub fn deinit(self: *LiteralEngine) void {
        if (self.candidate) |candidate| {
            self.allocator.free(candidate.literal);
        }
        if (self.boyer_moore) |*bm| {
            bm.deinit();
        }
    }

    /// 从表达式分析并准备字面量引擎
    pub fn analyze(self: *LiteralEngine, expr: *const Expr) !void {
        var extractor = LiteralExtractor.init(self.allocator);
        defer extractor.deinit();

        // 提取字面量候选者
        try extractor.extract(expr);

        // 确定最佳策略
        self.strategy = extractor.determineStrategy();

        if (self.strategy != .None) {
            const best_candidate = extractor.getBestCandidate().?;

            // 克隆候选者（分配内存）
            self.candidate = extractor.cloneCandidate(best_candidate) catch |err| {
                // 清理错误状态，但不释放内存（因为cloneCandidate已经处理了）
                return err;
            };

            // 如果需要Boyer-Moore，则初始化
            if (self.strategy == .BoyerMoore and self.candidate != null) {
                self.boyer_moore = BoyerMoore.init(self.allocator, self.candidate.?.literal) catch |err| {
                    // 清理已分配的candidate内存
                    if (self.candidate) |candidate| {
                        self.allocator.free(candidate.literal);
                        self.candidate = null;
                    }
                    return err;
                };
            }
        }
    }

    /// 从程序分析（已编译的NFA）
    pub fn analyzeFromProgram(self: *LiteralEngine, _: *const Program) !void {
        // 简化实现：从程序中分析字面量模式
        // 在实际实现中，这需要从NFA指令中重构模式

        // TODO: 实现从NFA指令重构字面量模式
        // 这需要更复杂的分析，暂时禁用

        self.strategy = .None;
    }

    /// 检查是否可以使用字面量优化
    pub fn canOptimize(self: *const LiteralEngine) bool {
        return self.strategy != .None;
    }

    /// 获取字面量内容
    pub fn getLiteral(self: *const LiteralEngine) ?[]const u8 {
        return if (self.candidate) |candidate| candidate.literal else null;
    }

    /// 获取优化策略
    pub fn getStrategy(self: *const LiteralEngine) LiteralStrategy {
        return self.strategy;
    }

    /// 快速搜索：在输入中搜索字面量
    pub fn search(self: *const LiteralEngine, input: *Input) !?MatchResult {
        if (!self.canOptimize() or self.candidate == null) return null;

        const literal = self.candidate.?.literal;
        const text = input.asBytes();

        return switch (self.strategy) {
            .FixedString => self.searchFixed(text, literal),
            .BoyerMoore => self.searchBoyerMoore(text),
            else => null,
        };
    }

    /// 固定字符串搜索
    fn searchFixed(_: *const LiteralEngine, text: []const u8, literal: []const u8) ?MatchResult {
        const pos = mem.indexOf(u8, text, literal) orelse return null;

        return MatchResult{
            .start = pos,
            .end = pos + literal.len,
            .is_complete = true,
        };
    }

    /// Boyer-Moore搜索
    fn searchBoyerMoore(self: *const LiteralEngine, text: []const u8) ?MatchResult {
        const bm = self.boyer_moore orelse return null;
        const pos = bm.search(text) orelse return null;

        return MatchResult{
            .start = pos,
            .end = pos + bm.patternLength(),
            .is_complete = true,
        };
    }

    /// 查找所有匹配位置
    pub fn findAll(self: *const LiteralEngine, input: *Input, allocator: Allocator) ![]MatchResult {
        if (!self.canOptimize() or self.candidate == null) {
            return allocator.alloc(MatchResult, 0);
        }

        const literal = self.candidate.?.literal;
        const text = input.asBytes();
        var results = ArrayList(MatchResult).init(allocator);
        defer results.deinit();

        switch (self.strategy) {
            .FixedString => {
                var pos: usize = 0;
                while (pos < text.len) {
                    if (mem.indexOfPos(u8, text, pos, literal)) |found_pos| {
                        try results.append(MatchResult{
                            .start = found_pos,
                            .end = found_pos + literal.len,
                            .is_complete = true,
                        });
                        pos = found_pos + 1;
                    } else {
                        break;
                    }
                }
            },
            .BoyerMoore => {
                const bm = self.boyer_moore orelse return allocator.alloc(MatchResult, 0);
                const positions = try bm.findAll(text, allocator);
                defer allocator.free(positions);

                for (positions) |pos| {
                    try results.append(MatchResult{
                        .start = pos,
                        .end = pos + bm.patternLength(),
                        .is_complete = true,
                    });
                }
            },
            else => {},
        }

        return results.toOwnedSlice();
    }

    /// 前缀匹配：检查输入是否以字面量开头
    pub fn matchPrefix(self: *const LiteralEngine, input: *Input) bool {
        if (!self.canOptimize() or self.candidate == null) return false;

        const literal = self.candidate.?.literal;
        const text = input.asBytes();

        if (text.len < literal.len) return false;

        return mem.eql(u8, text[0..literal.len], literal);
    }

    /// 后缀匹配：检查输入是否以字面量结尾
    pub fn matchSuffix(self: *const LiteralEngine, input: *Input) bool {
        if (!self.canOptimize() or self.candidate == null) return false;

        const literal = self.candidate.?.literal;
        const text = input.asBytes();

        if (text.len < literal.len) return false;

        const start = text.len - literal.len;
        return mem.eql(u8, text[start..], literal);
    }

    /// 获取字面量长度
    pub fn literalLength(self: *const LiteralEngine) usize {
        return if (self.candidate) |candidate| candidate.literal.len else 0;
    }

    /// 获取字面量在表达式中的位置信息
    pub fn getPosition(self: *const LiteralEngine) LiteralCandidate.Position {
        return if (self.candidate) |candidate| candidate.position else .Standalone;
    }

    /// 创建调试信息字符串
    pub fn debugInfo(self: *const LiteralEngine, allocator: Allocator) ![]u8 {
        var buf = ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator,"LiteralEngine[");
        try buf.appendSlice(allocator,@tagName(self.strategy));
        try buf.appendSlice(allocator,"]");

        if (self.candidate) |candidate| {
            try buf.appendSlice(allocator," literal=\"");
            try buf.appendSlice(allocator,candidate.literal);
            try buf.appendSlice(allocator,"\"");
            try buf.appendSlice(allocator," len=");
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{}", .{candidate.literal.len}) catch "err";
            try buf.appendSlice(allocator, len_str);
            try buf.appendSlice(allocator," pos=");
            try buf.appendSlice(allocator,@tagName(candidate.position));
        } else {
            try buf.appendSlice(allocator," no candidate");
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// 优化的正则表达式执行器，结合字面量引擎和NFA引擎
pub const OptimizedExecutor = struct {
    allocator: Allocator,
    literal_engine: LiteralEngine,
    use_literal_optimization: bool,

    pub fn init(allocator: Allocator) OptimizedExecutor {
        return OptimizedExecutor{
            .allocator = allocator,
            .literal_engine = LiteralEngine.init(allocator),
            .use_literal_optimization = true,
        };
    }

    pub fn deinit(self: *OptimizedExecutor) void {
        self.literal_engine.deinit();
    }

    /// 启用/禁用字面量优化
    pub fn setLiteralOptimization(self: *OptimizedExecutor, enabled: bool) void {
        self.use_literal_optimization = enabled;
    }

    /// 分析表达式并准备优化策略
    pub fn analyze(self: *OptimizedExecutor, expr: *const Expr) !void {
        if (self.use_literal_optimization) {
            try self.literal_engine.analyze(expr);
        }
    }

    /// 优化执行：先尝试字面量匹配，失败则回退到NFA
    pub fn execOptimized(
        self: *OptimizedExecutor,
        _: *const Program,
        input: *Input,
        nfa_exec: anytype,
    ) !bool {
        // 如果启用了字面量优化且引擎可用
        if (self.use_literal_optimization and self.literal_engine.canOptimize()) {
            // 尝试字面量快速匹配
            if (try self.literal_engine.search(input)) |result| {
                // 对于完全匹配，可以跳过NFA执行
                if (result.is_complete and self.literal_engine.getPosition() == .Standalone) {
                    // 这里需要设置NFA的匹配结果
                    // 暂时返回true，实际实现需要更复杂的集成
                    return true;
                }

                // 对于前缀匹配，可以优化NFA的起始位置
                // 暂时回退到NFA执行
            }
        }

        // 回退到标准NFA执行
        return nfa_exec(input);
    }
};

// 测试用例
test "LiteralEngine basic functionality" {
    const allocator = std.testing.allocator;

    // 测试固定字符串策略
    {
        var engine = LiteralEngine.init(allocator);
        defer engine.deinit();

        // 创建足够长的字面量表达式来触发优化
        var concat_exprs = ArrayListUnmanaged(*Expr).empty;
        defer concat_exprs.deinit(allocator);

        const chars = "hello";
        for (chars) |c| {
            const expr = try allocator.create(Expr);
            expr.* = .{ .Literal = c };
            try concat_exprs.append(allocator, expr);
        }

        var concat_expr = Expr{ .Concat = concat_exprs };
        try engine.analyze(&concat_expr);

        try std.testing.expectEqual(LiteralStrategy.BoyerMoore, engine.getStrategy());
        try std.testing.expect(engine.canOptimize());

        const literal = engine.getLiteral();
        try std.testing.expect(literal != null);
        try std.testing.expectEqualSlices(u8, "hello", literal.?);

        // 清理Expr分配
        for (concat_exprs.items) |expr| {
            allocator.destroy(expr);
        }
    }
}

test "LiteralEngine with concatenation" {
    const allocator = std.testing.allocator;

    var engine = LiteralEngine.init(allocator);
    defer engine.deinit();

    // 测试连接表达式：应该合并为字面量
    var concat_exprs = ArrayListUnmanaged(*Expr).empty;
    defer concat_exprs.deinit(allocator);

    const expr1 = try allocator.create(Expr);
    expr1.* = .{ .Literal = 'h' };
    errdefer allocator.destroy(expr1);

    const expr2 = try allocator.create(Expr);
    expr2.* = .{ .Literal = 'e' };
    errdefer allocator.destroy(expr2);

    const expr3 = try allocator.create(Expr);
    expr3.* = .{ .Literal = 'l' };
    errdefer allocator.destroy(expr3);

    try concat_exprs.append(allocator, expr1);
    try concat_exprs.append(allocator, expr2);
    try concat_exprs.append(allocator, expr3);

    var concat_expr = Expr{ .Concat = concat_exprs };
    try engine.analyze(&concat_expr);

    try std.testing.expect(engine.canOptimize());

    const literal = engine.getLiteral();
    try std.testing.expect(literal != null);
    try std.testing.expectEqualSlices(u8, "hel", literal.?);

    // 清理Expr分配
    allocator.destroy(expr1);
    allocator.destroy(expr2);
    allocator.destroy(expr3);
}

test "LiteralEngine search functionality" {
    const allocator = std.testing.allocator;

    var engine = LiteralEngine.init(allocator);
    defer engine.deinit();

    // 创建"hello"表达式
    var concat_exprs = ArrayListUnmanaged(*Expr).empty;
    defer concat_exprs.deinit(allocator);

    const chars = "hello";
    for (chars) |c| {
        const expr = try allocator.create(Expr);
        expr.* = .{ .Literal = c };
        try concat_exprs.append(allocator, expr);
    }

    var concat_expr = Expr{ .Concat = concat_exprs };
    try engine.analyze(&concat_expr);

    // 测试搜索
    var input = Input.init("say hello to the world", .bytes);

    // 清理Expr分配
    for (concat_exprs.items) |expr| {
        allocator.destroy(expr);
    }

    const result = try engine.search(&input);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.start);
    try std.testing.expectEqual(@as(usize, 9), result.?.end);
    try std.testing.expect(result.?.is_complete);

    // 测试前缀匹配
    var input_prefix = Input.init("hello world", .bytes);
    try std.testing.expect(engine.matchPrefix(&input_prefix));

    var input_no_prefix = Input.init("world hello", .bytes);
    try std.testing.expect(!engine.matchPrefix(&input_no_prefix));
}

test "LiteralEngine debug info" {
    const allocator = std.testing.allocator;

    var engine = LiteralEngine.init(allocator);
    defer engine.deinit();

    // 创建一个足够长的字面量来触发FixedString策略
    var concat_exprs = ArrayListUnmanaged(*Expr).empty;
    defer concat_exprs.deinit(allocator);

    const chars = "hello";
    for (chars) |c| {
        const expr = try allocator.create(Expr);
        expr.* = .{ .Literal = c };
        try concat_exprs.append(allocator, expr);
    }

    var concat_expr = Expr{ .Concat = concat_exprs };
    try engine.analyze(&concat_expr);

    const debug_info = try engine.debugInfo(allocator);
    defer allocator.free(debug_info);

    try std.testing.expect(mem.indexOf(u8, debug_info, "BoyerMoore") != null);
    try std.testing.expect(mem.indexOf(u8, debug_info, "literal=\"hello\"") != null);

    // 清理Expr分配
    for (concat_exprs.items) |expr| {
        allocator.destroy(expr);
    }
}