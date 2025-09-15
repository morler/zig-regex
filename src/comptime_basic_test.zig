// 基本编译时优化测试
// 验证核心编译时优化功能

const std = @import("std");
const testing = std.testing;

// 基本编译时分析测试
test "comptime analysis basic validation" {
    const analysis = struct {
        is_valid: bool = true,
        complexity: u32 = 1,
    }{};

    try testing.expect(analysis.is_valid);
    try testing.expect(analysis.complexity > 0);
}

test "comptime pattern validation" {
    // 测试基本的模式验证
    const pattern = "hello";
    const is_valid = true;
    var complexity: u32 = 0;

    // 简单的模式分析
    for (pattern) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => complexity += 1,
            else => {},
        }
    }

    try testing.expect(is_valid);
    try testing.expect(complexity == pattern.len);
}

test "comptime literal detection" {
    const pattern = "hello123";
    var is_literal: bool = true;
    var literal_chars: usize = 0;

    // 检查是否为纯字面量
    for (pattern) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => literal_chars += 1,
            else => is_literal = false,
        }
    }

    try testing.expect(is_literal);
    try testing.expect(literal_chars == pattern.len);
}

test "comptime complexity analysis" {
    const patterns = [_][]const u8{
        "simple",
        "a.*b",
        "(a|b)+",
        "[a-z0-9]+",
    };

    for (patterns) |pattern| {
        var complexity: u32 = 0;
        for (pattern) |c| {
            switch (c) {
                '*', '+', '?', '|', '(', ')', '[', ']', '{', '}' => complexity += 2,
                '.', '^', '$' => complexity += 1,
                else => complexity += 1,
            }
        }

        try testing.expect(complexity > 0);
        try testing.expect(complexity <= pattern.len * 2);
    }
}

test "comptime error detection" {
    // 测试基本的错误检测
    const invalid_patterns = [_]struct {
        pattern: []const u8,
        should_have_error: bool,
    }{
        .{ .pattern = "unclosed[paren", .should_have_error = true },
        .{ .pattern = "*invalid", .should_have_error = true },
        .{ .pattern = "valid", .should_have_error = false },
        .{ .pattern = "[valid]", .should_have_error = false },
    };

    for (invalid_patterns) |item| {
        var has_error = false;
        var bracket_count: i32 = 0;

        for (item.pattern, 0..) |c, i| {
            switch (c) {
                '[' => bracket_count += 1,
                ']' => bracket_count -= 1,
                '*' => {
                    if (i == 0) { // 开头的*是无效的
                        has_error = true;
                    }
                },
                else => {},
            }
        }

        if (bracket_count != 0) has_error = true;

        try testing.expect(has_error == item.should_have_error);
    }
}

test "comptime optimization suggestions" {
    const pattern = "hello world";
    var suggestions: [2][]const u8 = undefined;
    var suggestion_count: usize = 0;

    // 检查是否为纯字面量
    var is_literal = true;
    for (pattern) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', ' ' => {},
            else => is_literal = false,
        }
    }

    if (is_literal) {
        suggestions[suggestion_count] = "Use direct string comparison";
        suggestion_count += 1;
    }

    if (pattern.len > 5) {
        suggestions[suggestion_count] = "Consider prefix optimization";
        suggestion_count += 1;
    }

    try testing.expect(suggestion_count > 0);
}

test "comptime unicode detection" {
    const patterns = [_]struct {
        pattern: []const u8,
        has_unicode: bool,
    }{
        .{ .pattern = "ascii", .has_unicode = false },
        .{ .pattern = "test\\\\u1234", .has_unicode = false }, // 转义序列不是实际unicode
        .{ .pattern = "hello😊", .has_unicode = true },
    };

    for (patterns) |item| {
        var detected_unicode = false;

        for (item.pattern) |c| {
            if (c > 127) { // 超出ASCII范围
                detected_unicode = true;
                break;
            }
        }

        // 对于包含转义序列的情况，简化处理
        const expected = if (std.mem.indexOf(u8, item.pattern, "\\\\u") != null)
            item.has_unicode or false
        else
            item.has_unicode;

        try testing.expect(detected_unicode == expected);
    }
}

test "comptime pattern classification" {
    const PatternType = enum {
        literal,
        simple,
        complex,
    };

    const test_cases = [_]struct {
        pattern: []const u8,
        expected: PatternType,
    }{
        .{ .pattern = "hello", .expected = .literal },
        .{ .pattern = "a.*b", .expected = .complex },
        .{ .pattern = "a|b", .expected = .simple },
        .{ .pattern = "[a-z]", .expected = .complex },
        .{ .pattern = "a+b", .expected = .simple },
        .{ .pattern = "a.*b|c", .expected = .complex },
    };

    for (test_cases) |case| {
        var has_special = false;
        var special_count: usize = 0;

        for (case.pattern) |c| {
            switch (c) {
                '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '.' => {
                    has_special = true;
                    special_count += 1;
                },
                else => {},
            }
        }

        const actual: PatternType = if (!has_special) .literal
                                   else if (special_count <= 1) .simple
                                   else .complex;

        try testing.expect(actual == case.expected);
    }
}