const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;

test "debug original failing test" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Debug Original Failing Test ===\n", .{});

    var r = try Regex.compile(allocator, "ab(\\d+)");
    defer r.deinit();

    debug.print("Pattern: ab(\\d+)\n", .{});
    debug.print("slot_count: {}\n", .{r.compiled.slot_count});

    debug.assert(try r.partialMatch("xxxxab0123a"));

    var caps = (try r.captures("xxxxab0123a")).?;
    defer caps.deinit();

    debug.print("Slots length: {}\n", .{caps.slots.len});
    for (caps.slots, 0..) |slot, i| {
        debug.print("Slot {}: {?}\n", .{i, slot});
    }

    // Check bounds before slicing
    if (caps.boundsAt(0)) |bound| {
        debug.print("Bounds 0: {} to {} (valid: {})\n", .{bound.lower, bound.upper, bound.lower <= bound.upper});
    }
    if (caps.boundsAt(1)) |bound| {
        debug.print("Bounds 1: {} to {} (valid: {})\n", .{bound.lower, bound.upper, bound.lower <= bound.upper});
    }

    // This will panic if bounds are invalid
    const capture0 = caps.sliceAt(0) orelse "null";
    const capture1 = caps.sliceAt(1) orelse "null";

    debug.print("Capture 0: '{s}'\n", .{capture0});
    debug.print("Capture 1: '{s}'\n", .{capture1});
}