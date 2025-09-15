const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const mem = std.mem;

test "capture group debug analysis" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Capture Group Debug Analysis ===\n", .{});

    // Test 1: Debug the failing case
    {
        debug.print("\n--- Debug Test: Multiple capture groups ---\n", .{});
        var re = try Regex.compile(allocator, "(\\w+):(\\d+)");
        defer re.deinit();

        debug.print("Pattern: (\\w+):(\\d+)\n", .{});
        debug.print("slot_count: {}\n", .{re.compiled.slot_count});

        var caps = (try re.captures("user:123")).?;
        defer caps.deinit();

        debug.print("Total captures: {}\n", .{caps.len()});
        debug.print("Slots length: {}\n", .{caps.slots.len});

        // Debug slot contents
        for (caps.slots, 0..) |slot, i| {
            debug.print("Slot {}: {?}\n", .{i, slot});
        }

        const capture0 = caps.sliceAt(0) orelse "null";
        const capture1 = caps.sliceAt(1) orelse "null";
        const capture2 = caps.sliceAt(2) orelse "null";

        debug.print("Capture 0 (whole match): '{s}'\n", .{capture0});
        debug.print("Capture 1 (group 1): '{s}'\n", .{capture1});
        debug.print("Capture 2 (group 2): '{s}'\n", .{capture2});

        // Check bounds
        if (caps.boundsAt(0)) |bound| {
            debug.print("Bounds 0: {} to {}\n", .{bound.lower, bound.upper});
        }
        if (caps.boundsAt(1)) |bound| {
            debug.print("Bounds 1: {} to {}\n", .{bound.lower, bound.upper});
        }
        if (caps.boundsAt(2)) |bound| {
            debug.print("Bounds 2: {} to {}\n", .{bound.lower, bound.upper});
        }
    }

    // Test 2: Compare with basic case
    {
        debug.print("\n--- Compare with Basic Case ---\n", .{});
        var re = try Regex.compile(allocator, "ab(\\d+)");
        defer re.deinit();

        debug.print("Pattern: ab(\\d+)\n", .{});
        debug.print("slot_count: {}\n", .{re.compiled.slot_count});

        var caps = (try re.captures("xxxxab0123a")).?;
        defer caps.deinit();

        debug.print("Total captures: {}\n", .{caps.len()});
        debug.print("Slots length: {}\n", .{caps.slots.len});

        // Debug slot contents
        for (caps.slots, 0..) |slot, i| {
            debug.print("Slot {}: {?}\n", .{i, slot});
        }

        const capture0 = caps.sliceAt(0) orelse "null";
        const capture1 = caps.sliceAt(1) orelse "null";

        debug.print("Capture 0 (whole match): '{s}'\n", .{capture0});
        debug.print("Capture 1 (group 1): '{s}'\n", .{capture1});

        // Check bounds
        if (caps.boundsAt(0)) |bound| {
            debug.print("Bounds 0: {} to {}\n", .{bound.lower, bound.upper});
        }
        if (caps.boundsAt(1)) |bound| {
            debug.print("Bounds 1: {} to {}\n", .{bound.lower, bound.upper});
        }
    }

    debug.print("\n=== Debug analysis completed ===\n", .{});
}