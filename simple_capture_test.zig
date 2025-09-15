const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const re_debug = @import("src/debug.zig");
const mem = std.mem;

test "simple single capture group debug" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Simple Single Capture Group Debug ===\n", .{});

    // Test just one capture group: (\d+)
    {
        debug.print("\n--- Test: (\\d+) ---\n", .{});
        var re = try Regex.compile(allocator, "(\\d+)");
        defer re.deinit();

        debug.print("Pattern: (\\d+)\n", .{});
        debug.print("find_start: {}\n", .{re.compiled.find_start});
        debug.print("start: {}\n", .{re.compiled.start});
        debug.print("slot_count: {}\n", .{re.compiled.slot_count});

        debug.print("\n--- Program Instructions ---\n", .{});
        re_debug.dumpProgram(re.compiled);

        var caps = (try re.captures("test123")).?;
        defer caps.deinit();

        debug.print("Slots length: {}\n", .{caps.slots.len});
        for (caps.slots, 0..) |slot, i| {
            debug.print("Slot {}: {?}\n", .{i, slot});
        }

        const whole = caps.sliceAt(0) orelse "null";
        const group1 = caps.sliceAt(1) orelse "null";

        debug.print("Whole match: '{s}'\n", .{whole});
        debug.print("Group 1: '{s}'\n", .{group1});
    }

    // Test another pattern: user(\d+)
    {
        debug.print("\n--- Test: user(\\d+) ---\n", .{});
        var re = try Regex.compile(allocator, "user(\\d+)");
        defer re.deinit();

        debug.print("Pattern: user(\\d+)\n", .{});
        debug.print("slot_count: {}\n", .{re.compiled.slot_count});

        var caps = (try re.captures("testuser123")).?;
        defer caps.deinit();

        debug.print("Slots length: {}\n", .{caps.slots.len});
        for (caps.slots, 0..) |slot, i| {
            debug.print("Slot {}: {?}\n", .{i, slot});
        }

        const whole = caps.sliceAt(0) orelse "null";
        const group1 = caps.sliceAt(1) orelse "null";

        debug.print("Whole match: '{s}'\n", .{whole});
        debug.print("Group 1: '{s}'\n", .{group1});
    }

    debug.print("\n=== Debug completed ===\n", .{});
}