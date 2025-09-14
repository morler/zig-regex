const std = @import("std");
const Allocator = std.mem.Allocator;
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

pub const ThompsonNfa = struct {
    program: *const Program,
    thread_set: ThreadSet,
    input_pos: usize,
    match_start: ?usize,
    match_end: ?usize,
    allocator: Allocator,
    slots: ?*std.ArrayListUnmanaged(?usize) = null,

    pub fn init(allocator: Allocator, program: *const Program) !ThompsonNfa {
        return ThompsonNfa{
            .program = program,
            .thread_set = try ThreadSet.init(allocator, program.insts.len),
            .input_pos = 0,
            .match_start = null,
            .match_end = null,
            .allocator = allocator,
            .slots = null,
        };
    }

    pub fn deinit(self: *ThompsonNfa) void {
        self.thread_set.deinit();
    }

    pub fn setSlots(self: *ThompsonNfa, slots: *std.ArrayListUnmanaged(?usize)) void {
        self.slots = slots;
    }

    fn addClosureFrom(self: *ThompsonNfa, start_pc: usize, slots_len: usize, input: *Input, out_set: *BitVector) !void {
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
                    if (self.slots) |slots_ptr| {
                        if (slot_index < slots_len) {
                            // Save current input position into capture slot
                            if (slots_ptr.items.len < slots_len) {
                                try slots_ptr.resize(self.allocator, slots_len);
                            }
                            slots_ptr.items[slot_index] = self.input_pos;
                        }
                    }
                    if (!visited.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        visited.set(inst.out);
                    }
                },
                .EmptyMatch => |assertion| {
                    if (input.isEmptyMatch(assertion)) {
                        if (!visited.get(inst.out)) {
                            try stack.append(self.allocator, inst.out);
                            visited.set(inst.out);
                        }
                    }
                },
                .Match => {
                    self.match_end = self.input_pos;
                },
                else => {
                    visited.set(pc);
                },
            }
        }

        var it = visited.firstSet();
        while (it) |state| : (it = visited.nextSet(state)) {
            out_set.set(state);
        }
    }

    fn computeEpsilonClosureForCurrentSet(self: *ThompsonNfa, input: *Input) !void {
        // Copy current to temp and clear current
        self.thread_set.copyToTemp();
        self.thread_set.current.clear();

        const temp = self.thread_set.getTemp();
        var it = temp.firstSet();
        while (it) |pc| : (it = temp.nextSet(pc)) {
            try self.addClosureFrom(pc, self.program.slot_count, input, &self.thread_set.current);
        }
    }

    fn computeCharTransition(self: *ThompsonNfa, pc: usize, ch: u21, input: *Input) ?usize {
        _ = input;
        const inst = &self.program.insts[pc];
        return switch (inst.data) {
            .Char => |c| if (ch == c) inst.out else null,
            .ByteClass => |bc| blk: {
                if (ch <= std.math.maxInt(u8)) {
                    const b: u8 = @intCast(ch);
                    break :blk if (bc.contains(b)) inst.out else null;
                }
                break :blk null;
            },
            .AnyCharNotNL => if (ch != '\n') inst.out else null,
            else => null,
        };
    }

    fn step(self: *ThompsonNfa, input: *Input) !bool {
        if (self.thread_set.isEmpty()) return false;

        self.thread_set.prepareNext();
        const ch = input.current() orelse {
            self.thread_set.switchToNext();
            return false;
        };

        var it = self.thread_set.firstThread();
        while (it) |pc| : (it = self.thread_set.nextThread(pc)) {
            if (self.computeCharTransition(pc, ch, input)) |npc| {
                self.thread_set.addToNext(npc);
            }
        }

        self.thread_set.switchToNext();
        // 先前进输入位置，再计算基于当前位置的 epsilon 闭包（用于 \b、$ 等）
        input.advance();
        self.input_pos += 1;
        try self.computeEpsilonClosureForCurrentSet(input);
        return !self.thread_set.isEmpty();
    }

    pub fn reset(self: *ThompsonNfa) void {
        self.thread_set.clear();
        self.input_pos = 0;
        self.match_start = null;
        self.match_end = null;
    }

    pub fn execute(self: *ThompsonNfa, input: *Input, start_pc: usize) !bool {
        self.reset();

        try self.addClosureFrom(start_pc, self.program.slot_count, input, &self.thread_set.current);
        if (!self.thread_set.isEmpty()) self.match_start = self.input_pos;

        while (!input.isConsumed() and !self.thread_set.isEmpty()) {
            _ = try self.step(input);
        }

        if (!self.thread_set.isEmpty()) {
            try self.computeEpsilonClosureForCurrentSet(input);
        }

        return self.match_end != null;
    }

    pub fn getMatchResult(self: *const ThompsonNfa) struct { start: ?usize, end: ?usize } {
        return .{ .start = self.match_start, .end = self.match_end };
    }
};
