// Performance monitoring system for regex engine
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const regex = @import("regex.zig");

// Performance metrics
pub const PerformanceMetrics = struct {
    compile_time_ns: i64,
    match_time_ns: i64,
    memory_used_bytes: usize,
    pattern: []const u8,
    input_length: usize,
    match_found: bool,
    timestamp: i64,

    pub fn format(self: PerformanceMetrics, allocator: Allocator) ![]const u8 {
        var buffer = ArrayListUnmanaged(u8).empty;
        defer buffer.deinit(allocator);

        try std.fmt.format(allocator, &buffer,
            \\Performance Metrics:
            \\  Pattern: {s}
            \\  Input Length: {d}
            \\  Compile Time: {d} ns
            \\  Match Time: {d} ns
            \\  Memory Used: {d} bytes
            \\  Match Found: {}
            \\  Timestamp: {d}
            , .{
            self.pattern, self.input_length, self.compile_time_ns,
            self.match_time_ns, self.memory_used_bytes, self.match_found, self.timestamp
        });

        return buffer.toOwnedSlice(allocator);
    }
};

// Performance test case
pub const PerformanceTestCase = struct {
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    expected_match: bool,
    iterations: usize = 1000,

    pub fn run(self: *const PerformanceTestCase, allocator: Allocator) !PerformanceMetrics {
        const start_compile = std.time.nanoTimestamp();
        var regex_obj = try regex.Regex.compile(allocator, self.pattern);
        defer regex_obj.deinit();
        const end_compile = std.time.nanoTimestamp();

        const start_match = std.time.nanoTimestamp();
        var matches_found: usize = 0;
        for (0..self.iterations) |_| {
            if (try regex_obj.match(self.input)) {
                matches_found += 1;
            }
        }
        const end_match = std.time.nanoTimestamp();

        return PerformanceMetrics{
            .compile_time_ns = end_compile - start_compile,
            .match_time_ns = end_match - start_match,
            .memory_used_bytes = 0, // TODO: Implement memory tracking
            .pattern = self.pattern,
            .input_length = self.input.len,
            .match_found = matches_found > 0,
            .timestamp = std.time.nanoTimestamp(),
        };
    }
};

// Performance test suite
pub const PerformanceTestSuite = struct {
    allocator: Allocator,
    test_cases: ArrayListUnmanaged(PerformanceTestCase),
    results: ArrayListUnmanaged(PerformanceMetrics),

    pub fn init(allocator: Allocator) PerformanceTestSuite {
        return PerformanceTestSuite{
            .allocator = allocator,
            .test_cases = .empty,
            .results = .empty,
        };
    }

    pub fn deinit(self: *PerformanceTestSuite) void {
        self.test_cases.deinit(self.allocator);
        self.results.deinit(self.allocator);
    }

    pub fn addTestCase(self: *PerformanceTestSuite, test_case: PerformanceTestCase) !void {
        try self.test_cases.append(self.allocator, test_case);
    }

    pub fn runAll(self: *PerformanceTestSuite) !void {
        self.results.clearRetainingCapacity();

        for (self.test_cases.items) |test_case| {
            const result = try test_case.run(self.allocator);
            try self.results.append(self.allocator, result);
        }
    }

    pub fn generateReport(self: *const PerformanceTestSuite) ![]const u8 {
        var buffer = ArrayListUnmanaged(u8).empty;
        defer buffer.deinit(self.allocator);

        try std.fmt.format(allocator, &buffer,
            \\Performance Test Report
            \\=========================
            \\Total Tests: {d}
            \\
            , .{self.results.items.len}
        );

        for (self.results.items, 0..) |result, i| {
            try std.fmt.format(allocator, &buffer,
                \\Test {d}: {s}
                \\--------
                \\{s}
                \\
                , .{ i + 1, self.test_cases.items[i].name, try result.format(self.allocator) }
            );
        }

        return buffer.toOwnedSlice(self.allocator);
    }
};

// Predefined performance test cases
pub fn createStandardPerformanceTests(allocator: Allocator) !PerformanceTestSuite {
    var suite = PerformanceTestSuite.init(allocator);
    errdefer suite.deinit();

    // Literal fast path test
    try suite.addTestCase(PerformanceTestCase{
        .name = "Literal Fast Path",
        .pattern = "hello",
        .input = "hello world, hello everyone, hello universe",
        .expected_match = true,
        .iterations = 1000,
    });

    // Complex pattern test
    try suite.addTestCase(PerformanceTestCase{
        .name = "Complex Pattern",
        .pattern = "h.l+o",
        .input = "hello world, hello everyone, hello universe",
        .expected_match = true,
        .iterations = 1000,
    });

    // Long input test
    try suite.addTestCase(PerformanceTestCase{
        .name = "Long Input",
        .pattern = "quick",
        .input = "The quick brown fox jumps over the lazy dog. " ++
                 "The quick brown fox jumps over the lazy dog. " ++
                 "The quick brown fox jumps over the lazy dog.",
        .expected_match = true,
        .iterations = 100,
    });

    // ASCII fast path test
    try suite.addTestCase(PerformanceTestCase{
        .name = "ASCII Fast Path",
        .pattern = "test",
        .input = "This is a test string with ASCII only characters",
        .expected_match = true,
        .iterations = 1000,
    });

    // No match test
    try suite.addTestCase(PerformanceTestCase{
        .name = "No Match",
        .pattern = "xyz",
        .input = "This string does not contain the pattern",
        .expected_match = false,
        .iterations = 1000,
    });

    return suite;
}

// Performance comparison utility
pub fn comparePerformance(old: PerformanceMetrics, new: PerformanceMetrics) ![]const u8 {
    var buffer = ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(old.allocator);

    const compile_improvement = @as(f64, @floatFromInt(old.compile_time_ns - new.compile_time_ns)) / @as(f64, @floatFromInt(old.compile_time_ns)) * 100.0;
    const match_improvement = @as(f64, @floatFromInt(old.match_time_ns - new.match_time_ns)) / @as(f64, @floatFromInt(old.match_time_ns)) * 100.0;

    try std.fmt.format(old.allocator, &buffer,
        \\Performance Comparison:
        \\=====================
        \\Pattern: {s}
        \\
        \\Compile Time: {d}ns -> {d}ns ({d:.1}% {})
        \\Match Time: {d}ns -> {d}ns ({d:.1}% {})
        \\Memory: {d} bytes -> {d} bytes ({d:.1}% {})
        \\
        , .{
        old.pattern,
        old.compile_time_ns, new.compile_time_ns,
        @abs(compile_improvement), if (compile_improvement > 0) "improvement" else "regression",
        old.match_time_ns, new.match_time_ns,
        @abs(match_improvement), if (match_improvement > 0) "improvement" else "regression",
        old.memory_used_bytes, new.memory_used_bytes,
        @as(f64, @floatFromInt(new.memory_used_bytes - old.memory_used_bytes)) / @as(f64, @floatFromInt(old.memory_used_bytes)) * 100.0
    });

    return buffer.toOwnedSlice(old.allocator);
}