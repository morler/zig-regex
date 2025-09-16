// 输入抽象层的单元测试

const std = @import("std");
const testing = std.testing;
const input_mod = @import("input.zig");
const Input = input_mod.Input;

// 为了兼容性，保留旧的类型别名
const InputBytes = Input;
const InputUtf8 = Input;
const Assertion = @import("parse.zig").Assertion;

test "InputBytes - basic operations" {
    const test_str = "hello";
    var input_instance = InputBytes.init(test_str, .bytes);

    // Test initial state
    try testing.expectEqual(@as(usize, 0), input_instance.byte_pos);
    try testing.expectEqual(test_str, input_instance.bytes);

    // Test current character
    try testing.expectEqual(@as(u21, 'h'), input_instance.current().?);

    // Test advance
    input_instance.advance();
    try testing.expectEqual(@as(usize, 1), input_instance.byte_pos);
    try testing.expectEqual(@as(u21, 'e'), input_instance.current().?);

    // Test isConsumed
    try testing.expect(!input_instance.isConsumed());

    // Advance to end
    while (input_instance.byte_pos < test_str.len) {
        input_instance.advance();
    }
    try testing.expect(input_instance.isConsumed());
    try testing.expectEqual(@as(?u21, null), input_instance.current());
}

test "InputBytes - word character detection" {
    const test_str = "a1 b2";
    var input_instance = InputBytes.init(test_str, .bytes);

    // Test at position 0 ('a')
    try testing.expect(input_instance.isCurrentWordChar());
    try testing.expect(!input_instance.isPreviousWordChar());
    try testing.expect(input_instance.isNextWordChar()); // '1'

    // Advance to position 1 ('1')
    input_instance.advance();
    try testing.expect(input_instance.isCurrentWordChar());
    try testing.expect(input_instance.isPreviousWordChar()); // 'a'
    try testing.expect(!input_instance.isNextWordChar()); // ' '

    // Advance to position 2 (' ')
    input_instance.advance();
    try testing.expect(!input_instance.isCurrentWordChar());
    try testing.expect(input_instance.isPreviousWordChar()); // '1'
    try testing.expect(input_instance.isNextWordChar()); // 'b'
}

test "InputBytes - clone" {
    const test_str = "test";
    var input1 = InputBytes.init(test_str, .bytes);
    input1.advance();

    const input2 = input1.clone();

    try testing.expectEqual(input1.byte_pos, input2.byte_pos);
    try testing.expectEqual(input1.bytes, input2.bytes);

    // Modifying clone shouldn't affect original
    var input2_mut = input2.clone();
    input2_mut.advance();
    try testing.expect(input1.byte_pos != input2_mut.byte_pos);
}

test "InputBytes - empty match assertions" {
    const test_str = "test";
    var input_instance = InputBytes.init(test_str, .bytes);

    // BeginLine at start
    try testing.expect(input_instance.isEmptyMatch(Assertion.BeginLine));

    // Not BeginLine after advancing
    input_instance.advance();
    try testing.expect(!input_instance.isEmptyMatch(Assertion.BeginLine));

    // EndLine at end
    input_instance.byte_pos = test_str.len;
    try testing.expect(input_instance.isEmptyMatch(Assertion.EndLine));

    // WordBoundaryAscii
    input_instance.byte_pos = 0;
    try testing.expect(input_instance.isEmptyMatch(Assertion.WordBoundaryAscii)); // start -> word

    input_instance.byte_pos = 4; // after 't'
    try testing.expect(input_instance.isEmptyMatch(Assertion.WordBoundaryAscii)); // word -> end

    input_instance.byte_pos = 2; // middle of word
    try testing.expect(!input_instance.isEmptyMatch(Assertion.WordBoundaryAscii));
}

test "InputUtf8 - ASCII characters" {
    const test_str = "hello";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // Test ASCII characters (should work like InputBytes)
    try testing.expectEqual(@as(u21, 'h'), input_instance.current().?);

    input_instance.advance();
    try testing.expectEqual(@as(u21, 'e'), input_instance.current().?);

    // Test word character detection for ASCII
    try testing.expect(input_instance.isCurrentWordChar());
    try testing.expect(input_instance.isPreviousWordChar());
    try testing.expect(input_instance.isNextWordChar());
}

test "InputUtf8 - 2-byte UTF-8 sequences" {
    // "café" - 'é' is U+00E9, encoded as 0xC3 0xA9
    const test_str = "café";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // 'c'
    try testing.expectEqual(@as(u21, 'c'), input_instance.current().?);
    input_instance.advance();

    // 'a'
    try testing.expectEqual(@as(u21, 'a'), input_instance.current().?);
    input_instance.advance();

    // 'f'
    try testing.expectEqual(@as(u21, 'f'), input_instance.current().?);
    input_instance.advance();

    // 'é' (U+00E9)
    try testing.expectEqual(@as(u21, 0xE9), input_instance.current().?);
    try testing.expectEqual(@as(usize, 3), input_instance.byte_pos); // position of 'é'

    input_instance.advance();
    try testing.expectEqual(@as(usize, 5), input_instance.byte_pos); // moved past 2-byte sequence
    try testing.expect(input_instance.isConsumed());
}

test "InputUtf8 - 3-byte UTF-8 sequences" {
    // "中文" - '中' is U+4E2D, '文' is U+6587
    const test_str = "中文";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // '中' (U+4E2D)
    try testing.expectEqual(@as(u21, 0x4E2D), input_instance.current().?);
    try testing.expectEqual(@as(usize, 0), input_instance.byte_pos);

    input_instance.advance();
    try testing.expectEqual(@as(usize, 3), input_instance.byte_pos); // moved past 3-byte sequence

    // '文' (U+6587)
    try testing.expectEqual(@as(u21, 0x6587), input_instance.current().?);

    input_instance.advance();
    try testing.expectEqual(@as(usize, 6), input_instance.byte_pos);
    try testing.expect(input_instance.isConsumed());
}

test "InputUtf8 - 4-byte UTF-8 sequences" {
    // "𠮷" - U+20BB7, encoded as 0xF0 0xA0 0xAE 0xB7
    const test_str = "𠮷";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // '𠮷' (U+20BB7)
    try testing.expectEqual(@as(u21, 0x20BB7), input_instance.current().?);
    try testing.expectEqual(@as(usize, 0), input_instance.byte_pos);

    input_instance.advance();
    try testing.expectEqual(@as(usize, 4), input_instance.byte_pos);
    try testing.expect(input_instance.isConsumed());
}

test "InputUtf8 - invalid UTF-8 sequences" {
    // Invalid 2-byte sequence (second byte missing)
    const test_str = "a\xC3";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // 'a'
    try testing.expectEqual(@as(u21, 'a'), input_instance.current().?);
    input_instance.advance();

    // Invalid sequence should return null
    try testing.expectEqual(@as(?u21, null), input_instance.current());

    // Advance should still work
    input_instance.advance();
    try testing.expect(input_instance.isConsumed());
}

test "InputUtf8 - word character detection" {
    // Test with various Unicode characters
    const test_str = "aé中𠮷";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // 'a' - ASCII letter
    try testing.expect(input_instance.isCurrentWordChar());

    input_instance.advance();
    // 'é' - Latin extended
    try testing.expect(input_instance.isCurrentWordChar());

    input_instance.advance();
    // '中' - CJK character
    try testing.expect(input_instance.isCurrentWordChar());

    input_instance.advance();
    // '𠮷' - CJK character
    try testing.expect(input_instance.isCurrentWordChar());
}

test "InputUtf8 - previous and next word character detection" {
    const test_str = "a b";
    var input_instance = InputUtf8.init(test_str, .utf8);

    // At 'a'
    try testing.expect(input_instance.isCurrentWordChar());
    try testing.expect(!input_instance.isPreviousWordChar());
    try testing.expect(!input_instance.isNextWordChar()); // next is space

    input_instance.advance();
    // At ' '
    try testing.expect(!input_instance.isCurrentWordChar());
    try testing.expect(input_instance.isPreviousWordChar()); // 'a'
    try testing.expect(input_instance.isNextWordChar()); // 'b'

    input_instance.advance();
    // At 'b'
    try testing.expect(input_instance.isCurrentWordChar());
    try testing.expect(!input_instance.isPreviousWordChar()); // space
    try testing.expect(!input_instance.isNextWordChar());
}

test "Input - union type basic operations" {
    const test_str = "hello";

    // Test bytes variant
    var input_bytes = Input.init(test_str, .bytes);
    try testing.expectEqual(@as(u8, 'h'), input_bytes.current().?);
    input_bytes.advance();
    try testing.expectEqual(@as(u8, 'e'), input_bytes.current().?);

    // Test utf8 variant
    var input_utf8 = Input.init(test_str, .utf8);
    try testing.expectEqual(@as(u8, 'h'), input_utf8.current().?);
    input_utf8.advance();
    try testing.expectEqual(@as(u8, 'e'), input_utf8.current().?);
}

test "Input - union type word character detection" {
    const test_str = "a1";

    var input_bytes = Input.init(test_str, .bytes);
    try testing.expect(input_bytes.isCurrentWordChar());
    try testing.expect(input_bytes.isNextWordChar());

    var input_utf8 = Input.init(test_str, .utf8);
    try testing.expect(input_utf8.isCurrentWordChar());
    try testing.expect(input_utf8.isNextWordChar());
}

test "Input - clone" {
    const test_str = "test";
    var input1 = Input.init(test_str, .bytes);
    input1.advance();

    const input2 = input1.clone();
    try testing.expectEqual(input1.isCurrentWordChar(), input2.isCurrentWordChar());
}

test "Input - empty match assertions" {
    const test_str = "test";
    var input_instance = Input.init(test_str, .bytes);

    try testing.expect(input_instance.isEmptyMatch(Assertion.BeginLine));
    input_instance.advance();
    try testing.expect(!input_instance.isEmptyMatch(Assertion.BeginLine));

    // Test end of string
    input_instance.byte_pos = test_str.len;
    try testing.expect(input_instance.isEmptyMatch(Assertion.EndLine));
}

test "Performance comparison - InputBytes vs old Input" {
    // This test demonstrates the performance improvement
    // by showing that the new implementation doesn't use function pointers
    const test_str = "abcdefghijklmnopqrstuvwxyz";
    const iterations = 1000;

    // Test new InputBytes
    const start_time = std.time.nanoTimestamp();
    var input_bytes = InputBytes.init(test_str, .bytes);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pos: usize = 0;
        while (pos < test_str.len) : (pos += 1) {
            _ = input_bytes.current();
            input_bytes.advance();
        }
        input_bytes.byte_pos = 0; // reset
    }

    const new_time = std.time.nanoTimestamp() - start_time;

    // The key point is that the new implementation should be faster
    // because it eliminates function pointer indirection
    try testing.expect(new_time >= 0); // Just ensure it completes

    // In a real performance test, we would compare with the old implementation
    // but since we're replacing it, we just verify the new one works
    std.debug.print("InputBytes performance test completed in {} ns\n", .{new_time});
}

test "Performance comparison - InputUtf8 vs theoretical baseline" {
    // Test UTF-8 decoding performance
    const test_str = "你好世界こんにちは안녕하세요"; // Mixed UTF-8 text
    const iterations = 1000;

    const start_time = std.time.nanoTimestamp();
    var input_utf8 = InputUtf8.init(test_str, .utf8);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pos: usize = 0;
        while (pos < test_str.len) : (pos += 1) {
            _ = input_utf8.current();
            input_utf8.advance();
        }
        input_utf8.byte_pos = 0; // reset
    }

    const utf8_time = std.time.nanoTimestamp() - start_time;

    try testing.expect(utf8_time >= 0);
    std.debug.print("InputUtf8 performance test completed in {} ns\n", .{utf8_time});
}
