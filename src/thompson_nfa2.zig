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

test "ThompsonNfa epsilon-closure: split fan-out" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(insts);

    // 0: Split -> 1 and 2; 1: Char 'a' -> 3; 2: Char 'b' -> 3; 3: Match
    insts[0] = Instruction.new(1, InstructionData{ .Split = 2 });
    insts[1] = Instruction.new(3, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(3, InstructionData{ .Char = 'b' });
    insts[3] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);

    // Seed closure from start
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Expect both char states to be active; split itself may also be marked
    try std.testing.expect(nfa.thread_set.current.get(1));
    try std.testing.expect(nfa.thread_set.current.get(2));
}

test "ThompsonNfa epsilon-closure: EmptyMatch anchor" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: EmptyMatch(^) -> 1; 1: Char 'a' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.BeginLine });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("a", .bytes);

    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // At start of line, anchor allows transition to char state
    try std.testing.expect(nfa.thread_set.current.get(1));
}

test "ThompsonNfa epsilon-closure: Save writes slot" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Save(0) -> 1; 1: Char 'x' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .Save = 0 });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'x' });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 1,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var slots = std.ArrayListUnmanaged(?usize){};
    try slots.resize(allocator, program.slot_count);
    defer slots.deinit(allocator);
    nfa.setSlots(&slots);

    var input = input_new.Input.init("x", .bytes);

    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    try std.testing.expectEqual(@as(?usize, 0), slots.items[0]);
}

test "ThompsonNfa epsilon-closure: EndLine ($) at end-of-input" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 2);
    defer allocator.free(insts);

    // 0: EmptyMatch($) -> 1; 1: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.EndLine });
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

    // Empty input: position is both start and end, so $ holds
    var input = input_new.Input.init("", .bytes);
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Expect transition to Match is enabled (closure reaches pc=1)
    try std.testing.expect(nfa.thread_set.current.get(1));
}

test "ThompsonNfa execute: pattern a$ matches 'a'" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Char 'a' -> 1; 1: EmptyMatch($) -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData{ .EmptyMatch = parser.Assertion.EndLine });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("a", .bytes);
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);
}

test "ThompsonNfa epsilon-closure: handles epsilon cycles without infinite loop" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Split -> (1, 2); 1: Jump -> 0; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .Split = 1 }); // out=1, branch=1 (self-branch)
    insts[1] = Instruction.new(0, InstructionData.Jump); // out=0
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Should visit 0 and 1 but not hang; 2 is not reached by closure
    try std.testing.expect(nfa.thread_set.current.get(0));
    try std.testing.expect(nfa.thread_set.current.get(1));
    try std.testing.expect(!nfa.thread_set.current.get(2));
}

test "ThompsonNfa epsilon-closure: WordBoundary (\\b) at start before word char" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: \b -> 1; 1: Char 'a' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("a", .bytes);

    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // At start before a word char, \b holds, allowing transition to 1
    try std.testing.expect(nfa.thread_set.current.get(1));
}

test "ThompsonNfa execute: pattern a$ does not match 'ab'" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Char 'a' -> 1; 1: EmptyMatch($) -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData{ .EmptyMatch = parser.Assertion.EndLine });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("ab", .bytes);
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(!ok);
}

test "ThompsonNfa epsilon-closure: Not a word boundary (\\B) at start before non-word" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: \B -> 1; 1: Char 'a' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.NotWordBoundaryAscii });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("a", .bytes);

    // At start before a word char, it's a boundary => \B should not allow transition
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
    try std.testing.expect(!nfa.thread_set.current.get(1));
}

test "ThompsonNfa epsilon-closure: dense epsilon chain stress" {
    const allocator = std.testing.allocator;

    const N: usize = 64;
    var insts = try allocator.alloc(Instruction, N + 1);
    defer allocator.free(insts);

    // Build a chain of N-1 splits/jumps ending at a Match
    // 0: Split -> 1 and 2
    // 1: Split -> 2 and 3
    // ... creating many reachable states via closure
    var i: usize = 0;
    while (i < N - 1) : (i += 1) {
        const out = if (i + 1 < N - 1) i + 1 else N - 1;
        const branch = if (i + 2 < N - 1) i + 2 else N - 1;
        insts[i] = Instruction.new(out, InstructionData{ .Split = branch });
    }
    insts[N - 1] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Count visited states; should be >= N-1 (many reachable states)
    var count: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        count += 1;
    }
    try std.testing.expect(count >= N - 1);
}

test "ThompsonNfa epsilon-closure: UTF-8 input word boundary at start before ASCII 'a'" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: \b -> 1; 1: Char 'a' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    // UTF-8 mode input containing ASCII 'a'
    var input = input_new.Input.init("a", .utf8);
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
    try std.testing.expect(nfa.thread_set.current.get(1));
}
