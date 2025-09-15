const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const mem = std.mem;

test "comprehensive capture group validation" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Comprehensive Capture Group Validation ===\n", .{});

    const test_cases = [_]struct {
        pattern: []const u8,
        input: []const u8,
        expected_whole: []const u8,
        expected_groups: []const []const u8,
    }{
        .{
            .pattern = "ab(\\d+)",
            .input = "xxxxab0123a",
            .expected_whole = "ab0123",
            .expected_groups = &.{"0123"},
        },
        .{
            .pattern = "(\\w+):(\\d+)",
            .input = "user:123",
            .expected_whole = "user:123",
            .expected_groups = &.{"user", "123"},
        },
        .{
            .pattern = "a((\\d+)b)",
            .input = "a123b",
            .expected_whole = "a123b",
            .expected_groups = &.{"123b", "123"},
        },
        .{
            .pattern = "(\\d+)",
            .input = "test123",
            .expected_whole = "123",
            .expected_groups = &.{"123"},
        },
    };

    for (test_cases, 0..) |test_case, i| {
        debug.print("\n--- Test Case {} ---\n", .{i + 1});
        debug.print("Pattern: '{s}'\n", .{test_case.pattern});
        debug.print("Input: '{s}'\n", .{test_case.input});
        debug.print("Expected whole: '{s}'\n", .{test_case.expected_whole});

        var re = try Regex.compile(allocator, test_case.pattern);
        defer re.deinit();

        var caps = (try re.captures(test_case.input)).?;
        defer caps.deinit();

        const whole_match = caps.sliceAt(0) orelse "null";
        debug.print("Actual whole: '{s}'\n", .{whole_match});

        // Test whole match
        if (mem.eql(u8, test_case.expected_whole, whole_match)) {
            debug.print("✅ Whole match CORRECT\n", .{});
        } else {
            debug.print("❌ Whole match INCORRECT\n", .{});
        }

        // Test groups
        for (test_case.expected_groups, 0..) |expected_group, group_idx| {
            const actual_group = caps.sliceAt(group_idx + 1) orelse "null";
            debug.print("Expected group {}: '{s}'\n", .{group_idx + 1, expected_group});
            debug.print("Actual group {}: '{s}'\n", .{group_idx + 1, actual_group});

            if (mem.eql(u8, expected_group, actual_group)) {
                debug.print("✅ Group {} CORRECT\n", .{group_idx + 1});
            } else {
                debug.print("❌ Group {} INCORRECT\n", .{group_idx + 1});
            }
        }
    }

    debug.print("\n=== Validation completed ===\n", .{});
}