const std = @import("std");
const Allocator = std.mem.Allocator;

const thompson_nfa2 = @import("thompson_nfa2.zig");
const ThompsonNfa = thompson_nfa2.ThompsonNfa;
const compile = @import("compile.zig");
const input_new = @import("input_new.zig");

pub fn benchmarkEpsilonClosure(allocator: Allocator) !void {
      const print = std.debug.print;

    print("=== Epsilon-Closure 性能基准测试 ===\n\n", .{});

    // 测试1: 简单 Split 扇出
    try benchmarkSplitFanOut(allocator);

    // 测试2: 深度递归
    try benchmarkDeepRecursion(allocator);

    // 测试3: 密集图压力测试
    try benchmarkDenseGraph(allocator);

    // 测试4: 复杂网络
    try benchmarkComplexNetwork(allocator);
}

fn benchmarkSplitFanOut(allocator: Allocator) !void {
    const print = std.debug.print;

    // 创建一个简单的 Split 扇出图
    const N = 100;
    var insts = try allocator.alloc(compile.Instruction, N + 1);
    defer allocator.free(insts);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const out = if (i + 1 < N) i + 1 else N;
        const branch = if (i + 2 < N) i + 2 else N;
        insts[i] = compile.Instruction.new(out, compile.InstructionData{ .Split = branch });
    }
    insts[N] = compile.Instruction.new(0, compile.InstructionData.Match);

    var program = compile.Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 1000;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));

    print("Split Fan Out ({} 节点):\n", .{N});
    print("  总时间: {} ms\n", .{duration});
    print("  平均时间: {d:.3} ms\n", .{avg_time});
    print("  吞吐量: {d:.1} ops/sec\n", .{1000.0 / avg_time});
    print("\n", .{});
}

fn benchmarkDeepRecursion(allocator: Allocator) !void {
    const print = std.debug.print;

    // 创建深度递归图
    const DEPTH = 1000;
    var insts = try allocator.alloc(compile.Instruction, DEPTH + 1);
    defer allocator.free(insts);

    var i: usize = 0;
    while (i < DEPTH) : (i += 1) {
        insts[i] = compile.Instruction.new(i + 1, compile.InstructionData.Jump);
    }
    insts[DEPTH] = compile.Instruction.new(0, compile.InstructionData.Match);

    var program = compile.Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 1000;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));

    print("深度递归 ({} 层):\n", .{DEPTH});
    print("  总时间: {} ms\n", .{duration});
    print("  平均时间: {d:.3} ms\n", .{avg_time});
    print("  吞吐量: {d:.1} ops/sec\n", .{1000.0 / avg_time});
    print("\n", .{});
}

fn benchmarkDenseGraph(allocator: Allocator) !void {
    const print = std.debug.print;

    // 创建密集图
    const N = 256;
    var insts = try allocator.alloc(compile.Instruction, N + 1);
    defer allocator.free(insts);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const out1 = if (i + 1 < N) i + 1 else N;
        const out2 = if (i + 2 < N) i + 2 else N;
        const out3 = if (i + 4 < N) i + 4 else N;
        const out4 = if (i + 8 < N) i + 8 else N;

        insts[i] = compile.Instruction.new(out1, compile.InstructionData{ .Split = out2 });

        if (i + 3 < N) {
            insts[i + 1] = compile.Instruction.new(out3, compile.InstructionData{ .Split = out4 });
            i += 1;
        }
    }
    insts[N] = compile.Instruction.new(0, compile.InstructionData.Match);

    var program = compile.Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 5) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 100;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));

    print("密集图 ({} 节点):\n", .{N});
    print("  总时间: {} ms\n", .{duration});
    print("  平均时间: {d:.3} ms\n", .{avg_time});
    print("  吞吐量: {d:.1} ops/sec\n", .{1000.0 / avg_time});
    print("\n", .{});
}

fn benchmarkComplexNetwork(allocator: Allocator) !void {
    const print = std.debug.print;

    // 创建复杂网络
    const NODES = 128;
    var insts = try allocator.alloc(compile.Instruction, NODES + 1);
    defer allocator.free(insts);

    for (0..NODES) |i| {
        const left = if (i * 2 + 1 < NODES) i * 2 + 1 else NODES;
        const right = if (i * 2 + 2 < NODES) i * 2 + 2 else NODES;
        insts[i] = compile.Instruction.new(left, compile.InstructionData{ .Split = right });
    }
    insts[NODES] = compile.Instruction.new(0, compile.InstructionData.Match);

    var program = compile.Program{
        .insts = insts,
        .start = 0,
        .find_start = 0,
        .slot_count = 0,
        .allocator = allocator,
    };

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input = input_new.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 500;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(duration)) / @as(f64, @floatFromInt(iterations));

    print("复杂网络 ({} 节点):\n", .{NODES});
    print("  总时间: {} ms\n", .{duration});
    print("  平均时间: {d:.3} ms\n", .{avg_time});
    print("  吞吐量: {d:.1} ops/sec\n", .{1000.0 / avg_time});
    print("\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try benchmarkEpsilonClosure(allocator);
}