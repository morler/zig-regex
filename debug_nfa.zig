const std = @import("std");
const Regex = @import("src/regex.zig").Regex;
const debug = std.debug;
const mem = std.mem;

test "debug nfa execution" {
    const allocator = std.testing.allocator;

    debug.print("\n=== Debug NFA Execution ===\n", .{});

    var re = try Regex.compile(allocator, "ab");
    defer re.deinit();

    debug.print("Pattern: ab\n", .{});
    debug.print("find_start: {}\n", .{re.compiled.find_start});
    debug.print("start: {}\n", .{re.compiled.start});

    // Test basic matching
    const matched = try re.match("xxxxab");
    debug.print("Match result: {}\n", .{matched});
}