// Literal extractor for fast path optimization
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const parser = @import("parse.zig");
const Expr = parser.Expr;

// Literal analysis result
pub const LiteralInfo = struct {
    is_literal: bool,
    literal: []const u8,
    case_sensitive: bool = true,

    pub fn deinit(self: *LiteralInfo, allocator: Allocator) void {
        if (self.is_literal and self.literal.len > 0) {
            allocator.free(self.literal);
        }
    }
};

// Analyzer for detecting literal patterns in regex
pub const LiteralAnalyzer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) LiteralAnalyzer {
        return LiteralAnalyzer{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LiteralAnalyzer) void {
        _ = self;
        // No cleanup needed
    }

    // Analyze an expression to determine if it's a simple literal
    pub fn analyze(self: *LiteralAnalyzer, expr: *const Expr) !LiteralInfo {
        return self.analyzeInternal(expr, true);
    }

    fn analyzeInternal(self: *LiteralAnalyzer, expr: *const Expr, top_level: bool) !LiteralInfo {
        _ = top_level;
        switch (expr.*) {
            Expr.Literal => |lit| {
                // Simple literal - this is our fast path case
                var literal_copy = try self.allocator.alloc(u8, 1);
                literal_copy[0] = lit;
                return LiteralInfo{
                    .is_literal = true,
                    .literal = literal_copy,
                };
            },

            Expr.Concat => |subexprs| {
                // Check if all sub-expressions are literals
                var total_len: usize = 0;
                var all_literals = true;

                // First pass: check if all are literals and calculate total length
                for (subexprs.items) |subexpr| {
                    var sub_info = try self.analyzeInternal(subexpr, false);
                    defer sub_info.deinit(self.allocator);

                    if (!sub_info.is_literal) {
                        all_literals = false;
                        break;
                    }
                    total_len += sub_info.literal.len;
                }

                if (!all_literals) {
                    return LiteralInfo{ .is_literal = false, .literal = "" };
                }

                // Second pass: concatenate all literals
                var buffer = try self.allocator.alloc(u8, total_len);
                var pos: usize = 0;

                for (subexprs.items) |subexpr| {
                    var sub_info = try self.analyzeInternal(subexpr, false);
                    defer sub_info.deinit(self.allocator);

                    @memcpy(buffer[pos..][0..sub_info.literal.len], sub_info.literal);
                    pos += sub_info.literal.len;
                }

                return LiteralInfo{
                    .is_literal = true,
                    .literal = buffer,
                };
            },

            // For all other expression types, return non-literal
            else => {
                return LiteralInfo{ .is_literal = false, .literal = "" };
            },
        }
    }

    // Direct pattern analysis for simple cases
    pub fn analyzePattern(self: *LiteralAnalyzer, pattern: []const u8) !LiteralInfo {
        // Quick scan for regex metacharacters
        for (pattern) |ch| {
            switch (ch) {
                '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '\\' => {
                    // Contains regex special characters - not a simple literal
                    return LiteralInfo{ .is_literal = false, .literal = "" };
                },
                else => {},
            }
        }

        // No special characters found - this is a simple literal
        const literal_copy = try self.allocator.dupe(u8, pattern);
        return LiteralInfo{
            .is_literal = true,
            .literal = literal_copy,
        };
    }
};

// Fast literal matcher using standard string search
pub const LiteralMatcher = struct {
    literal: []const u8,

    pub fn init(literal: []const u8) LiteralMatcher {
        return LiteralMatcher{
            .literal = literal,
        };
    }

    // Check if literal matches at the given position
    pub fn matchesAt(self: *const LiteralMatcher, input: []const u8, pos: usize) bool {
        if (pos + self.literal.len > input.len) {
            return false;
        }

        for (0..self.literal.len) |i| {
            if (input[pos + i] != self.literal[i]) {
                return false;
            }
        }

        return true;
    }

    // Find first occurrence of literal in input
    pub fn find(self: *const LiteralMatcher, input: []const u8) ?usize {
        if (self.literal.len == 0) {
            return 0;
        }

        if (self.literal.len > input.len) {
            return null;
        }

        // Simple naive search for now - can be optimized with Boyer-Moore later
        for (0..input.len - self.literal.len + 1) |i| {
            if (self.matchesAt(input, i)) {
                return i;
            }
        }

        return null;
    }

    // Check if input contains the literal
    pub fn contains(self: *const LiteralMatcher, input: []const u8) bool {
        return self.find(input) != null;
    }
};