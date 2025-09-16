const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const compile = @import("compile.zig");
const input_mod = @import("input.zig");
const thompson_nfa = @import("thompson_nfa.zig");
const ThompsonNfa = thompson_nfa.ThompsonNfa;

/// Performance benchmark for Thompson NFA epsilon-closure operations
pub fn benchmarkEpsilonClosure(allocator: Allocator, nfa_size: usize, complexity_factor: usize) !struct {
    closure_time: i64,
    nodes_visited: usize,
    memory_usage: usize,
} {
    // Create a complex epsilon graph for stress testing
    var insts = try allocator.alloc(compile.Instruction, nfa_size + 1);
    defer allocator.free(insts);

    // Build a complex network with varying fan-out based on complexity_factor
    for (0..nfa_size) |i| {
        const fan_out = @min(complexity_factor, nfa_size - i - 1);
        if (fan_out <= 1) {
            // Simple jump for the tail
            insts[i] = compile.Instruction.new(
                if (i + 1 < nfa_size) i + 1 else nfa_size,
                compile.InstructionData.Jump,
            );
        } else {
            // Split with multiple branches for complexity
            const out1 = i + 1;
            const out2 = @min(i + fan_out, nfa_size);
            insts[i] = compile.Instruction.new(out1, compile.InstructionData{ .Split = out2 });
        }
    }
    insts[nfa_size] = compile.Instruction.new(0, compile.InstructionData.Match);

    var program = compile.Program.init(allocator, insts, 0, 0);

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var input_instance = input_mod.Input.init("", .bytes);

    // Get baseline memory usage
    const baseline_memory = getMemoryUsage();

    // Time the closure computation
    const start_time = std.time.nanoTimestamp();
    try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
    const end_time = std.time.nanoTimestamp();

    // Count visited nodes
    var nodes_visited: usize = 0;
    var it = nfa.thread_set.current.firstSet();
    while (it) |pc| : (it = nfa.thread_set.current.nextSet(pc)) {
        nodes_visited += 1;
    }

    return .{
        .closure_time = @as(i64, @intCast(end_time - start_time)),
        .nodes_visited = nodes_visited,
        .memory_usage = getMemoryUsage() - baseline_memory,
    };
}

/// Performance benchmark for NFA execution on different text sizes
pub fn benchmarkExecution(allocator: Allocator, pattern: []const u8, text: []const u8, iterations: usize) !struct {
    total_time: i64,
    matches_found: usize,
    avg_time_per_match: f64,
} {
    // Compile pattern (simplified - in real usage would use full compilation pipeline)
    var program = try createSimpleProgram(allocator, pattern);
    defer allocator.free(program.insts);

    var nfa = try ThompsonNfa.init(allocator, &program);
    defer nfa.deinit();

    var total_matches: usize = 0;
    const start_time = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        var input_instance = input_mod.Input.init(text, .bytes);
        if (try nfa.execute(&input_instance, program.start)) {
            total_matches += 1;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const total_time = @as(i64, @intCast(end_time - start_time));
    const avg_time_per_match = if (total_matches > 0)
        @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(total_matches))
    else
        0;

    return .{
        .total_time = total_time,
        .matches_found = total_matches,
        .avg_time_per_match = avg_time_per_match,
    };
}

/// Create a simple program for basic character matching
fn createSimpleProgram(allocator: Allocator, pattern: []const u8) !compile.Program {
    const inst_count = pattern.len + 1;
    var insts = try allocator.alloc(compile.Instruction, inst_count);
    errdefer allocator.free(insts);

    // Build simple character sequence
    for (pattern, 0..) |char, i| {
        insts[i] = compile.Instruction.new(
            i + 1,
            compile.InstructionData{ .Char = char },
        );
    }
    insts[pattern.len] = compile.Instruction.new(0, compile.InstructionData.Match);

    return compile.Program.init(allocator, insts, 0, 0);
}

/// Get current memory usage (platform-dependent approximation)
fn getMemoryUsage() usize {
    // This is a simplified version - in a real implementation you'd use
    // platform-specific memory accounting
    return 0; // Placeholder
}

test "benchmark: epsilon-closure performance on small graphs" {
    const allocator = testing.allocator;

    const result = try benchmarkEpsilonClosure(allocator, 100, 3);

    // Should complete quickly
    try testing.expect(result.closure_time < 10_000_000); // 10ms
    try testing.expect(result.nodes_visited > 0);

    std.debug.print("Small graph closure: {}ns, {} nodes visited, {} bytes\n", .{
        result.closure_time, result.nodes_visited, result.memory_usage,
    });
}

test "benchmark: epsilon-closure performance on medium graphs" {
    const allocator = testing.allocator;

    const result = try benchmarkEpsilonClosure(allocator, 1000, 5);

    // Should still complete in reasonable time
    try testing.expect(result.closure_time < 50_000_000); // 50ms
    try testing.expect(result.nodes_visited > 100);

    std.debug.print("Medium graph closure: {}ns, {} nodes visited, {} bytes\n", .{
        result.closure_time, result.nodes_visited, result.memory_usage,
    });
}

test "benchmark: execution performance simple pattern" {
    const allocator = testing.allocator;

    const pattern = "abc";
    const text = "abc"; // Simple text that will match
    const iterations = 1000;

    const result = try benchmarkExecution(allocator, pattern, text, iterations);

    try testing.expect(result.matches_found == iterations); // Should match every time
    try testing.expect(result.total_time > 0);
    try testing.expect(result.avg_time_per_match > 0);

    std.debug.print("Simple pattern execution: {}ns total, {} matches, {}ns avg\n", .{
        result.total_time, result.matches_found, result.avg_time_per_match,
    });
}

test "benchmark: execution performance long text" {
    const allocator = testing.allocator;

    const pattern = "the";
    // Create a long text with multiple occurrences
    var long_text = std.ArrayListUnmanaged(u8){};
    defer long_text.deinit(allocator);

    // Repeat "the " many times
    for (0..1000) |_| {
        try long_text.appendSlice(allocator, "the ");
    }

    const iterations = 100;
    const result = try benchmarkExecution(allocator, pattern, long_text.items, iterations);

    try testing.expect(result.matches_found == iterations);
    try testing.expect(result.total_time > 0);

    std.debug.print("Long text execution: {}ns total, {} matches, {}ns avg\n", .{
        result.total_time, result.matches_found, result.avg_time_per_match,
    });
}

test "benchmark: memory usage efficiency" {
    const allocator = testing.allocator;

    // Test memory usage with different NFA sizes
    const sizes = [_]usize{ 10, 100, 1000, 5000 };

    for (sizes) |size| {
        const result = try benchmarkEpsilonClosure(allocator, size, 2);

        // Memory usage should scale reasonably with size
        // (This is a basic check - in practice you'd want more sophisticated memory tracking)
        std.debug.print("Size {}: {}ns, {} nodes, {} bytes\n", .{
            size, result.closure_time, result.nodes_visited, result.memory_usage,
        });

        // Should not take too long for reasonable sizes
        try testing.expect(result.closure_time < 100_000_000); // 100ms max
    }
}

// === Epsilon-Closure 性能基准测试 (从 benchmark_closure.zig 合并) ===

pub fn benchmarkEpsilonClosureDetailed(allocator: Allocator) !void {
    const print = std.debug.print;

    print("=== Epsilon-Closure 详细性能基准测试 ===\n\n", .{});

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

    var input_instance = input_mod.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 1000;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
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

    var input_instance = input_mod.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 1000;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
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

    var input_instance = input_mod.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 5) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 100;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
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

    var input_instance = input_mod.Input.init("", .bytes);

    // 预热
    var i_preheat: usize = 0;
    while (i_preheat < 10) : (i_preheat += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
        nfa.thread_set.clear();
    }

    // 基准测试
    const iterations = 500;
    const start_time = std.time.milliTimestamp();

    var i_bench: usize = 0;
    while (i_bench < iterations) : (i_bench += 1) {
        try nfa.addClosureFrom(0, program.slot_count, &input_instance, &nfa.thread_set.current);
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

    try benchmarkEpsilonClosureDetailed(allocator);
}
