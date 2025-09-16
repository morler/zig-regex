// Zig vs Rust Regex 全面对比评测套件
// 本文件包含标准化的测试用例，用于对比两个正则表达式引擎的功能和性能

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const time = std.time;

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

// 测试结果结构
const TestResult = struct {
    test_case: *const TestCase,
    zig_matched: bool,
    zig_captures: ?[]const ?[]const u8,
    rust_matched: bool,
    rust_captures: ?[]const ?[]const u8,
    zig_error: ?[]const u8,
    rust_error: ?[]const u8,
    execution_time_zig_ns: i64,
    execution_time_rust_ns: i64,
};

// 性能测试用例结构
const PerfTestCase = struct {
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
};

// 测试类别枚举
const TestCategory = enum {
    basic_syntax,
    character_classes,
    anchors_boundaries,
    quantifiers,
    groups_captures,
    unicode,
    assertions,
    advanced_features,
    edge_cases,
};

// 基础语法测试
const basic_syntax_tests = [_]TestCase{
    .{
        .name = "literal_match",
        .pattern = "hello",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "literal_no_match",
        .pattern = "hello",
        .input = "world hello",
        .expected_match = true,
    },
    .{
        .name = "dot_matches_char",
        .pattern = "h.llo",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "alternation_simple",
        .pattern = "cat|dog",
        .input = "I have a cat",
        .expected_match = true,
    },
    .{
        .name = "concatenation",
        .pattern = "hello.world",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "question_mark_optional",
        .pattern = "colou?r",
        .input = "color",
        .expected_match = true,
    },
    .{
        .name = "question_mark_present",
        .pattern = "colou?r",
        .input = "colour",
        .expected_match = true,
    },
    .{
        .name = "plus_one_or_more",
        .pattern = "ab+",
        .input = "abb",
        .expected_match = true,
    },
    .{
        .name = "star_zero_or_more",
        .pattern = "ab*c",
        .input = "ac",
        .expected_match = true,
    },
    .{
        .name = "star_multiple",
        .pattern = "ab*c",
        .input = "abbbc",
        .expected_match = true,
    },
};

// 字符类测试
const character_class_tests = [_]TestCase{
    .{
        .name = "simple_class",
        .pattern = "[abc]",
        .input = "a",
        .expected_match = true,
    },
    .{
        .name = "range_class",
        .pattern = "[a-z]",
        .input = "m",
        .expected_match = true,
    },
    .{
        .name = "negated_class",
        .pattern = "[^0-9]",
        .input = "a",
        .expected_match = true,
    },
    .{
        .name = "mixed_range",
        .pattern = "[a-zA-Z0-9]",
        .input = "A",
        .expected_match = true,
    },
    .{
        .name = "digit_class",
        .pattern = "\\d",
        .input = "7",
        .expected_match = true,
    },
    .{
        .name = "word_class",
        .pattern = "\\w",
        .input = "_",
        .expected_match = true,
    },
    .{
        .name = "space_class",
        .pattern = "\\s",
        .input = " ",
        .expected_match = true,
    },
};

// 锚点和边界测试
const anchor_tests = [_]TestCase{
    .{
        .name = "start_anchor",
        .pattern = "^hello",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "end_anchor",
        .pattern = "world$",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "both_anchors",
        .pattern = "^hello world$",
        .input = "hello world",
        .expected_match = true,
    },
    .{
        .name = "word_boundary",
        .pattern = "\\bword\\b",
        .input = "word boundary",
        .expected_match = true,
    },
    .{
        .name = "non_word_boundary",
        .pattern = "\\Bw\\B",
        .input = "aword",
        .expected_match = true,
    },
};

// 量词测试
const quantifier_tests = [_]TestCase{
    .{
        .name = "exact_count",
        .pattern = "a{3}",
        .input = "aaa",
        .expected_match = true,
    },
    .{
        .name = "range_min",
        .pattern = "a{2,}",
        .input = "aaa",
        .expected_match = true,
    },
    .{
        .name = "range_both",
        .pattern = "a{2,4}",
        .input = "aaa",
        .expected_match = true,
    },
    .{
        .name = "lazy_quantifier",
        .pattern = "a+?",
        .input = "aaa",
        .expected_match = true,
    },
};

// 捕获组测试
const group_tests = [_]TestCase{
    .{
        .name = "simple_capture",
        .pattern = "(hello)",
        .input = "hello",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "hello", "hello" },
    },
    .{
        .name = "multiple_captures",
        .pattern = "(\\d{4})-(\\d{2})-(\\d{2})",
        .input = "2023-12-25",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "2023-12-25", "2023", "12", "25" },
    },
    .{
        .name = "named_group_pattern",
        .pattern = "(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})",
        .input = "2023-12-25",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "2023-12-25", "2023", "12", "25" },
    },
    .{
        .name = "non_capture_group",
        .pattern = "(?:hello)",
        .input = "hello",
        .expected_match = true,
    },
};

// Unicode测试
const unicode_tests = [_]TestCase{
    .{
        .name = "unicode_basic",
        .pattern = "héllo",
        .input = "héllo world",
        .expected_match = true,
    },
    .{
        .name = "unicode_chinese",
        .pattern = "世界",
        .input = "你好世界",
        .expected_match = true,
    },
    .{
        .name = "unicode_japanese",
        .pattern = "こんにちは",
        .input = "こんにちは世界",
        .expected_match = true,
    },
    .{
        .name = "unicode_emoji",
        .pattern = "😊",
        .input = "Hello 😊",
        .expected_match = true,
    },
    .{
        .name = "unicode_property",
        .pattern = "\\p{L}",
        .input = "A",
        .expected_match = true,
    },
};

// 断言测试
const assertion_tests = [_]TestCase{
    .{
        .name = "lookahead_positive",
        .pattern = "a(?=b)",
        .input = "ab",
        .expected_match = true,
    },
    .{
        .name = "lookahead_negative",
        .pattern = "a(?!b)",
        .input = "ac",
        .expected_match = true,
    },
};

// 高级特性测试
const advanced_tests = [_]TestCase{
    .{
        .name = "flags_ignore_case",
        .pattern = "(?i)HELLO",
        .input = "hello",
        .expected_match = true,
    },
    .{
        .name = "flags_multiline",
        .pattern = "(?m)^hello",
        .input = "hello\nworld",
        .expected_match = true,
    },
    .{
        .name = "flags_dotall",
        .pattern = "(?s)a.b",
        .input = "a\nb",
        .expected_match = true,
    },
};

// 边缘情况测试
const edge_case_tests = [_]TestCase{
    .{
        .name = "empty_string",
        .pattern = "",
        .input = "",
        .expected_match = true,
    },
    .{
        .name = "empty_pattern",
        .pattern = "",
        .input = "abc",
        .expected_match = true,
    },
    .{
        .name = "long_input",
        .pattern = "end",
        .input = "This is a very long string that ends with end",
        .expected_match = true,
    },
    .{
        .name = "nested_groups",
        .pattern = "((a)b)",
        .input = "ab",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "ab", "ab", "a" },
    },
    .{
        .name = "complex_pattern",
        .pattern = "^\\s*(\\d+)\\s+(\\w+)\\s*$",
        .input = "   123   word   ",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "   123   word   ", "123", "word" },
    },
};

// 性能测试用例
const perf_tests = [_]PerfTestCase{
    .{
        .name = "simple_match_short",
        .pattern = "hello",
        .input = "hello world hello world hello world hello world hello world",
        .iterations = 10000,
    },
    .{
        .name = "simple_match_long",
        .pattern = "hello",
        .input = "x" ++ ("x" ** 10000) ++ "hello",
        .iterations = 1000,
    },
    .{
        .name = "complex_pattern_short",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "test@example.com test2@example.org test3@example.net",
        .iterations = 5000,
    },
    .{
        .name = "complex_pattern_long",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "x" ++ ("x" ** 5000) ++ "test@example.com",
        .iterations = 1000,
    },
    .{
        .name = "unicode_match",
        .pattern = "世界",
        .input = "你好世界你好世界你好世界你好世界你好世界",
        .iterations = 5000,
    },
    .{
        .name = "backtracking_pattern",
        .pattern = "(a+)+",
        .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .iterations = 1000,
    },
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
        .input = "world hello",
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
        .name = "negated_word",
        .pattern = "\\W+",
        .input = "!@#$%",
        .expected_match = true,
    },
    .{
        .name = "negated_space",
        .pattern = "\\S+",
        .input = "hello",
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
        .name = "negated_character_class",
        .pattern = "[^0-9]+",
        .input = "abc",
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
        .name = "non_word_boundary",
        .pattern = "\\Bhello\\B",
        .input = "ahellohb",
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
    .{
        .name = "unicode_range",
        .pattern = "[\\u4e00-\\u9fff]+",
        .input = "你好世界",
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
    .{
        .name = "quoted_string_pattern",
        .pattern = "\"([^\"]*)\"",
        .input = "\"hello world\"",
        .expected_match = true,
        .expected_captures = &[_][]const u8{ "\"hello world\"", "hello world" },
    },
};

// 性能测试用例
const perf_tests = [_]PerfTestCase{
    .{
        .name = "simple_match_short",
        .pattern = "hello",
        .input = "hello world hello world hello world hello world hello world",
        .iterations = 10000,
    },
    .{
        .name = "simple_match_long",
        .pattern = "hello",
        .input = "x" ++ ("x" ** 10000) ++ "hello",
        .iterations = 1000,
    },
    .{
        .name = "complex_pattern_short",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "test@example.com test2@example.org test3@example.net",
        .iterations = 5000,
    },
    .{
        .name = "complex_pattern_long",
        .pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
        .input = "x" ++ ("x" ** 5000) ++ "test@example.com",
        .iterations = 1000,
    },
    .{
        .name = "unicode_match",
        .pattern = "世界",
        .input = "你好世界你好世界你好世界你好世界你好世界",
        .iterations = 5000,
    },
    .{
        .name = "backtracking_pattern",
        .pattern = "(a+)+",
        .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .iterations = 1000,
    },
};

// Zig regex测试实现
pub fn runZigBasicTests(allocator: Allocator) !void {
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
}

pub fn runZigCaptureTests(allocator: Allocator) !void {
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
}

pub fn runZigUnicodeTests(allocator: Allocator) !void {
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
}

pub fn runZigComplexTests(allocator: Allocator) !void {
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
}

pub fn runZigPerformanceTests(allocator: Allocator) !void {
    std.debug.print("=== Zig Regex 性能测试 ===\n", .{});

    for (perf_tests) |test_case| {
        var re = ZigRegex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: 编译失败: {}\n", .{ test_case.name, err });
            continue;
        };
        defer re.deinit();

        const start = time.nanoTimestamp();

        var matches: usize = 0;
        var i: usize = 0;
        while (i < test_case.iterations) : (i += 1) {
            if (re.match(test_case.input) catch false) {
                matches += 1;
            }
        }

        const end = time.nanoTimestamp();
        const duration = end - start;
        const avg_duration = @divFloor(duration, test_case.iterations);

        std.debug.print("{s}: {} iterations, {} matches, total: {}ns, avg: {}ns\n", .{ test_case.name, test_case.iterations, matches, duration, avg_duration });
    }

    std.debug.print("\n", .{});
}

// 运行所有Zig测试
pub fn runAllZigTests(allocator: Allocator) !void {
    std.debug.print("开始 Zig Regex 完整测试套件\n\n", .{});

    try runZigBasicTests(allocator);
    try runZigCaptureTests(allocator);
    try runZigUnicodeTests(allocator);
    try runZigComplexTests(allocator);
    try runZigPerformanceTests(allocator);
}

test "run comparison test suite" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try runAllZigTests(gpa.allocator());
}
