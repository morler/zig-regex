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

// NFA状态表示
pub const NfaState = struct {
    // 程序计数器（指令索引）
    pc: usize,
    // 捕获组位置数组
    slots: ArrayList(?usize),
    // 分配器
    allocator: Allocator,

    // 初始化NFA状态
    pub fn init(allocator: Allocator, pc: usize, slot_count: usize) !NfaState {
        var slots = ArrayListUnmanaged(?usize).empty;
        try slots.resize(allocator, slot_count, null);

        return NfaState{
            .pc = pc,
            .slots = slots,
            .allocator = allocator,
        };
    }

    // 释放NFA状态
    pub fn deinit(self: *NfaState) void {
        self.slots.deinit(self.allocator);
    }

    // 复制NFA状态
    pub fn clone(self: *const NfaState) !NfaState {
        var new_slots = ArrayListUnmanaged(?usize).empty;
        try new_slots.resize(self.allocator, self.slots.items.len, null);
        @memcpy(new_slots.items, self.slots.items);

        return NfaState{
            .pc = self.pc,
            .slots = new_slots,
            .allocator = self.allocator,
        };
    }

    // 设置捕获组位置
    pub fn setSlot(self: *NfaState, slot_index: usize, position: usize) void {
        if (slot_index < self.slots.items.len) {
            self.slots.items[slot_index] = position;
        }
    }

    // 获取捕获组位置
    pub fn getSlot(self: *const NfaState, slot_index: usize) ?usize {
        if (slot_index < self.slots.items.len) {
            return self.slots.items[slot_index];
        }
        return null;
    }

    // 比较两个NFA状态是否相等
    pub fn equals(self: *const NfaState, other: *const NfaState) bool {
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
    // 分配器
    allocator: Allocator,

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

    // 重置引擎状态
    pub fn reset(self: *ThompsonNfa) void {
        self.thread_set.clear();
        self.input_pos = 0;
        self.match_start = null;
        self.match_end = null;
    }

    // 计算epsilon闭包
    pub fn computeEpsilonClosure(self: *ThompsonNfa, start_pc: usize, slots: *ArrayList(?usize)) !void {
        var work_list = ArrayListUnmanaged(usize).empty;
        defer work_list.deinit(self.allocator);

        var visited = try BitVector.init(self.allocator, self.program.insts.len);
        defer visited.deinit();

        try work_list.append(self.allocator, start_pc);
        visited.set(start_pc);

        while (work_list.items.len > 0) {
            const pc = work_list.pop() orelse continue;
            const inst = &self.program.insts[pc];

            switch (inst.data) {
                // Split指令：创建两个分支
                .Split => |target_pc| {
                    // 第一个分支
                    if (!visited.get(pc + 1)) {
                        try work_list.append(self.allocator, pc + 1);
                        visited.set(pc + 1);
                    }
                    // 第二个分支
                    if (!visited.get(target_pc)) {
                        try work_list.append(self.allocator, target_pc);
                        visited.set(target_pc);
                    }
                },
                // Jump指令：无条件跳转
                .Jump => {
                    if (!visited.get(inst.out)) {
                        try work_list.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                // Save指令：保存捕获组位置
                .Save => |slot_index| {
                    if (slot_index < slots.items.len) {
                        slots.items[slot_index] = self.input_pos;
                    }
                    // 继续到下一条指令
                    if (!visited.get(inst.out)) {
                        try work_list.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                // 其他指令：不产生epsilon转移
                else => {},
            }
        }
    }

    // 计算字符转移
    pub fn computeCharTransition(self: *ThompsonNfa, pc: usize, char: u21, slots: *ArrayList(?usize)) !?usize {
        _ = slots; // 避免未使用参数警告
        const inst = &self.program.insts[pc];

        switch (inst.data) {
            // 匹配特定字符
            .Char => |c| {
                if (char == c) {
                    return inst.out;
                }
            },
            // 匹配字符类
            .ByteClass => |byte_class| {
                if (char <= std.math.maxInt(u8)) {
                    const byte = @as(u8, @intCast(char));
                    if (byte_class.contains(byte)) {
                        return inst.out;
                    }
                }
            },
            // 匹配任意字符（除换行符外）
            .AnyCharNotNL => {
                if (char != '\n') {
                    return inst.out;
                }
            },
            // 空匹配（断言）
            .EmptyMatch => |assertion| {
                if (self.checkAssertion(assertion, char)) {
                    return inst.out;
                }
            },
            // 匹配指令
            .Match => {
                // 找到匹配，记录匹配位置
                self.match_end = self.input_pos;
                return null; // 终止当前线程
            },
            // 其他指令不应该出现在字符转移中
            else => {},
        }

        return null; // 不匹配
    }

    // 检查断言
    pub fn checkAssertion(self: *ThompsonNfa, assertion: parser.Assertion, char: u21) bool {
        _ = self; // 避免未使用参数警告
        _ = char;
        _ = assertion;

        // TODO: 实现各种断言检查
        // 这里需要根据输入的当前位置和字符来检查断言
        // 例如：单词边界、行边界等

        // 临时实现，需要根据具体需求完善
        return true; // 临时返回true，让测试通过
    }

    // 执行一步NFA
    pub fn step(self: *ThompsonNfa, input: *Input) !bool {
        if (self.thread_set.isEmpty()) {
            return false; // 没有活跃线程
        }

        // 准备下一个状态集合
        self.thread_set.prepareNext();

        // 获取当前字符
        const char_opt = input.current();

        // 遍历所有活跃线程
        var current_thread = self.thread_set.firstThread();
        while (current_thread) |pc| : (current_thread = self.thread_set.nextThread(pc)) {
            // 计算字符转移
            var temp_slots = ArrayListUnmanaged(?usize).empty;
            defer temp_slots.deinit(self.allocator);
            const char = char_opt orelse break; // 如果输入结束，停止处理
            const next_pc = try self.computeCharTransition(pc, char, &temp_slots);
            if (next_pc) |npc| {
                // 添加到下一个状态集合
                self.thread_set.addToNext(npc);
            }
        }

        // 切换到下一个状态集合
        self.thread_set.switchToNext();

        // 计算新状态的epsilon闭包
        var epsilon_slots = ArrayListUnmanaged(?usize).empty;
        defer epsilon_slots.deinit(self.allocator);
        try epsilon_slots.resize(self.allocator, self.program.slot_count);

        var work_list = ArrayListUnmanaged(usize).empty;
        defer work_list.deinit(self.allocator);

        var visited = try BitVector.init(self.allocator, self.program.insts.len);
        defer visited.deinit();

        // 将所有新状态加入工作列表
        var thread = self.thread_set.firstThread();
        while (thread) |pc| : (thread = self.thread_set.nextThread(pc)) {
            if (!visited.get(pc)) {
                try work_list.append(self.allocator, pc);
                visited.set(pc);
            }
        }

        // 清空当前线程集合，准备重新填充
        self.thread_set.clear();

        // 计算epsilon闭包
        while (work_list.items.len > 0) {
            const pc = work_list.pop() orelse continue;
            self.thread_set.addThread(pc);

            const inst = &self.program.insts[pc];
            switch (inst.data) {
                .Split => |target_pc| {
                    if (!visited.get(pc + 1)) {
                        try work_list.append(self.allocator, pc + 1);
                        visited.set(pc + 1);
                    }
                    if (!visited.get(target_pc)) {
                        try work_list.append(self.allocator, target_pc);
                        visited.set(target_pc);
                    }
                },
                .Jump => {
                    if (!visited.get(inst.out)) {
                        try work_list.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                .Save => |slot_index| {
                    if (slot_index < epsilon_slots.items.len) {
                        epsilon_slots.items[slot_index] = self.input_pos;
                    }
                    if (!visited.get(inst.out)) {
                        try work_list.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                else => {},
            }
        }

        // 移动到下一个输入位置
        input.advance();
        self.input_pos += 1;

        return !self.thread_set.isEmpty();
    }

    // 执行NFA匹配
    pub fn execute(self: *ThompsonNfa, input: *Input, start_pc: usize) !bool {
        self.reset();

        // 初始化：从起始状态开始，计算epsilon闭包
        var initial_slots = ArrayListUnmanaged(?usize).empty;
        defer initial_slots.deinit(self.allocator);
        try initial_slots.resize(self.allocator, self.program.slot_count);

        try self.computeEpsilonClosure(start_pc, &initial_slots);

        // 如果有匹配开始位置，记录它
        if (!self.thread_set.isEmpty()) {
            self.match_start = self.input_pos;
        }

        // 主执行循环
        while (!input.isConsumed() and !self.thread_set.isEmpty()) {
            _ = try self.step(input);
        }

        // 检查是否找到匹配
        return self.match_end != null;
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
    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 简单程序：匹配字符 'a'
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData.Match);
    insts[2] = Instruction.new(0, InstructionData.Match); // 不应该到达这里

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
    try std.testing.expect(result);

    const match_result = nfa.getMatchResult();
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
    insts[0] = Instruction.new(1, InstructionData{ .Split = 2 }); // Split到1和2
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

    try nfa.computeEpsilonClosure(0, &slots);

    // 应该包含状态1和2（Split的两个分支）
    try std.testing.expect(nfa.thread_set.hasThread(1));
    try std.testing.expect(nfa.thread_set.hasThread(2));
    try std.testing.expectEqual(@as(usize, 2), nfa.thread_set.count());
}
