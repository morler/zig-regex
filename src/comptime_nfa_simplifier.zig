// 编译时NFA简化算法
// 提供零开销的NFA结构简化和优化

const std = @import("std");
const Allocator = std.mem.Allocator;

const compile = @import("compile.zig");
const Program = compile.Program;
const Instruction = compile.Instruction;
const InstructionData = compile.InstructionData;
const parser = @import("parse.zig");
const Expr = parser.Expr;

// NFA简化策略
pub const SimplificationStrategy = enum {
    none, // 无简化
    basic, // 基本简化
    aggressive, // 激进简化
    extreme, // 极端简化
};

// 编译时NFA简化器
pub const ComptimeNFASimplifier = struct {
    const Self = @This();

    strategy: SimplificationStrategy,
    enable_redundancy_elimination: bool,
    enable_dead_code_elimination: bool,
    enable_constant_propagation: bool,
    enable_peephole_optimization: bool,

    pub fn init(strategy: SimplificationStrategy) Self {
        return Self{
            .strategy = strategy,
            .enable_redundancy_elimination = switch (strategy) {
                .none => false,
                .basic, .aggressive, .extreme => true,
            },
            .enable_dead_code_elimination = switch (strategy) {
                .none => false,
                .basic => false,
                .aggressive, .extreme => true,
            },
            .enable_constant_propagation = switch (strategy) {
                .none => false,
                .basic, .aggressive, .extreme => true,
            },
            .enable_peephole_optimization = switch (strategy) {
                .none, .basic => false,
                .aggressive, .extreme => true,
            },
        };
    }

    // 简化程序
    pub fn simplifyProgram(self: *const Self, program: *const Program) !SimplifiedProgram {
        var simplifier = ProgramSimplifier{
            .base = self.*,
            .original_program = program,
        };

        return simplifier.simplify();
    }

    // 分析简化机会
    pub fn analyzeSimplificationOpportunities(self: *const Self, program: *const Program) SimplificationAnalysis {
        var analysis = SimplificationAnalysis{};

        // 1. 冗余分析
        if (self.enable_redundancy_elimination) {
            analysis.redundant_instructions = self.countRedundantInstructions(program);
        }

        // 2. 死代码分析
        if (self.enable_dead_code_elimination) {
            analysis.dead_instructions = self.countDeadInstructions(program);
        }

        // 3. 常量传播分析
        if (self.enable_constant_propagation) {
            analysis.constant_folding_opportunities = self.countConstantFoldingOpportunities(program);
        }

        // 4. �窺孔孔优化分析
        if (self.enable_peephole_optimization) {
            analysis.peephole_opportunities = self.countPeepholeOpportunities(program);
        }

        // 5. 复杂度分析
        analysis.original_complexity = self.calculateComplexity(program);

        // 6. 估算改进
        analysis.estimated_instruction_reduction =
            analysis.redundant_instructions +
            analysis.dead_instructions +
            analysis.constant_folding_opportunities +
            @divFloor(analysis.peephole_opportunities, 2);

        analysis.estimated_memory_reduction = @as(f32, @floatFromInt(analysis.estimated_instruction_reduction)) * 0.6;

        return analysis;
    }

    // 计算冗余指令数
    fn countRedundantInstructions(self: *const Self, program: *const Program) usize {
        _ = self;
        var count: usize = 0;

        for (program.instructions, 0..) |inst, i| {
            // 检查冗余的跳转
            if (inst.data == InstructionData.Jump) {
                if (inst.out == i + 1) {
                    count += 1; // 跳转到下一个指令是冗余的
                }
            }

            // 检查冗余的字符匹配
            if (i > 0 and i < program.instructions.len - 1) {
                const prev = program.instructions[i - 1];

                // 连续的相同字符匹配
                if (inst.data == InstructionData.Char and prev.data == InstructionData.Char) {
                    if (@as(InstructionData.Char, inst.data) == @as(InstructionData.Char, prev.data)) {
                        count += 1;
                    }
                }
            }
        }

        return count;
    }

    // 计算死指令数
    fn countDeadInstructions(self: *const Self, program: *const Program) usize {
        var count: usize = 0;
        var reachable = std.ArrayList(bool).init(std.heap.page_allocator);
        defer reachable.deinit();

        reachable.resize(program.instructions.len, false) catch return 0;

        // 标记从入口可达的指令
        self.markReachableInstructions(program, &reachable, 0);

        // 统计不可达指令
        for (reachable.items, 0..) |is_reachable, i| {
            _ = i;
            if (!is_reachable) {
                count += 1;
            }
        }

        return count;
    }

    // 标记可达指令
    fn markReachableInstructions(self: *const Self, program: *const Program, reachable: *std.ArrayList(bool), start: usize) void {
        if (start >= program.instructions.len) return;
        if (reachable.items[start]) return; // 已经访问过

        reachable.items[start] = true;

        const inst = program.instructions[start];

        // 处理跳转
        if (inst.data == InstructionData.Jump) {
            self.markReachableInstructions(program, reachable, inst.out);
        } else if (inst.data == InstructionData.Match) {
            // 匹配指令停止执行
            return;
        } else {
            // 顺序执行下一条指令
            self.markReachableInstructions(program, reachable, start + 1);

            // 处理Split指令的特殊情况
            if (std.meta.activeTag(inst.data) == .Split) {
                const split_addr = std.meta.field(InstructionData, inst.data, .Split);
                self.markReachableInstructions(program, reachable, split_addr);
            }
        }
    }

    // 计算常量折叠机会
    fn countConstantFoldingOpportunities(self: *const Self, program: *const Program) usize {
        _ = self;
        var count: usize = 0;

        for (program.instructions, 0..) |inst, i| {
            // 检查可以折叠的简单序列
            if (i < program.instructions.len - 1) {
                const next = program.instructions[i + 1];

                // 字符匹配后立即匹配
                if (inst.data == InstructionData.Char and next.data == InstructionData.Char) {
                    count += 1;
                }

                // 简单的字符序列
                if (i < program.instructions.len - 2) {
                    const next2 = program.instructions[i + 2];
                    if (inst.data == InstructionData.Char and
                        next.data == InstructionData.Char and
                        next2.data == InstructionData.Char)
                    {
                        count += 1;
                    }
                }
            }
        }

        return count;
    }

    // 计算窺孔孔优化机会
    fn countPeepholeOpportunities(self: *const Self, program: *const Program) usize {
        _ = self;
        var count: usize = 0;

        for (program.instructions, 0..) |inst, i| {
            // 跳转到跳转
            if (inst.data == InstructionData.Jump and i < program.instructions.len - 1) {
                const next = program.instructions[i + 1];
                if (next.data == InstructionData.Jump) {
                    count += 1;
                }
            }

            // 无用的跳转
            if (inst.data == InstructionData.Jump and inst.out == i + 1) {
                count += 1;
            }

            // 分支到相同位置
            if (i < program.instructions.len - 1) {
                const next = program.instructions[i + 1];
                if (std.meta.activeTag(inst.data) == .Split and
                    std.meta.activeTag(next.data) == .Split)
                {
                    const split1 = std.meta.field(InstructionData, inst.data, .Split);
                    const split2 = std.meta.field(InstructionData, next.data, .Split);
                    if (split1 == split2) {
                        count += 1;
                    }
                }
            }
        }

        return count;
    }

    // 计算复杂度
    fn calculateComplexity(self: *const Self, program: *const Program) u32 {
        _ = self;
        var complexity: u32 = 0;

        for (program.instructions) |inst| {
            switch (inst.data) {
                InstructionData.Char => complexity += 1,
                InstructionData.ByteClass => complexity += 2,
                InstructionData.AnyCharNotNL => complexity += 1,
                InstructionData.EmptyMatch => complexity += 1,
                InstructionData.Match => complexity += 1,
                InstructionData.Jump => complexity += 1,
                InstructionData.Split => complexity += 3,
                InstructionData.Save => complexity += 2,
            }
        }

        return complexity;
    }
};

// 程序简化器
const ProgramSimplifier = struct {
    base: ComptimeNFASimplifier,
    original_program: *const Program,

    fn simplify(self: *const ProgramSimplifier) !SimplifiedProgram {
        var simplified = SimplifiedProgram{
            .instructions = std.ArrayList(Instruction).init(std.heap.page_allocator),
            .original_count = self.original_program.instructions.len,
            .removed_count = 0,
            .optimized_sequences = std.ArrayList(OptimizedSequence).init(std.heap.page_allocator),
            .simplifications_applied = std.ArrayList(SimplificationType).init(std.heap.page_allocator),
        };
        errdefer {
            simplified.instructions.deinit();
            simplified.optimized_sequences.deinit();
            simplified.simplifications_applied.deinit();
        }

        // 复制原始指令
        try simplified.instructions.appendSlice(self.original_program.instructions);

        // 1. 冗余消除
        if (self.base.enable_redundancy_elimination) {
            try self.eliminateRedundancy(&simplified);
        }

        // 2. 死代码消除
        if (self.base.enable_dead_code_elimination) {
            try self.eliminateDeadCode(&simplified);
        }

        // 3. 常量传播
        if (self.base.enable_constant_propagation) {
            try self.foldConstants(&simplified);
        }

        // 4. 窺孔孔优化
        if (self.base.enable_peephole_optimization) {
            try self.peepholeOptimize(&simplified);
        }

        // 计算移除的指令数
        simplified.removed_count = self.original_program.instructions.len - simplified.instructions.items.len;

        return simplified;
    }

    // 冗余消除
    fn eliminateRedundancy(self: *const ProgramSimplifier, simplified: *SimplifiedProgram) !void {
        _ = self;
        var i: usize = 0;
        while (i < simplified.instructions.items.len) {
            const inst = simplified.instructions.items[i];

            // 移除冗余的跳转（跳转到下一条指令）
            if (inst.data == InstructionData.Jump and inst.out == i + 1) {
                _ = simplified.instructions.orderedRemove(i);
                try simplified.simplifications_applied.append(.redundant_jump);
                continue;
            }

            // 移除连续的相同字符匹配
            if (i > 0 and i < simplified.instructions.items.len - 1) {
                const prev = simplified.instructions.items[i - 1];

                if (inst.data == InstructionData.Char and
                    prev.data == InstructionData.Char and
                    @as(InstructionData.Char, inst.data) == @as(InstructionData.Char, prev.data))
                {
                    _ = simplified.instructions.orderedRemove(i);
                    try simplified.simplifications_applied.append(.redundant_char);
                    continue;
                }
            }

            i += 1;
        }
    }

    // 死代码消除
    fn eliminateDeadCode(self: *const ProgramSimplifier, simplified: *SimplifiedProgram) !void {
        var reachable = std.ArrayList(bool).init(std.heap.page_allocator);
        defer reachable.deinit();

        try reachable.resize(simplified.instructions.items.len, false);

        // 标记可达指令
        self.markReachable(simplified, &reachable, 0);

        // 移除不可达指令
        var new_instructions = std.ArrayList(Instruction).init(std.heap.page_allocator);
        errdefer new_instructions.deinit();

        var removed_count: usize = 0;
        for (simplified.instructions.items, 0..) |inst, i| {
            if (reachable.items[i]) {
                try new_instructions.append(inst);
            } else {
                removed_count += 1;
            }
        }

        if (removed_count > 0) {
            simplified.instructions.deinit();
            simplified.instructions = new_instructions;
            try simplified.simplifications_applied.append(.dead_code);
        } else {
            new_instructions.deinit();
        }
    }

    // 标记可达指令
    fn markReachable(self: *const ProgramSimplifier, simplified: *SimplifiedProgram, reachable: *std.ArrayList(bool), start: usize) void {
        if (start >= simplified.instructions.items.len) return;
        if (reachable.items[start]) return;

        reachable.items[start] = true;

        const inst = simplified.instructions.items[start];

        if (inst.data == InstructionData.Jump) {
            self.markReachable(simplified, reachable, inst.out);
        } else if (inst.data == InstructionData.Match) {
            return;
        } else {
            self.markReachable(simplified, reachable, start + 1);

            if (std.meta.activeTag(inst.data) == .Split) {
                const split_addr = std.meta.field(InstructionData, inst.data, .Split);
                self.markReachable(simplified, reachable, split_addr);
            }
        }
    }

    // 常量折叠
    fn foldConstants(self: *const ProgramSimplifier, simplified: *SimplifiedProgram) !void {
        _ = self;
        var i: usize = 0;
        while (i < simplified.instructions.items.len - 1) {
            const current = simplified.instructions.items[i];
            const next = simplified.instructions.items[i + 1];

            // 合并连续的字符匹配
            if (current.data == InstructionData.Char and next.data == InstructionData.Char) {
                // 简化：暂时跳过复杂的合并逻辑
                i += 1;
                continue;
            }

            i += 1;
        }
    }

    // 窺孔孔优化
    fn peepholeOptimize(self: *const ProgramSimplifier, simplified: *SimplifiedProgram) !void {
        _ = self;
        var i: usize = 0;
        while (i < simplified.instructions.items.len - 1) {
            const current = simplified.instructions.items[i];
            const next = simplified.instructions.items[i + 1];

            // 跳转到跳转优化
            if (current.data == InstructionData.Jump and next.data == InstructionData.Jump) {
                // 直接跳转到最终目标
                simplified.instructions.items[i].out = next.out;
                _ = simplified.instructions.orderedRemove(i + 1);
                try simplified.simplifications_applied.append(.jump_to_jump);
                continue;
            }

            // 无条件分支优化
            if (std.meta.activeTag(current.data) == .Split) {
                const split_addr = std.meta.field(InstructionData, current.data, .Split);

                // 如果分支目标相同，转换为跳转
                if (split_addr == i + 1) {
                    simplified.instructions.items[i].data = InstructionData.Jump;
                    try simplified.simplifications_applied.append(.split_to_jump);
                    continue;
                }
            }

            i += 1;
        }
    }
};

// 简化后的程序
pub const SimplifiedProgram = struct {
    instructions: std.ArrayList(Instruction),
    original_count: usize,
    removed_count: usize,
    optimized_sequences: std.ArrayList(OptimizedSequence),
    simplifications_applied: std.ArrayList(SimplificationType),

    pub fn deinit(self: *@This()) void {
        self.instructions.deinit();
        self.optimized_sequences.deinit();
        self.simplifications_applied.deinit();
    }

    pub fn getOptimizationRatio(self: *const @This()) f32 {
        if (self.original_count == 0) return 0.0;
        return @as(f32, @floatFromInt(self.removed_count)) / @as(f32, @floatFromInt(self.original_count));
    }

    pub fn getFinalInstructions(self: *@This()) []Instruction {
        return self.instructions.items;
    }
};

// 优化序列
const OptimizedSequence = struct {
    start_index: usize,
    end_index: usize,
    original_instructions: usize,
    optimized_instructions: usize,
    optimization_type: OptimizationType,
};

// 优化类型
const OptimizationType = enum {
    character_sequence,
    jump_chain,
    dead_code_removal,
    constant_propagation,
};

// 简化类型
const SimplificationType = enum {
    redundant_jump,
    redundant_char,
    dead_code,
    jump_to_jump,
    split_to_jump,
    constant_folding,
    peephole_optimization,
};

// 简化分析
pub const SimplificationAnalysis = struct {
    redundant_instructions: usize = 0,
    dead_instructions: usize = 0,
    constant_folding_opportunities: usize = 0,
    peephole_opportunities: usize = 0,
    original_complexity: u32 = 0,
    estimated_instruction_reduction: usize = 0,
    estimated_memory_reduction: f32 = 0.0,
    is_worth_simplifying: bool = false,

    pub fn calculateWorth(self: *const @This()) void {
        self.is_worth_simplifying =
            self.redundant_instructions > 2 or
            self.dead_instructions > 1 or
            self.constant_folding_opportunities > 3 or
            self.estimated_instruction_reduction > 5;
    }
};

// 编译时NFA简化器包装器
pub fn ComptimeNFASimplifierWrapper(comptime program: *const Program, comptime strategy: SimplificationStrategy) type {
    return struct {
        const Self = @This();

        // 编译时分析
        pub const analysis = blk: {
            var simplifier = ComptimeNFASimplifier.init(strategy);
            break :blk simplifier.analyzeSimplificationOpportunities(program);
        };

        // 编译时简化
        pub const simplified_program = blk: {
            var simplifier = ComptimeNFASimplifier.init(strategy);
            break :blk simplifier.simplifyProgram(program) catch unreachable;
        };

        // 编译时验证
        comptime {
            analysis.calculateWorth();

            if (analysis.is_worth_simplifying) {
                @compileLog("NFA simplification applied with ", simplified_program.removed_count, " instructions removed");
            }
        }

        pub fn getSimplifiedProgram() SimplifiedProgram {
            return simplified_program;
        }

        pub fn getAnalysis() SimplificationAnalysis {
            return analysis;
        }

        pub fn getOptimizationRatio() f32 {
            return simplified_program.getOptimizationRatio();
        }
    };
}

// 测试
test "comptime NFA simplifier basic" {
    // 创建一个简单的测试程序
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'h' }),
        Instruction.new(2, InstructionData{ .Char = 'e' }),
        Instruction.new(3, InstructionData{ .Char = 'l' }),
        Instruction.new(4, InstructionData{ .Char = 'l' }),
        Instruction.new(5, InstructionData{ .Char = 'o' }),
        Instruction.new(6, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.basic;
    const analysis = comptime blk: {
        var simplifier = ComptimeNFASimplifier.init(strategy);
        break :blk simplifier.analyzeSimplificationOpportunities(&test_program);
    };

    try std.testing.expect(analysis.original_complexity > 0);
}

test "comptime NFA simplifier with jumps" {
    // 创建一个包含冗余跳转的测试程序
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'a' }),
        Instruction.new(2, InstructionData.Jump), // 跳转到下一条指令（冗余）
        Instruction.new(3, InstructionData{ .Char = 'b' }),
        Instruction.new(4, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.aggressive;
    const analysis = comptime blk: {
        var simplifier = ComptimeNFASimplifier.init(strategy);
        break :blk simplifier.analyzeSimplificationOpportunities(&test_program);
    };

    try std.testing.expect(analysis.redundant_instructions > 0);
}

test "comptime NFA simplifier wrapper" {
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'h' }),
        Instruction.new(2, InstructionData{ .Char = 'e' }),
        Instruction.new(3, InstructionData.Jump), // 冗余跳转
        Instruction.new(4, InstructionData{ .Char = 'l' }),
        Instruction.new(5, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const TestSimplifier = ComptimeNFASimplifierWrapper(&test_program, SimplificationStrategy.basic);

    const simplified = TestSimplifier.getSimplifiedProgram();
    _ = TestSimplifier.getAnalysis();

    try std.testing.expect(simplified.original_count >= simplified.instructions.items.len);
}

test "comptime simplification analysis" {
    const test_instructions = [_]Instruction{
        Instruction.new(1, InstructionData{ .Char = 'a' }),
        Instruction.new(2, InstructionData.Jump), // 冗余
        Instruction.new(3, InstructionData{ .Char = 'b' }),
        Instruction.new(4, InstructionData.Jump), // 跳转到跳转
        Instruction.new(5, InstructionData{ .Char = 'c' }),
        Instruction.new(6, InstructionData.Match),
    };

    const test_program = Program{
        .instructions = &test_instructions,
        .num_captures = 0,
    };

    const strategy = SimplificationStrategy.aggressive;
    const analysis = comptime blk: {
        var simplifier = ComptimeNFASimplifier.init(strategy);
        break :blk simplifier.analyzeSimplificationOpportunities(&test_program);
    };

    analysis.calculateWorth();
    try std.testing.expect(analysis.is_worth_simplifying);
    try std.testing.expect(analysis.redundant_instructions > 0);
    try std.testing.expect(analysis.peephole_opportunities > 0);
}
