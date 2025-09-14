const std = @import("std");
const Parser = @import("src/parse.zig").Parser;
const re_debug = @import("src/debug.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // 调试字符类解析
    std.debug.print("=== Debugging character class parsing ===\n", .{});

    var p = Parser.init(allocator);
    defer p.deinit();

    const regex = "[\\+-]";
    std.debug.print("Parsing regex: '{s}'\n", .{regex});

    const expr = p.parse(regex) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return;
    };

    std.debug.print("Expression tree:\n", .{});
    re_debug.dumpExpr(expr.*);

    // 测试字符类包含
    if (expr.* == .ByteClass) {
        const byte_class = expr.ByteClass;
        std.debug.print("\nTesting character class contains:\n", .{});
        std.debug.print("  Contains '+': {}\n", .{byte_class.contains('+')});
        std.debug.print("  Contains '-': {}\n", .{byte_class.contains('-')});
        std.debug.print("  Ranges: ", .{});
        for (byte_class.ranges.items) |range| {
            std.debug.print("[{}-{}] ", .{ range.min, range.max });
        }
        std.debug.print("\n", .{});
    }
}
