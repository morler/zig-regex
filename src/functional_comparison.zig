// Zig vs Rust Regex 功能对比评测套件
// 本文件包含简化的功能测试，用于对比两个正则表达式引擎的功能

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// 导入Zig regex实现
const zig_regex = @import("regex.zig");
const ZigRegex = zig_regex.Regex;

// 测试用例结构
const TestCase = struct {
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    expected_match: bool,
    expected_captures: ?[]const []const u8 = null,
};

// 基础功能测试
const basic_tests = [_]TestCase{
    .{
        .name = "simple_literal",
        .pattern = "hello",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "simple_literal_no_match",
        .pattern = "hello",
        .input = "world only",
        .expected_match = false,
    },
    .{
        .name = "digit_class",
        .pattern = "\\d+",
        .input = "12345",
        .expected_match = true,
    },
    .{
        .name = "word_class",
        .pattern = "\\w+",
        .input = "hello_world123",
        .expected_match = true,
    },
    .{
        .name = "space_class",
        .pattern = "\\s+",
        .input = " \t\n\r",
        .expected_match = true,
    },
    .{
        .name = "negated_digit",
        .pattern = "\\D+",
        .input = "abc",
        .expected_match = true,
    },
    .{
        .name = "character_range",
        .pattern = "[a-z]+",
        .input = "abcdefghijklmnopqrstuvwxyz",
        .expected_match = true,
    },
    .{
        .name = "character_range_mixed",
        .pattern = "[a-zA-Z0-9]+",
        .input = "HelloWorld123",
        .expected_match = true,
    },
    .{
        .name = "quantifier_star",
        .pattern = "a*",
        .input = "aaaa",
        .expected_match = true,
    },
    .{
        .name = "quantifier_plus",
        .pattern = "a+",
        .input = "aaaa",
        .expected_match = true,
    },
    .{
        .name = "quantifier_question",
        .pattern = "a?",
        .input = "a",
        .expected_match = true,
    },
    .{
        .name = "quantifier_range",
        .pattern = "a{2,4}",
        .input = "aaa",
        .expected_match = true,
    },
    .{
        .name = "anchor_start",
        .pattern = "^hello",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "anchor_end",
        .pattern = "world$",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "word_boundary",
        .pattern = "\\bhello\\b",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "alternation",
        .pattern = "cat|dog",
        .input = "cat",
        .expected_match = true,
    },
    .{
        .name = "grouping",
        .pattern = "(hello)+",
        .input = "hellohello",
        .expected_match = true,
    },
};

// 捕获组测试
const capture_tests = [_]TestCase{
    .{
        .name = "simple_capture",
        .pattern = "(\\d+)",
        .input = "abc123def",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "123", "123" },
    },
    .{
        .name = "multiple_captures",
        .pattern = "(\\w+)\\s+(\\d+)",
        .input = "hello 123",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "hello 123", "hello", "123" },
    },
    .{
        .name = "nested_groups",
        .pattern = "((\\w+)\\s+(\\d+))",
        .input = "hello 123",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "hello 123", "hello 123", "hello", "123" },
    },
    .{
        .name = "non_capturing_group",
        .pattern = "(?:hello)\\s+(world)",
        .input = "hello world",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "hello world", "world" },
    },
};

// Unicode测试
const unicode_tests = [_]TestCase{
    .{
        .name = "unicode_basic",
        .pattern = "世界",
        .input = "你好世界",
        .expected_match = true,
    },
    .{
        .name = "unicode_combining",
        .pattern = "café",
        .input = "café",
        .expected_match = true,
    },
    .{
        .name = "unicode_emoji",
        .pattern = "😊",
        .input = "Hello 😊",
        .expected_match = true,
    },
};

// 复杂模式测试
const complex_tests = [_]TestCase{
    .{
        .name = "email_pattern",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "test@example.com",
        .expected_match = true,
    },
    .{
        .name = "ipv4_pattern",
        .pattern = "\\b(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b",
        .input = "192.168.1.1",
        .expected_match = true,
    },
    .{
        .name = "html_tag_pattern",
        .pattern = "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*>(.*?)</\\1>",
        .input = "<div>content</div>",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "<div>content</div>", "div", "content" },
    },
};

// Zig regex测试实现
pub fn runZigBasicTests(allocator: Allocator) !struct { passed: usize, total: usize } {
    std.debug.print("=== Zig Regex 基础功能测试 ===\n", .{});

    var passed: usize = 0;
    const total: usize = basic_tests.len;

    for (basic_tests) |test_case| {
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: 编译失败: {}\n", .{ test_case.name, err });
            continue;
        };
        defer re.deinit();

        const result = re.match(test_case.input) catch |err| {
            std.debug.print("❌ {s}: 执行失败: {}\n", .{ test_case.name, err });
            continue;
        };

        if (result == test_case.expected_match) {
            passed += 1;
            std.debug.print("✅ {s}\n", .{test_case.name});
        } else {
            std.debug.print("❌ {s}: 期望 {}, 实际 {}\n", .{ test_case.name, test_case.expected_match, result });
        }
    }

    std.debug.print("基础功能测试结果: {}/{} ({d:.1}%)\n\n", .{ passed, total, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0 });

    return .{ .passed = passed, .total = total };
}

pub fn runZigCaptureTests(allocator: Allocator) !struct { passed: usize, total: usize } {
    std.debug.print("=== Zig Regex 捕获组测试 ===\n", .{});

    var passed: usize = 0;
    const total: usize = capture_tests.len;

    for (capture_tests) |test_case| {
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: 编译失败: {}\n", .{ test_case.name, err });
            continue;
        };
        defer re.deinit();

        const result = re.captures(test_case.input) catch |err| {
            std.debug.print("❌ {s}: 执行失败: {}\n", .{ test_case.name, err });
            continue;
        };

        if (test_case.expected_captures) |expected| {
            if (result) |captures| {
                var caps = captures;
                defer caps.deinit();

                var capture_passed = true;
                for (expected, 0..) |expected_capture, i| {
                    const actual_capture = caps.sliceAt(i) orelse {
                        std.debug.print("❌ {s}: 捕获组{} 为空\n", .{ test_case.name, i });
                        capture_passed = false;
                        break;
                    };

                    if (!std.mem.eql(u8, expected_capture, actual_capture)) {
                        std.debug.print("❌ {s}: 捕获组{} 不匹配, 期望 '{s}', 实际 '{s}'\n", .{ test_case.name, i, expected_capture, actual_capture });
                        capture_passed = false;
                        break;
                    }
                }

                if (capture_passed) {
                    passed += 1;
                    std.debug.print("✅ {s}\n", .{test_case.name});
                } else {
                    std.debug.print("❌ {s}: 捕获组不匹配\n", .{test_case.name});
                }
            } else {
                std.debug.print("❌ {s}: 未找到匹配\n", .{test_case.name});
            }
        } else {
            // 只检查是否匹配
            if (result != null) {
                passed += 1;
                std.debug.print("✅ {s}\n", .{test_case.name});
            } else {
                std.debug.print("❌ {s}: 未找到匹配\n", .{test_case.name});
            }
        }
    }

    std.debug.print("捕获组测试结果: {}/{} ({d:.1}%)\n\n", .{ passed, total, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0 });

    return .{ .passed = passed, .total = total };
}

pub fn runZigUnicodeTests(allocator: Allocator) !struct { passed: usize, total: usize } {
    std.debug.print("=== Zig Regex Unicode测试 ===\n", .{});

    var passed: usize = 0;
    const total: usize = unicode_tests.len;

    for (unicode_tests) |test_case| {
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: 编译失败: {}\n", .{ test_case.name, err });
            continue;
        };
        defer re.deinit();

        const result = re.match(test_case.input) catch |err| {
            std.debug.print("❌ {s}: 执行失败: {}\n", .{ test_case.name, err });
            continue;
        };

        if (result == test_case.expected_match) {
            passed += 1;
            std.debug.print("✅ {s}\n", .{test_case.name});
        } else {
            std.debug.print("❌ {s}: 期望 {}, 实际 {}\n", .{ test_case.name, test_case.expected_match, result });
        }
    }

    std.debug.print("Unicode测试结果: {}/{} ({d:.1}%)\n\n", .{ passed, total, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0 });

    return .{ .passed = passed, .total = total };
}

pub fn runZigComplexTests(allocator: Allocator) !struct { passed: usize, total: usize } {
    std.debug.print("=== Zig Regex 复杂模式测试 ===\n", .{});

    var passed: usize = 0;
    const total: usize = complex_tests.len;

    for (complex_tests) |test_case| {
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: 编译失败: {}\n", .{ test_case.name, err });
            continue;
        };
        defer re.deinit();

        const result = re.match(test_case.input) catch |err| {
            std.debug.print("❌ {s}: 执行失败: {}\n", .{ test_case.name, err });
            continue;
        };

        if (result == test_case.expected_match) {
            passed += 1;
            std.debug.print("✅ {s}\n", .{test_case.name});
        } else {
            std.debug.print("❌ {s}: 期望 {}, 实际 {}\n", .{ test_case.name, test_case.expected_match, result });
        }
    }

    std.debug.print("复杂模式测试结果: {}/{} ({d:.1}%)\n\n", .{ passed, total, @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0 });

    return .{ .passed = passed, .total = total };
}

// 运行所有Zig功能测试
pub fn runAllZigFunctionalTests(allocator: Allocator) !void {
    std.debug.print("开始 Zig Regex 功能对比评测\n\n", .{});

    const basic_result = try runZigBasicTests(allocator);
    const capture_result = try runZigCaptureTests(allocator);
    const unicode_result = try runZigUnicodeTests(allocator);
    const complex_result = try runZigComplexTests(allocator);

    const total_passed = basic_result.passed + capture_result.passed + unicode_result.passed + complex_result.passed;
    const total_tests = basic_result.total + capture_result.total + unicode_result.total + complex_result.total;

    std.debug.print(
        \\=== Zig Regex 总体功能测试结果 ===
        \\基础功能: {}/{} ({d:.1}%)
        \\捕获组: {}/{} ({d:.1}%)
        \\Unicode: {}/{} ({d:.1}%)
        \\复杂模式: {}/{} ({d:.1}%)
        \\
        \\总计: {}/{} ({d:.1}%)
        \\
    , .{
        basic_result.passed,                                                                                    basic_result.total,
        @as(f64, @floatFromInt(basic_result.passed)) / @as(f64, @floatFromInt(basic_result.total)) * 100.0,     capture_result.passed,
        capture_result.total,                                                                                   @as(f64, @floatFromInt(capture_result.passed)) / @as(f64, @floatFromInt(capture_result.total)) * 100.0,
        unicode_result.passed,                                                                                  unicode_result.total,
        @as(f64, @floatFromInt(unicode_result.passed)) / @as(f64, @floatFromInt(unicode_result.total)) * 100.0, complex_result.passed,
        complex_result.total,                                                                                   @as(f64, @floatFromInt(complex_result.passed)) / @as(f64, @floatFromInt(complex_result.total)) * 100.0,
        total_passed,                                                                                           total_tests,
        @as(f64, @floatFromInt(total_passed)) / @as(f64, @floatFromInt(total_tests)) * 100.0,
    });
}

test "run functional comparison test suite" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try runAllZigFunctionalTests(gpa.allocator());
}
