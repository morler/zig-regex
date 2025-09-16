const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const mem = std.mem;

test "simple input position test" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Simple Input Position Test ===\n", .{});

    var re = try Regex.compile(allocator, "ab");
    defer re.deinit();

    debug.print("Pattern: ab\n", .{});
    debug.print("Testing on: xxxxab\n", .{});

    var caps = (try re.captures("xxxxab")).?;
    defer caps.deinit();

    debug.print("slot_count: {}\n", .{re.compiled.slot_count});
    debug.print("Total captures: {}\n", .{caps.len()});
    debug.print("Slots length: {}\n", .{caps.slots.len});

    // Debug slot contents
    for (caps.slots, 0..) |slot, i| {
        debug.print("Slot {}: {?}\n", .{i, slot});
    }

    const capture0 = caps.sliceAt(0) orelse "null";
    debug.print("Capture 0 (whole match): '{s}'\n", .{capture0});

    if (caps.boundsAt(0)) |bound| {
        debug.print("Bounds 0: {} to {}\n", .{bound.lower, bound.upper});
    }
}