const std = @import("std");
const parse = @import("src/parse.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = parse.Parser.init(allocator);
    defer parser.deinit();

    // Test the problematic pattern
    const pattern = "[\\+-]";
    std.debug.print("Testing pattern: {s}\n", .{pattern});

    const expr = try parser.parse(pattern);
    defer parser.reset();

    // Print the parsed expression
    switch (expr.*) {
        .ByteClass => |byte_class| {
            std.debug.print("Parsed as ByteClass\n", .{});
            std.debug.print("Ranges:\n", .{});

            // Iterate through ranges
            for (byte_class.ranges.items) |range| {
                std.debug.print("  [{c}-{c}] ({}-{})\n", .{ range.min, range.max, range.min, range.max });
            }
        },
        else => {
            std.debug.print("Not parsed as ByteClass\n", .{});
        },
    }
}
