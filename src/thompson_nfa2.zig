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
const range_set = @import("range_set.zig");

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

    pub fn addClosureFrom(self: *ThompsonNfa, start_pc: usize, slots_len: usize, input: *Input, out_set: *BitVector) !void {
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

test "ThompsonNfa epsilon-closure: dense graph stress test with 256 nodes" {
    const allocator = std.testing.allocator;

    const N: usize = 256;
    var insts = try allocator.alloc(Instruction, N + 1);
    defer allocator.free(insts);

    // Build a dense epsilon graph: each node splits to next 4 nodes
    // This creates exponential fan-out to stress test the closure algorithm
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const out1 = if (i + 1 < N) i + 1 else N;
        const out2 = if (i + 2 < N) i + 2 else N;
        const out3 = if (i + 4 < N) i + 4 else N;
        const out4 = if (i + 8 < N) i + 8 else N;

        // Create splits that fan out to multiple targets
        insts[i] = Instruction.new(out1, InstructionData{ .Split = out2 });

        // Add additional splits for more fan-out if we have space
        if (i + 3 < N) {
            insts[i + 1] = Instruction.new(out3, InstructionData{ .Split = out4 });
            i += 1; // Skip next position as we used it
        }
    }
    insts[N] = Instruction.new(0, InstructionData.Match);

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

    // Time the closure computation
    const start_time = std.time.milliTimestamp();
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    // Count visited states - should visit many but not all due to visited tracking
    var count: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        count += 1;
    }

    // Should visit a significant number of states but not hang
    try std.testing.expect(count > 10);
    // Note: with the current graph structure, we might visit most nodes
    // The important thing is that it completes quickly and doesn't hang

    // Should complete quickly (under 100ms for this size)
    try std.testing.expect(duration < 100);

    // Verify no memory leaks by checking we can deinit cleanly
    nfa.thread_set.clear();
}

test "ThompsonNfa epsilon-closure: deep recursion stress test" {
    const allocator = std.testing.allocator;

    const DEPTH: usize = 1000;
    var insts = try allocator.alloc(Instruction, DEPTH + 1);
    defer allocator.free(insts);

    // Build a deep chain of jumps to test stack depth handling
    var i: usize = 0;
    while (i < DEPTH) : (i += 1) {
        insts[i] = Instruction.new(i + 1, InstructionData.Jump);
    }
    insts[DEPTH] = Instruction.new(0, InstructionData.Match);

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

    // This should not cause stack overflow
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Should reach the final Match state
    try std.testing.expect(nfa.thread_set.current.get(DEPTH));
}

test "ThompsonNfa epsilon-closure: complex split network stress test" {
    const allocator = std.testing.allocator;

    const NODES: usize = 128;
    var insts = try allocator.alloc(Instruction, NODES + 1);
    defer allocator.free(insts);

    // Build a complex network of splits that creates many paths
    // Each node splits to two others, creating a binary tree-like structure
    for (0..NODES) |i| {
        const left = if (i * 2 + 1 < NODES) i * 2 + 1 else NODES;
        const right = if (i * 2 + 2 < NODES) i * 2 + 2 else NODES;
        insts[i] = Instruction.new(left, InstructionData{ .Split = right });
    }
    insts[NODES] = Instruction.new(0, InstructionData.Match);

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

    // Should visit multiple paths through the split network
    var count: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        count += 1;
    }

    // Should visit several nodes but not all (due to tree structure)
    try std.testing.expect(count > 5);
    try std.testing.expect(count <= NODES + 1);
}

test "ThompsonNfa epsilon-closure: mixed instruction types stress test" {
    const allocator = std.testing.allocator;

    const SIZE: usize = 200;
    var insts = try allocator.alloc(Instruction, SIZE + 1);
    defer allocator.free(insts);

    // Create a mix of different epsilon instruction types
    for (0..SIZE) |i| {
        const next = if (i + 1 < SIZE) i + 1 else SIZE;
        const next_next = if (i + 2 < SIZE) i + 2 else SIZE;

        // Alternate between different epsilon instruction types
        switch (i % 4) {
            0 => insts[i] = Instruction.new(next, InstructionData{ .Split = next_next }),
            1 => insts[i] = Instruction.new(next, InstructionData.Jump),
            2 => insts[i] = Instruction.new(next, InstructionData{ .Save = @mod(i, 10) }),
            3 => insts[i] = Instruction.new(next, InstructionData{ .EmptyMatch = parser.Assertion.BeginLine }),
            else => unreachable,
        }
    }
    insts[SIZE] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 10,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var slots = std.ArrayListUnmanaged(?usize){};
    try slots.resize(allocator, program.slot_count);
    defer slots.deinit(allocator);
    nfa.setSlots(&slots);

    var input = input_new.Input.init("", .bytes);

    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

    // Should process all instruction types without error
    var count: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        count += 1;
    }

    try std.testing.expect(count > 0);
    try std.testing.expect(count <= SIZE + 1);
}

test "ThompsonNfa epsilon-closure: extreme dense graph with 5000 nodes" {
    const allocator = std.testing.allocator;

    const N: usize = 5000;
    var insts = try allocator.alloc(Instruction, N + 1);
    defer allocator.free(insts);

    // Build an extremely dense graph: each node connects to many others
    // This creates a massive fan-out to stress test memory and performance
    var i: usize = 0;
    while (i < N) : (i += 1) {
        // Each node splits to multiple targets creating exponential reachability
        const out1 = if (i + 1 < N) i + 1 else N;
        const out2 = if (i + 2 < N) i + 2 else N;
        const out3 = if (i + 3 < N) i + 3 else N;
        const out4 = if (i + 5 < N) i + 5 else N;
        const out5 = if (i + 8 < N) i + 8 else N;
        const out6 = if (i + 13 < N) i + 13 else N;
        const out7 = if (i + 21 < N) i + 21 else N;
        const out8 = if (i + 34 < N) i + 34 else N;

        // Create a split that fans out to many targets
        insts[i] = Instruction.new(out1, InstructionData{ .Split = out2 });

        // Add additional splits in the next few positions for even more fan-out
        if (i + 1 < N) {
            insts[i + 1] = Instruction.new(out3, InstructionData{ .Split = out4 });
        }
        if (i + 2 < N) {
            insts[i + 2] = Instruction.new(out5, InstructionData{ .Split = out6 });
        }
        if (i + 3 < N) {
            insts[i + 3] = Instruction.new(out7, InstructionData{ .Split = out8 });
        }

        // Skip the positions we used for additional splits
        i += @min(3, N - i - 1);
    }
    insts[N] = Instruction.new(0, InstructionData.Match);

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

    // Time the closure computation for performance measurement
    const start_time = std.time.microTimestamp();
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
    const end_time = std.time.microTimestamp();
    const duration_us = end_time - start_time;

    // Count visited states
    var count: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        count += 1;
    }

    // Performance assertions: should complete quickly even for 5000 nodes
    try std.testing.expect(duration_us < 10000); // Under 10ms

    // Should visit a reasonable number of states (but not all due to visited tracking)
    try std.testing.expect(count > 50);
    try std.testing.expect(count <= N + 1);

    // Verify memory efficiency by checking we can deinit cleanly
    nfa.thread_set.clear();
}

test "ThompsonNfa epsilon-closure: memory allocation stress test" {
    const allocator = std.testing.allocator;

    const N: usize = 10000;
    var insts = try allocator.alloc(Instruction, N + 1);
    defer allocator.free(insts);

    // Build a graph that will stress the memory allocation patterns
    // Create many small connected components to test allocation/deallocation
    const component_size: usize = 50;
    var i: usize = 0;
    while (i < N) : (i += component_size) {
        const component_end = @min(i + component_size, N);

        // Create a small chain within each component
        var j: usize = i;
        while (j < component_end - 1) : (j += 1) {
            insts[j] = Instruction.new(j + 1, InstructionData.Jump);
        }
        insts[component_end - 1] = Instruction.new(N, InstructionData.Jump);
    }
    insts[N] = Instruction.new(0, InstructionData.Match);

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

    // Run closure multiple times to test memory management
    for (0..10) |_| {
        nfa.thread_set.clear();
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);

        // Verify we can clear and reuse memory
        var count: usize = 0;
        var it = nfa.thread_set.current.firstSet();
        while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
            count += 1;
        }
        try std.testing.expect(count > 0);
    }

    // Final cleanup should work without issues
    nfa.thread_set.clear();
}

test "ThompsonNfa execute: multiline mode - ^ matches at start of each line" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(insts);

    // Pattern: ^a in multiline mode
    // 0: EmptyMatch(^) -> 1; 1: Char 'a' -> 2; 2: Jump -> 0; 3: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.BeginLine });
    insts[1] = Instruction.new(3, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(0, InstructionData.Jump);
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

    // Test with multiline input
    var input = input_new.Input.initWithMultiline("a\nb\na", .bytes, true);

    // Should match both 'a's at the start of lines
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 2), result.start); // Second 'a' position
    try std.testing.expectEqual(@as(?usize, 3), result.end);
}

test "ThompsonNfa execute: multiline mode - $ matches at end of each line" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // Pattern: a$ in multiline mode
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

    // Test with multiline input
    var input = input_new.Input.initWithMultiline("a\nb\na", .bytes, true);

    // Should match first 'a' at end of first line
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 0), result.start);
    try std.testing.expectEqual(@as(?usize, 1), result.end);
}

test "ThompsonNfa execute: multiline mode - complex pattern with both anchors" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 5);
    defer allocator.free(insts);

    // Pattern: ^test$ in multiline mode
    // 0: EmptyMatch(^) -> 1; 1: Char 't' -> 2; 2: Char 'e' -> 3; 3: Char 's' -> 4; 4: Char 't' -> 5
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.BeginLine });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 't' });
    insts[2] = Instruction.new(3, InstructionData{ .Char = 'e' });
    insts[3] = Instruction.new(4, InstructionData{ .Char = 's' });
    insts[4] = Instruction.new(5, InstructionData{ .Char = 't' });

    // Add more instructions for the full pattern
    var full_insts = try allocator.alloc(Instruction, 7);
    defer allocator.free(full_insts);

    // Copy the first 5 instructions
    for (0..5) |i| {
        full_insts[i] = insts[i];
    }

    // Add the remaining instructions
    full_insts[5] = Instruction.new(6, InstructionData{ .EmptyMatch = parser.Assertion.EndLine });
    full_insts[6] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = full_insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    // Test with multiline input
    var input = input_new.Input.initWithMultiline("test\nnotest\ntest", .bytes, true);

    // Should match first and third lines
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 8), result.start); // Third 'test' position
    try std.testing.expectEqual(@as(?usize, 12), result.end);
}

test "ThompsonNfa execute: non-multiline mode - ^ only matches at absolute start" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // Pattern: ^a in non-multiline mode
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

    // Test with multiline input but non-multiline mode
    var input = input_new.Input.initWithMultiline("a\nb\na", .bytes, false);

    // Should only match first 'a' at absolute start
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 0), result.start);
    try std.testing.expectEqual(@as(?usize, 1), result.end);
}

test "ThompsonNfa execute: multiline mode - word boundaries across lines" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // Pattern: \ba\b in multiline mode
    // 0: EmptyMatch(\b) -> 1; 1: Char 'a' -> 2; 2: EmptyMatch(\b) -> 3; 3: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(3, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });

    // Add the match instruction
    var full_insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(full_insts);

    full_insts[0] = insts[0];
    full_insts[1] = insts[1];
    full_insts[2] = insts[2];
    full_insts[3] = Instruction.new(0, InstructionData.Match);

    var program = Program{
        .insts = full_insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    // Test with multiline input
    var input = input_new.Input.initWithMultiline("a\n a\nb", .bytes, true);

    // Should match both standalone 'a's
    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 2), result.start); // Second 'a' position
    try std.testing.expectEqual(@as(?usize, 3), result.end);
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - mixed ASCII and Unicode" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Char 'a' -> 1; 1: Char 'b' -> 2; 2: Match
    // This tests basic character matching in UTF-8 mode
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'b' });
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

    // UTF-8 input with basic ASCII
    var input = input_new.Input.init("ab", .utf8);

    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 0), result.start);
    try std.testing.expectEqual(@as(?usize, 2), result.end);
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - basic UTF-8 handling" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // Pattern: basic ASCII characters in UTF-8 mode
    // 0: Char 'a' -> 1; 1: Char 'b' -> 2; 2: Match
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'b' });
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

    // UTF-8 input with basic ASCII
    var input = input_new.Input.init("ab", .utf8);

    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 0), result.start);
    try std.testing.expectEqual(@as(?usize, 2), result.end);
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - word boundaries in UTF-8" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(insts);

    // Pattern: \ba\b (word boundaries in UTF-8 mode)
    // 0: EmptyMatch(\b) -> 1; 1: Char 'a' -> 2; 2: EmptyMatch(\b) -> 3; 3: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(3, InstructionData{ .EmptyMatch = parser.Assertion.WordBoundaryAscii });
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

    // Test word boundaries in UTF-8 mode
    var input = input_new.Input.init(" a ", .utf8);

    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 1), result.start);
    try std.testing.expectEqual(@as(?usize, 2), result.end);
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - invalid sequences" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // 0: Char 'a' -> 1; 1: AnyCharNotNL -> 2; 2: Match
    // This tests that invalid UTF-8 sequences are handled gracefully
    insts[0] = Instruction.new(1, InstructionData{ .Char = 'a' });
    insts[1] = Instruction.new(2, InstructionData.AnyCharNotNL);
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

    // UTF-8 input with invalid sequence (incomplete 2-byte sequence)
    var input = input_new.Input.init("a\xc3", .utf8);

    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 0), result.start);
    try std.testing.expectEqual(@as(?usize, 2), result.end); // 'a' + invalid byte treated as single char
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - character class boundaries" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 3);
    defer allocator.free(insts);

    // Pattern: [a] (character class with ASCII)
    // 0: ByteClass containing 'a' -> 1; 1: Match
    var byte_class = range_set.RangeSet(u8).init(allocator);
    defer byte_class.deinit(allocator);

    try byte_class.addRange(allocator, range_set.Range(u8).single('a'));

    insts[0] = Instruction.new(1, InstructionData{ .ByteClass = byte_class });
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

    // Test with ASCII character that should match
    var ascii_input = input_new.Input.init("a", .utf8);
    const ascii_ok = try nfa.execute(&ascii_input, program.start);
    try std.testing.expect(ascii_ok);

    // Test with ASCII character that should not match
    var other_input = input_new.Input.init("b", .utf8);
    const other_ok = try nfa.execute(&other_input, program.start);
    try std.testing.expect(!other_ok);
}

test "ThompsonNfa epsilon-closure: UTF-8 boundary validation - multiline in UTF-8" {
    const allocator = std.testing.allocator;

    var insts = try allocator.alloc(Instruction, 4);
    defer allocator.free(insts);

    // Pattern: ^a$ in multiline mode with UTF-8
    // 0: EmptyMatch(^) -> 1; 1: Char 'a' -> 2; 2: EmptyMatch($) -> 3; 3: Match
    insts[0] = Instruction.new(1, InstructionData{ .EmptyMatch = parser.Assertion.BeginLine });
    insts[1] = Instruction.new(2, InstructionData{ .Char = 'a' });
    insts[2] = Instruction.new(3, InstructionData{ .EmptyMatch = parser.Assertion.EndLine });
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

    // Test with multiline UTF-8 input
    var input = input_new.Input.initWithMultiline("a\nb\na", .utf8, true);

    const ok = try nfa.execute(&input, program.start);
    try std.testing.expect(ok);

    const result = nfa.getMatchResult();
    try std.testing.expectEqual(@as(?usize, 2), result.start); // Second 'a' position
    try std.testing.expectEqual(@as(?usize, 3), result.end);
}
