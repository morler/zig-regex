const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const re_debug = @import("src/debug.zig");
const mem = std.mem;

test "debug nfa detailed execution" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Debug NFA Detailed Execution ===\n", .{});

    var re = try Regex.compile(allocator, "ab");
    defer re.deinit();

    debug.print("Pattern: ab\n", .{});
    debug.print("find_start: {}\n", .{re.compiled.find_start});
    debug.print("start: {}\n", .{re.compiled.start});
    debug.print("slot_count: {}\n", .{re.compiled.slot_count});

    debug.print("\n--- Program Instructions ---\n", .{});
    re_debug.dumpProgram(re.compiled);

    // Test basic matching
    const matched = try re.match("xxxxab");
    debug.print("Match result: {}\n", .{matched});

    // Test capture
    var caps = (try re.captures("xxxxab")).?;
    defer caps.deinit();

    debug.print("Capture 0 bounds: {?} to {?}\n", .{caps.slots[0], caps.slots[1]});
}