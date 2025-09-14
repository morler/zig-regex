const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const compile = @import("compile.zig");
const Program = compile.Program;
const Instruction = compile.Instruction;
const InstructionData = compile.InstructionData;
const parser = @import("parse.zig");

const input_new = @import("input_new.zig");
const Input = input_new.Input;

const bit_vector = @import("bit_vector.zig");
const BitVector = bit_vector.BitVector;
const ThreadSet = bit_vector.ThreadSet;

// NFA状态表�?pub const NfaState = struct {
    // 程序计数器（指令索引�?    pc: usize,
    // 捕获组位置数�?    slots: ArrayList(?usize),
    // 分配�?    allocator: Allocator,

    // 初始化NFA状�?    pub fn init(allocator: Allocator, pc: usize, slot_count: usize) !NfaState {
        var slots = ArrayListUnmanaged(?usize).empty;
        try slots.resize(allocator, slot_count, null);

        return NfaState{
            .pc = pc,
            .slots = slots,
            .allocator = allocator,
        };
    }

    // 释放NFA状�?    pub fn deinit(self: *NfaState) void {
        self.slots.deinit(self.allocator);
    }

    // 复制NFA状�?    pub fn clone(self: *const NfaState) !NfaState {
        var new_slots = ArrayListUnmanaged(?usize).empty;
        try new_slots.resize(self.allocator, self.slots.items.len, null);
        @memcpy(new_slots.items, self.slots.items);

        return NfaState{
            .pc = self.pc,
            .slots = new_slots,
            .allocator = self.allocator,
        };
    }

    // 设置捕获组位�?    pub fn setSlot(self: *NfaState, slot_index: usize, position: usize) void {
        if (slot_index < self.slots.items.len) {
            self.slots.items[slot_index] = position;
        }
    }

    // 获取捕获组位�?    pub fn getSlot(self: *const NfaState, slot_index: usize) ?usize {
        if (slot_index < self.slots.items.len) {
            return self.slots.items[slot_index];
        }
        return null;
    }

    // 比较两个NFA状态是否相�?    pub fn equals(self: *const NfaState, other: *const NfaState) bool {
        if (self.pc != other.pc) return false;
        if (self.slots.items.len != other.slots.items.len) return false;

        for (self.slots.items, other.slots.items) |self_slot, other_slot| {
            if (self_slot != other_slot) return false;
        }

        return true;
    }
};

// Thompson NFA引擎
pub const ThompsonNfa = struct {
    // 编译后的程序
    program: *const Program,
    // 线程集合
    thread_set: ThreadSet,
    // 当前输入位置
    input_pos: usize,
    // 匹配结果
    match_start: ?usize,
    match_end: ?usize,
    // 分配�?    allocator: Allocator,

    // 初始化Thompson NFA引擎
    pub fn init(allocator: Allocator, program: *const Program) !ThompsonNfa {
        return ThompsonNfa{
            .program = program,
            .thread_set = try ThreadSet.init(allocator, program.insts.len),
            .input_pos = 0,
            .match_start = null,
            .match_end = null,
            .allocator = allocator,
        };
    }

    // 释放Thompson NFA引擎
    pub fn deinit(self: *ThompsonNfa) void {
        self.thread_set.deinit();
    }

    // 重置引擎状�?    pub fn reset(self: *ThompsonNfa) void {
        self.thread_set.clear();
        self.input_pos = 0;
        self.match_start = null;
        self.match_end = null;
    }

    // 计算epsilon闭包（旧实现，保留以便对照）
    pub fn computeEpsilonClosureOld(self: *ThompsonNfa, start_pc: usize, slots: *ArrayList(?usize), input: *Input) !void {
        var visited = try BitVector.init(self.allocator, self.program.insts.len);
        defer visited.deinit();

        // 使用动态分配的栈以避免固定大小限制
        var stack = ArrayListUnmanaged(usize).empty;
        defer stack.deinit(self.allocator);

        // 初始状态入�?        try stack.append(self.allocator, start_pc);
        visited.set(start_pc);

        // DFS遍历epsilon转移
        while (stack.items.len > 0) {
            const pc = stack.pop() orelse unreachable;
            const inst = &self.program.insts[pc];

            switch (inst.data) {
                // Split指令：创建两个分�?                .Split => |target_pc| {
                    // 第一个分�?                    if (!visited.get(pc + 1)) {
                        try stack.append(self.allocator, pc + 1);
                        visited.set(pc + 1);
                    }
                    // 第二个分�?                    if (!visited.get(target_pc)) {
                        try stack.append(self.allocator, target_pc);
                        visited.set(target_pc);
                    }
                },
                // Jump指令：无条件跳转
                .Jump => {
                    if (!visited.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                // Save指令：保存捕获组位置
                .Save => |slot_index| {
                    if (slot_index < slots.items.len) {
                        slots.items[slot_index] = self.input_pos;
                    }
                    // 继续到下一条指�?                    if (!visited.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                // 空匹配（断言�?                            .EmptyMatch => |assertion| { _ = assertion; },
                    }
                },
                // 匹配指令：找到匹�?                .Match => {
                    // 找到匹配，记录匹配位�?                    self.match_end = self.input_pos; // 匹配结束位置是当前位�?                    // 不添加Match指令到线程集合，因为它会终止线程
                },
                // 其他指令：不产生epsilon转移，但需要添加到线程集合
                else => {
                    // 非epsilon转移指令，标记为已访问但不继续遍�?                    visited.set(pc);
                },
            }
        }

        // 将所有访问过的状态添加到线程集合
        var pc = visited.firstSet();
        while (pc) |state| : (pc = visited.nextSet(state)) {
            self.thread_set.addThread(state);
        }
    }

    // 计算epsilon闭包（修正后的实现）
    pub fn computeEpsilonClosure(self: *ThompsonNfa, start_pc: usize, slots: *ArrayList(?usize), input: *Input) !void {
        var visited = try BitVector.init(self.allocator, self.program.insts.len);
        defer visited.deinit();

        var stack = ArrayListUnmanaged(usize).empty;
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, start_pc);
        visited.set(start_pc);

        while (stack.items.len > 0) {
            const pc = stack.pop() orelse unreachable;
            const inst = &self.program.insts[pc];

            switch (inst.data) {
                .Split => |branch_pc| {
                    const first_pc = inst.out;
                    if (!visited.get(first_pc)) {
                        try stack.append(self.allocator, first_pc);
                        visited.set(first_pc);
                    }
                    if (!visited.get(branch_pc)) {
                        try stack.append(self.allocator, branch_pc);
                        visited.set(branch_pc);
                    }
                },
                .Jump => {
                    if (!visited.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                .Save => |slot_index| {
                    if (slot_index < slots.items.len) {
                        slots.items[slot_index] = self.input_pos;
                    }
                    if (!visited.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                            .EmptyMatch => |assertion| { _ = assertion; },
                    }
                },
                .Match => {
                    // 记录匹配结束位置
                    self.match_end = self.input_pos;
                },
                else => {
                    // 非epsilon节点，作为边界加入集�?                    visited.set(pc);
                },
            }
        }

        var it = visited.firstSet();
        while (it) |state| : (it = visited.nextSet(state)) {
            self.thread_set.addThread(state);
        }
    }

    // 计算字符转移
    pub fn computeCharTransition(self: *ThompsonNfa, pc: usize, char: u21, slots: *ArrayList(?usize), input: *Input) !?usize {
        _ = slots; // 避免未使用参数警�?        const inst = &self.program.insts[pc];

        switch (inst.data) {
            // 匹配特定字符
            .Char => |c| {
                if (char == c) {
                    return inst.out;
                }
            },
            // 匹配字符�?            .ByteClass => |byte_class| {
                if (char <= std.math.maxInt(u8)) {
                    const byte = @as(u8, @intCast(char));
                    if (byte_class.contains(byte)) {
                        return inst.out;
                    }
                }
            },
            // 匹配任意字符（除换行符外�?            .AnyCharNotNL => {
                if (char != '\n') {
                    return inst.out;
                }
            },
            // 空匹配（断言�?                        .EmptyMatch => |assertion| { _ = assertion; },
            },
            // 匹配指令不应该出现在字符转移�?            .Match => {
                return null; // 终止当前线程
            },
            // 其他指令不应该出现在字符转移�?            else => {
                // 不处理其他指令类�?            },
        }

        return null; // 不匹�?    }

    // 检查断言
    pub fn checkAssertion(self: *ThompsonNfa, assertion: parser.Assertion, char: u21, input: *Input) bool {
        _ = char; // 大多数断言不需要字符参�?
        switch (assertion) {
            // 无断言
            .None => {
                return true;
            },
            // 行开始：^
            .BeginLine => {
                return self.input_pos == 0;
            },
            // 行结束：$
            .EndLine => {
                // 检查是否到达输入末�?                const input_len = input.getLength();
                if (self.input_pos >= input_len) {
                    return true; // 到达输入末尾
                }
                // 检查当前位置的字符是否是换行符
                const current_char = input.current() orelse {
                    return false;
                };
                return current_char == '\n';
            },
            // 文本开始：\A
            .BeginText => {
                return self.input_pos == 0;
            },
            // 文本结束：\z
            .EndText => {
                // 检查是否到达输入末�?                const input_len = input.getLength();
                return self.input_pos >= input_len;
            },
            // ASCII单词边界：\b
            .WordBoundaryAscii => {
                // 简化实现：总是返回true
                return true;
            },
            // ASCII非单词边界：\B
            .NotWordBoundaryAscii => {
                // 简化实现：总是返回false
                return false;
            },
        }
    }

    // 执行一步NFA
    pub fn step(self: *ThompsonNfa, input: *Input) !bool {
        if (self.thread_set.isEmpty()) {
            return false; // 没有活跃线程
        }

        // 准备下一个状态集�?        self.thread_set.prepareNext();

        // 获取当前字符
        const char_opt = input.current();
        const char = char_opt orelse {
            // 输入结束，停止处�?            self.thread_set.switchToNext();
            return false;
        };

        // 遍历所有活跃线程，计算字符转移
        var current_thread = self.thread_set.firstThread();
        while (current_thread) |pc| : (current_thread = self.thread_set.nextThread(pc)) {
            var temp_slots = ArrayListUnmanaged(?usize).empty;
            defer temp_slots.deinit(self.allocator);
            const next_pc = try self.computeCharTransition(pc, char, &temp_slots, input);
            if (next_pc) |npc| {
                // 添加到下一个状态集�?                self.thread_set.addToNext(npc);
            }
        }

        // 切换到下一个状态集�?        self.thread_set.switchToNext();

        // 计算新状态的epsilon闭包
        try self.computeEpsilonClosureForCurrentSet(input);

        // 移动到下一个输入位�?        input.advance();
        self.input_pos += 1;

        return !self.thread_set.isEmpty();
    }

    // 为当前线程集合计算epsilon闭包（使用统一的实现）
    fn computeEpsilonClosureForCurrentSet(self: *ThompsonNfa, input: *Input) !void {

        // 调试：检查容�?        std.debug.print("  Current capacity: {}, Temp capacity: {}\n", .{ self.thread_set.current.capacity, self.thread_set.temp.capacity });

        // 保存当前线程集合到临时位向量
        self.thread_set.copyToTemp();

        // 只清空当前线程集合，保留临时位向�?        self.thread_set.current.clear();

        // 为临时位向量中的每个状态计算epsilon闭包
        const temp_bit_vector = self.thread_set.getTemp();
        var thread = temp_bit_vector.firstSet();
        while (thread) |pc| : (thread = temp_bit_vector.nextSet(pc)) {
            var slots = ArrayListUnmanaged(?usize).empty;
            defer slots.deinit(self.allocator);
            try slots.resize(self.allocator, self.program.slot_count);

            // 创建临时线程集合来存储单个状态的epsilon闭包
            var temp_thread_set = try ThreadSet.init(self.allocator, self.program.insts.len);
            defer temp_thread_set.deinit();

            // 交换线程集合以使用临时集�?            const original_thread_set = self.thread_set;
            self.thread_set = temp_thread_set;

            // 计算单个状态的epsilon闭包到临时集�?            try self.computeEpsilonClosure(pc, &slots, input);

            // 恢复原始线程集合
            self.thread_set = original_thread_set;

            // 将临时集合中的所有线程添加到原始集合
            var temp_thread = temp_thread_set.firstThread();
            while (temp_thread) |temp_pc| : (temp_thread = temp_thread_set.nextThread(temp_pc)) {
                self.thread_set.addThread(temp_pc);
            }
        }
    }

    // 执行NFA匹配
    pub fn execute(self: *ThompsonNfa, input: *Input, start_pc: usize) !bool {
        self.reset();

        // 初始化：从起始状态开始，计算epsilon闭包
        var initial_slots = ArrayListUnmanaged(?usize).empty;
        defer initial_slots.deinit(self.allocator);
        try initial_slots.resize(self.allocator, self.program.slot_count);

        try self.computeEpsilonClosure(start_pc, &initial_slots, input);

        // 如果有匹配开始位置，记录�?        if (!self.thread_set.isEmpty()) {
            self.match_start = self.input_pos;
        }

        // 主执行循�?        while (!input.isConsumed() and !self.thread_set.isEmpty()) {
            _ = try self.step(input);
        }

        // 输入结束后的最终epsilon闭包计算，处理EndLine等断言
        if (!self.thread_set.isEmpty()) {
            try self.computeEpsilonClosureForCurrentSet(input);
        }

        // 检查是否找到匹�?        return self.match_end != null;
    }

    // 获取匹配结果
    pub fn getMatchResult(self: *const ThompsonNfa) struct { start: ?usize, end: ?usize } {
        return .{
            .start = self.match_start,
            .end = self.match_end,
        };
    }
};

test "Thompson NFA basic functionality" {
    const allocator = std.testing.allocator;

    // 创建一个简单的测试程序
    var insts = try allocator.alloc(Instruction, 2);
    defer allocator.free(insts);

    // 简单程序：匹配字符 'a'
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    // 测试匹配
    var input = input_new.Input.init("a", .bytes);

    const result = try nfa.execute(&input, 0);
    std.debug.print("Test result: {}\n", .{result});
    try std.testing.expect(result);

    const match_result = nfa.getMatchResult();
    std.debug.print("Match start: {}, Match end: {}\n", .{ match_result.start.?, match_result.end.? });
    try std.testing.expectEqual(@as(usize, 0), match_result.start.?);
    try std.testing.expectEqual(@as(usize, 1), match_result.end.?);
}

test "Thompson NFA epsilon closure" {
    const allocator = std.testing.allocator;

    // 创建一个测试程序，包含epsilon转移
    var insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(insts);

    // 程序：Split -> Char 'a' -> Match
    //         |
    //         -> Char 'b' -> Match
    insts[0] = Instruction.new(1, InstructionData{ .Split = 2 }); // Split�?�?
    insts[1] = Instruction.new(3, InstructionData{ .Char = 'a' }); // 分支1
    insts[2] = Instruction.new(3, InstructionData{ .Char = 'b' }); // 分支2
    insts[3] = Instruction.new(0, InstructionData.Match); // Match

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    // 测试epsilon闭包计算
    var slots = ArrayListUnmanaged(?usize).empty;
    defer slots.deinit(allocator);
    try slots.resize(allocator, 0);

    var input = input_new.Input.init("", .bytes);
    try nfa.computeEpsilonClosure(0, &slots, &input);

    // 应该包含状�?�?（Split的两个分支）
    try std.testing.expect(nfa.thread_set.hasThread(1));
    try std.testing.expect(nfa.thread_set.hasThread(2));
    // 注意：Split指令本身（状�?）也会被添加到线程集�?    try std.testing.expectEqual(@as(usize, 3), nfa.thread_set.count());
}
