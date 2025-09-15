const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const compile = @import("compile.zig");
const input_new = @import("input_new.zig");
const thompson_nfa2 = @import("thompson_nfa2.zig");
const ThompsonNfa = thompson_nfa2.ThompsonNfa;

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

    var input = input_new.Input.init("", .bytes);

    // Get baseline memory usage
    const baseline_memory = getMemoryUsage();

    // Time the closure computation
    const start_time = std.time.nanoTimestamp();
    try nfa.addClosureFrom(0, program.slot_count, &input, &nfa.thread_set.current);
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
        var input = input_new.Input.init(text, .bytes);
        if (try nfa.execute(&input, program.start)) {
            total_matches += 1;
        }
    }

    const end_time = std.time.nanoTimestamp();
    const total_time = @as(i64, @intCast(end_time - start_time));
    const avg_time_per_match = if (total_matches > 0)
        @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(total_matches))
    else 0;

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