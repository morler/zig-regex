// UTF-8解码器测试

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const utf8 = @import("utf8.zig");

test "Utf8Decoder - decode ASCII characters" {
    const test_str = "Hello World!";

    for (test_str, 0..) |c, i| {
        const result = try utf8.Utf8Decoder.decodeFirst(test_str[i..]);
        try testing.expectEqual(@as(u21, c), result.codepoint);
        try testing.expectEqual(@as(u3, 1), result.byte_len);
    }
}

test "Utf8Decoder - decode 2-byte UTF-8 sequences" {
    // "café" - 'é' is U+00E9, encoded as 0xC3 0xA9
    const test_bytes = [_]u8{ 0xC3, 0xA9 };
    const result = try utf8.Utf8Decoder.decodeFirst(&test_bytes);

    try testing.expectEqual(@as(u21, 0xE9), result.codepoint);
    try testing.expectEqual(@as(u3, 2), result.byte_len);
}

test "Utf8Decoder - decode 3-byte UTF-8 sequences" {
    // "中" - U+4E2D, encoded as 0xE4 0xB8 0xAD
    const test_bytes = [_]u8{ 0xE4, 0xB8, 0xAD };
    const result = try utf8.Utf8Decoder.decodeFirst(&test_bytes);

    try testing.expectEqual(@as(u21, 0x4E2D), result.codepoint);
    try testing.expectEqual(@as(u3, 3), result.byte_len);
}

test "Utf8Decoder - decode 4-byte UTF-8 sequences" {
    // "𠮷" - U+20BB7, encoded as 0xF0 0xA0 0xAE 0xB7
    const test_bytes = [_]u8{ 0xF0, 0xA0, 0xAE, 0xB7 };
    const result = try utf8.Utf8Decoder.decodeFirst(&test_bytes);

    try testing.expectEqual(@as(u21, 0x20BB7), result.codepoint);
    try testing.expectEqual(@as(u3, 4), result.byte_len);
}

test "Utf8Decoder - decode at specific position" {
    const test_str = "a中b𠮷c";

    // Test at position 0 ('a')
    const result1 = try utf8.Utf8Decoder.decodeAt(test_str, 0);
    try testing.expectEqual(@as(u21, 'a'), result1.codepoint);
    try testing.expectEqual(@as(u3, 1), result1.byte_len);

    // Test at position 1 ('中')
    const result2 = try utf8.Utf8Decoder.decodeAt(test_str, 1);
    try testing.expectEqual(@as(u21, 0x4E2D), result2.codepoint);
    try testing.expectEqual(@as(u3, 3), result2.byte_len);

    // Test at position 4 ('b')
    const result3 = try utf8.Utf8Decoder.decodeAt(test_str, 4);
    try testing.expectEqual(@as(u21, 'b'), result3.codepoint);
    try testing.expectEqual(@as(u3, 1), result3.byte_len);

    // Test at position 5 ('𠮷')
    const result4 = try utf8.Utf8Decoder.decodeAt(test_str, 5);
    try testing.expectEqual(@as(u21, 0x20BB7), result4.codepoint);
    try testing.expectEqual(@as(u3, 4), result4.byte_len);
}

test "Utf8Decoder - handle invalid UTF-8 sequences" {
    // Incomplete 2-byte sequence
    const test_bytes1 = [_]u8{ 0xC3 };
    try testing.expectError(error.IncompleteSequence, utf8.Utf8Decoder.decodeFirst(&test_bytes1));

    // Invalid continuation byte
    const test_bytes2 = [_]u8{ 0xC3, 0xFF };
    try testing.expectError(error.UnexpectedContinuationByte, utf8.Utf8Decoder.decodeFirst(&test_bytes2));

    // Overlong encoding (ASCII encoded as 2 bytes)
    const test_bytes3 = [_]u8{ 0xC1, 0x41 }; // 'A' encoded incorrectly
    try testing.expectError(error.UnexpectedContinuationByte, utf8.Utf8Decoder.decodeFirst(&test_bytes3));

    // Invalid codepoint (surrogate pair)
    const test_bytes4 = [_]u8{ 0xED, 0xA0, 0x80 }; // U+D800 (invalid)
    try testing.expectError(error.InvalidCodepoint, utf8.Utf8Decoder.decodeFirst(&test_bytes4));

    // Codepoint beyond Unicode range
    const test_bytes5 = [_]u8{ 0xF4, 0x90, 0x80, 0x80 }; // U+110000 (invalid)
    try testing.expectError(error.InvalidCodepoint, utf8.Utf8Decoder.decodeFirst(&test_bytes5));
}

test "Utf8Decoder - validate UTF-8 strings" {
    // Valid UTF-8 strings
    const valid_strings = [_][]const u8{
        "Hello",
        "café",
        "中文",
        "𠮷",
        "a中b𠮷c",
    };

    for (valid_strings) |str| {
        try testing.expect(utf8.Utf8Decoder.validate(str));
    }

    // Invalid UTF-8 strings
    const invalid_strings = [_][]const u8{
        "\xC3", // Incomplete 2-byte sequence
        "\xC3\xFF", // Invalid continuation byte
        "\xC0\x41", // Overlong encoding
        "\xED\xA0\x80", // Surrogate pair
        "\xF4\x90\x80\x80", // Beyond Unicode range
    };

    for (invalid_strings) |str| {
        try testing.expect(!utf8.Utf8Decoder.validate(str));
    }
}

test "Utf8Decoder - count codepoints" {
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Decoder.countCodepoints("Hello"));
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Decoder.countCodepoints("café"));
    try testing.expectEqual(@as(usize, 2), utf8.Utf8Decoder.countCodepoints("中文"));
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Decoder.countCodepoints("𠮷"));
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Decoder.countCodepoints("a中b𠮷c"));

    // Invalid UTF-8 should count valid characters only
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Decoder.countCodepoints("a\xC3b")); // a + invalid + b
}

test "Utf8Encoder - encode ASCII characters" {
    var buffer: [4]u8 = undefined;

    for ('a'..'z') |c| {
        const encoded = try utf8.Utf8Encoder.encode(@as(u21, @intCast(c)), &buffer);
        try testing.expectEqual(@as(usize, 1), encoded.len);
        try testing.expectEqual(@as(u8, @intCast(c)), encoded[0]);
    }
}

test "Utf8Encoder - encode 2-byte sequences" {
    var buffer: [4]u8 = undefined;

    // 'é' (U+00E9)
    const result1 = try utf8.Utf8Encoder.encode(0xE9, &buffer);
    try testing.expectEqual(@as(usize, 2), result1.len);
    try testing.expectEqual(@as(u8, 0xC3), result1[0]);
    try testing.expectEqual(@as(u8, 0xA9), result1[1]);
}

test "Utf8Encoder - encode 3-byte sequences" {
    var buffer: [4]u8 = undefined;

    // '中' (U+4E2D)
    const result1 = try utf8.Utf8Encoder.encode(0x4E2D, &buffer);
    try testing.expectEqual(@as(usize, 3), result1.len);
    try testing.expectEqual(@as(u8, 0xE4), result1[0]);
    try testing.expectEqual(@as(u8, 0xB8), result1[1]);
    try testing.expectEqual(@as(u8, 0xAD), result1[2]);
}

test "Utf8Encoder - encode 4-byte sequences" {
    var buffer: [4]u8 = undefined;

    // '𠮷' (U+20BB7)
    const result1 = try utf8.Utf8Encoder.encode(0x20BB7, &buffer);
    try testing.expectEqual(@as(usize, 4), result1.len);
    try testing.expectEqual(@as(u8, 0xF0), result1[0]);
    try testing.expectEqual(@as(u8, 0xA0), result1[1]);
    try testing.expectEqual(@as(u8, 0xAE), result1[2]);
    try testing.expectEqual(@as(u8, 0xB7), result1[3]);
}

test "Utf8Encoder - handle invalid codepoints" {
    var buffer: [4]u8 = undefined;

    // Codepoint beyond Unicode range
    try testing.expectError(error.InvalidCodepoint, utf8.Utf8Encoder.encode(0x110000, &buffer));

    // Surrogate pair codepoints
    try testing.expectError(error.InvalidCodepoint, utf8.Utf8Encoder.encode(0xD800, &buffer));
    try testing.expectError(error.InvalidCodepoint, utf8.Utf8Encoder.encode(0xDFFF, &buffer));
}

test "Utf8Encoder - encoded length calculation" {
    try testing.expectEqual(@as(u3, 1), utf8.Utf8Encoder.encodedLength('A'));
    try testing.expectEqual(@as(u3, 1), utf8.Utf8Encoder.encodedLength(0x7F));
    try testing.expectEqual(@as(u3, 2), utf8.Utf8Encoder.encodedLength(0xE9));
    try testing.expectEqual(@as(u3, 3), utf8.Utf8Encoder.encodedLength(0x4E2D));
    try testing.expectEqual(@as(u3, 4), utf8.Utf8Encoder.encodedLength(0x20BB7));
    try testing.expectEqual(@as(u3, 4), utf8.Utf8Encoder.encodedLength(0x10FFFF));
}

test "Utf8Encoder - encode slice" {
    const codepoints = [_]u21{ 'H', 'e', 'l', 'l', 'o', 0x4E2D, 0x6587 };
    var buffer: [20]u8 = undefined;

    const encoded = try utf8.Utf8Encoder.encodeSlice(&codepoints, &buffer);

    // Should encode as "Hello中文"
    try testing.expectEqual(@as(usize, 11), encoded.len);
    try testing.expectEqualSlices(u8, "Hello中文", encoded);
}

test "Utf8Iterator - basic iteration" {
    const test_str = "Hello 世界!";
    var iter = utf8.Utf8Iterator.init(test_str);

    const expected = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', '世', '界', '!' };

    for (expected) |expected_cp| {
        const actual_cp = iter.next().?;
        try testing.expectEqual(expected_cp, actual_cp);
    }

    try testing.expectEqual(null, iter.next());
}

test "Utf8Iterator - peek functionality" {
    const test_str = "ab";
    var iter = utf8.Utf8Iterator.init(test_str);

    try testing.expectEqual(@as(u21, 'a'), iter.peek().?);
    try testing.expectEqual(@as(u21, 'a'), iter.next().?);
    try testing.expectEqual(@as(u21, 'b'), iter.peek().?);
    try testing.expectEqual(@as(u21, 'b'), iter.next().?);
    try testing.expectEqual(null, iter.peek());
    try testing.expectEqual(null, iter.next());
}

test "Utf8Iterator - reset and position" {
    const test_str = "test";
    var iter = utf8.Utf8Iterator.init(test_str);

    // Advance through the string
    _ = iter.next(); // 't'
    _ = iter.next(); // 'e'
    try testing.expectEqual(@as(usize, 2), iter.position());

    // Reset and start over
    iter.reset();
    try testing.expectEqual(@as(usize, 0), iter.position());
    try testing.expectEqual(@as(u21, 't'), iter.next().?);
}

test "Utf8Iterator - handle invalid UTF-8" {
    const test_str = "a\xC3b"; // 'a' + invalid + 'b'
    var iter = utf8.Utf8Iterator.init(test_str);

    try testing.expectEqual(@as(u21, 'a'), iter.next().?);
    try testing.expectEqual(null, iter.next()); // invalid sequence
    try testing.expectEqual(@as(u21, 'b'), iter.next().?);
    try testing.expectEqual(null, iter.next());
}

test "UnicodeClassifier - ASCII character classification" {
    // Letters
    try testing.expect(utf8.UnicodeClassifier.isLetter('a'));
    try testing.expect(utf8.UnicodeClassifier.isLetter('Z'));
    try testing.expect(!utf8.UnicodeClassifier.isLetter('1'));
    try testing.expect(!utf8.UnicodeClassifier.isLetter(' '));

    // Digits
    try testing.expect(utf8.UnicodeClassifier.isDigit('0'));
    try testing.expect(utf8.UnicodeClassifier.isDigit('9'));
    try testing.expect(!utf8.UnicodeClassifier.isDigit('a'));
    try testing.expect(!utf8.UnicodeClassifier.isDigit(' '));

    // Word characters
    try testing.expect(utf8.UnicodeClassifier.isWordChar('a'));
    try testing.expect(utf8.UnicodeClassifier.isWordChar('1'));
    try testing.expect(utf8.UnicodeClassifier.isWordChar('_'));
    try testing.expect(!utf8.UnicodeClassifier.isWordChar(' '));

    // Whitespace
    try testing.expect(utf8.UnicodeClassifier.isWhitespace(' '));
    try testing.expect(utf8.UnicodeClassifier.isWhitespace('\t'));
    try testing.expect(utf8.UnicodeClassifier.isWhitespace('\n'));
    try testing.expect(!utf8.UnicodeClassifier.isWhitespace('a'));

    // Punctuation
    try testing.expect(utf8.UnicodeClassifier.isPunctuation('!'));
    try testing.expect(utf8.UnicodeClassifier.isPunctuation(','));
    try testing.expect(utf8.UnicodeClassifier.isPunctuation('.'));
    try testing.expect(!utf8.UnicodeClassifier.isPunctuation('a'));
}

test "UnicodeClassifier - Unicode character classification" {
    // Unicode letters
    try testing.expect(utf8.UnicodeClassifier.isLetter(0xE9)); // é
    try testing.expect(utf8.UnicodeClassifier.isLetter(0x4E2D)); // 中

    // Unicode digits
    try testing.expect(utf8.UnicodeClassifier.isDigit(0x0660)); // Arabic-Indic digit zero

    // Unicode word characters
    try testing.expect(utf8.UnicodeClassifier.isWordChar(0x4E2D)); // 中

    // Unicode whitespace
    try testing.expect(utf8.UnicodeClassifier.isWhitespace(0x00A0)); // Non-breaking space
    try testing.expect(utf8.UnicodeClassifier.isWhitespace(0x3000)); // Ideographic space
}

test "UnicodeGeneralCategory - ASCII character categories" {
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Lu, utf8.UnicodeClassifier.getCategory('A'));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Ll, utf8.UnicodeClassifier.getCategory('a'));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Nd, utf8.UnicodeClassifier.getCategory('0'));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Zs, utf8.UnicodeClassifier.getCategory(' '));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Pc, utf8.UnicodeClassifier.getCategory('_'));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Po, utf8.UnicodeClassifier.getCategory('!'));
    try testing.expectEqual(utf8.UnicodeGeneralCategory.Cc, utf8.UnicodeClassifier.getCategory('\n'));
}

test "UnicodeCharClass - basic operations" {
    const allocator = testing.allocator;

    var letters = try utf8.UnicodeClasses.letters(allocator);
    defer letters.deinit();

    var digits = try utf8.UnicodeClasses.digits(allocator);
    defer digits.deinit();

    // Test basic contains
    try testing.expect(letters.contains('A'));
    try testing.expect(letters.contains('a'));
    try testing.expect(letters.contains(0x4E2D)); // 中
    try testing.expect(!letters.contains('0'));

    try testing.expect(digits.contains('0'));
    try testing.expect(digits.contains('9'));
    try testing.expect(digits.contains(0x0660)); // Arabic-Indic digit
    try testing.expect(!digits.contains('A'));
}

test "UnicodeCharClass - set operations" {
    const allocator = testing.allocator;

    var letters = try utf8.UnicodeClasses.letters(allocator);
    defer letters.deinit();

    var digits = try utf8.UnicodeClasses.digits(allocator);
    defer digits.deinit();

    // Test union operation
    var union_result = utf8.UnicodeCharClass.init(allocator);
    defer union_result.deinit();
    try letters.setUnion(&digits, &union_result);

    try testing.expect(union_result.contains('A'));
    try testing.expect(union_result.contains('0'));

    // Test intersection operation
    var intersection_result = utf8.UnicodeCharClass.init(allocator);
    defer intersection_result.deinit();
    try letters.intersection(&digits, &intersection_result);

    // Letters and digits should not intersect
    try testing.expect(!intersection_result.contains('A'));
    try testing.expect(!intersection_result.contains('0'));
}

test "UnicodeCharClass - word characters" {
    const allocator = testing.allocator;

    var word_chars = try utf8.UnicodeClasses.wordChars(allocator);
    defer word_chars.deinit();

    // Test word character detection
    try testing.expect(word_chars.contains('A'));
    try testing.expect(word_chars.contains('a'));
    try testing.expect(word_chars.contains('0'));
    try testing.expect(word_chars.contains('_'));
    try testing.expect(word_chars.contains(0x4E2D)); // 中
    try testing.expect(!word_chars.contains(' '));
    try testing.expect(!word_chars.contains('!'));
}

test "UnicodeCharClass - whitespace" {
    const allocator = testing.allocator;

    var whitespace = try utf8.UnicodeClasses.whitespace(allocator);
    defer whitespace.deinit();

    // Test whitespace character detection
    try testing.expect(whitespace.contains(' '));
    try testing.expect(whitespace.contains('\t'));
    try testing.expect(whitespace.contains('\n'));
    try testing.expect(whitespace.contains(0x00A0)); // Non-breaking space
    try testing.expect(whitespace.contains(0x3000)); // Ideographic space
    try testing.expect(!whitespace.contains('A'));
    try testing.expect(!whitespace.contains('0'));
}

test "UnicodeCharClass - punctuation" {
    const allocator = testing.allocator;

    var punctuation = try utf8.UnicodeClasses.punctuation(allocator);
    defer punctuation.deinit();

    // Test punctuation character detection
    try testing.expect(punctuation.contains('!'));
    try testing.expect(punctuation.contains(','));
    try testing.expect(punctuation.contains('.'));
    try testing.expect(punctuation.contains('?'));
    try testing.expect(punctuation.contains(0x3001)); // CJK comma
    try testing.expect(!punctuation.contains('A'));
    try testing.expect(!punctuation.contains(' '));
}

test "UnicodeCharClass - optimization" {
    const allocator = testing.allocator;

    var class = utf8.UnicodeCharClass.init(allocator);
    defer class.deinit();

    // Add overlapping ranges
    try class.addRange('A', 'Z', .Lu);
    try class.addRange('M', 'P', .Lu); // Overlaps with previous range
    try class.addRange('a', 'z', .Ll);

    try testing.expectEqual(@as(usize, 3), class.ranges.items.len);

    // Optimize should merge overlapping ranges
    try class.optimize();

    try testing.expect(class.ranges.items.len <= 3);

    // Verify the merged ranges still contain expected characters
    try testing.expect(class.contains('A'));
    try testing.expect(class.contains('Z'));
    try testing.expect(class.contains('a'));
    try testing.expect(class.contains('z'));
}

test "UnicodeCharClass - negation" {
    const allocator = testing.allocator;

    var letters = try utf8.UnicodeClasses.letters(allocator);
    defer letters.deinit();

    var negated = utf8.UnicodeCharClass.init(allocator);
    defer negated.deinit();

    try letters.negate(&negated);

    // Negated letters should contain non-letter characters
    try testing.expect(negated.contains('0'));
    try testing.expect(negated.contains(' '));
    try testing.expect(negated.contains('!'));
    try testing.expect(!negated.contains('A'));
    try testing.expect(!negated.contains('a'));
}

test "UnicodeCharClass - serialization" {
    const allocator = testing.allocator;

    var original = try utf8.UnicodeClasses.letters(allocator);
    defer original.deinit();

    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);

    // Serialize
    try original.serialize(buffer.writer(allocator));

    var restored = utf8.UnicodeCharClass.init(allocator);
    defer restored.deinit();

    // Deserialize
    var reader = std.io.fixedBufferStream(buffer.items);
    try restored.deserialize(reader.reader());

    // Verify deserialized class matches original
    try testing.expectEqual(original.ranges.items.len, restored.ranges.items.len);

    for (original.ranges.items) |range| {
        try testing.expect(restored.contains(range.start));
        try testing.expect(restored.contains(range.end));
    }
}

test "Utf8Boundary - boundary detection" {
    const test_str = "a中b𠮷c";

    // Valid boundaries
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 0)); // start
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 1)); // after 'a'
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 4)); // after '中'
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 5)); // after 'b'
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 9)); // after '𠮷'
    try testing.expect(utf8.Utf8Boundary.isBoundary(test_str, 10)); // end

    // Invalid boundaries (in middle of multi-byte sequences)
    try testing.expect(!utf8.Utf8Boundary.isBoundary(test_str, 2)); // middle of '中'
    try testing.expect(!utf8.Utf8Boundary.isBoundary(test_str, 3)); // middle of '中'
    try testing.expect(!utf8.Utf8Boundary.isBoundary(test_str, 6)); // middle of '𠮷'
    try testing.expect(!utf8.Utf8Boundary.isBoundary(test_str, 7)); // middle of '𠮷'
    try testing.expect(!utf8.Utf8Boundary.isBoundary(test_str, 8)); // middle of '𠮷'
}

test "Utf8Boundary - next and prev boundary" {
    const test_str = "a中b𠮷c";

    // Test nextBoundary
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Boundary.nextBoundary(test_str, 0).?);
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Boundary.nextBoundary(test_str, 1).?);
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Boundary.nextBoundary(test_str, 4).?);
    try testing.expectEqual(@as(usize, 9), utf8.Utf8Boundary.nextBoundary(test_str, 5).?);
    try testing.expectEqual(@as(usize, 10), utf8.Utf8Boundary.nextBoundary(test_str, 9).?);
    try testing.expectEqual(null, utf8.Utf8Boundary.nextBoundary(test_str, 10));

    // Test prevBoundary
    try testing.expectEqual(null, utf8.Utf8Boundary.prevBoundary(test_str, 0));
    try testing.expectEqual(@as(usize, 0), utf8.Utf8Boundary.prevBoundary(test_str, 1).?);
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Boundary.prevBoundary(test_str, 4).?);
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Boundary.prevBoundary(test_str, 5).?);
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Boundary.prevBoundary(test_str, 9).?);
    try testing.expectEqual(@as(usize, 9), utf8.Utf8Boundary.prevBoundary(test_str, 10).?);
}

test "Utf8Boundary - byte to char offset conversion" {
    const test_str = "a中b𠮷c";

    // byteToCharOffset
    try testing.expectEqual(@as(usize, 0), utf8.Utf8Boundary.byteToCharOffset(test_str, 0));
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Boundary.byteToCharOffset(test_str, 1));
    try testing.expectEqual(@as(usize, 2), utf8.Utf8Boundary.byteToCharOffset(test_str, 2)); // middle of '中'
    try testing.expectEqual(@as(usize, 2), utf8.Utf8Boundary.byteToCharOffset(test_str, 4));
    try testing.expectEqual(@as(usize, 3), utf8.Utf8Boundary.byteToCharOffset(test_str, 5));
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Boundary.byteToCharOffset(test_str, 6)); // middle of '𠮷'
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Boundary.byteToCharOffset(test_str, 9));
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Boundary.byteToCharOffset(test_str, 10));

    // charToByteOffset
    try testing.expectEqual(@as(usize, 0), utf8.Utf8Boundary.charToByteOffset(test_str, 0));
    try testing.expectEqual(@as(usize, 1), utf8.Utf8Boundary.charToByteOffset(test_str, 1));
    try testing.expectEqual(@as(usize, 4), utf8.Utf8Boundary.charToByteOffset(test_str, 2));
    try testing.expectEqual(@as(usize, 5), utf8.Utf8Boundary.charToByteOffset(test_str, 3));
    try testing.expectEqual(@as(usize, 9), utf8.Utf8Boundary.charToByteOffset(test_str, 4));
    try testing.expectEqual(@as(usize, 10), utf8.Utf8Boundary.charToByteOffset(test_str, 5));
}

test "Performance - UTF-8 decoding" {
    const test_str = "你好世界こんにちは안녕하세요Hello World!";
    const iterations = 1000;

    var iter = utf8.Utf8Iterator.init(test_str);
    var count: usize = 0;

    const start_time = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        iter.reset();
        while (iter.next()) |_| {
            count += 1;
        }
    }

    const elapsed = std.time.nanoTimestamp() - start_time;

    try testing.expect(count > 0);
    std.debug.print("UTF-8 decoding performance: {} iterations in {} ns\n", .{ iterations, elapsed });
}

test "Performance - UTF-8 encoding" {
    const codepoints = [_]u21{
        'H', 'e', 'l', 'l', 'o', ' ',
        0x4E16, 0x754C, // 世界
        0x3053, 0x3093, 0x306B, 0x3061, 0x306F, // こんにちは
        0xC548, 0xB155, 0xD558, 0xC138, 0xC694, // 안녕하세요
    };

    var buffer: [100]u8 = undefined;
    const iterations = 1000;

    const start_time = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = utf8.Utf8Encoder.encodeSlice(&codepoints, &buffer) catch unreachable;
    }

    const elapsed = std.time.nanoTimestamp() - start_time;

    try testing.expect(elapsed >= 0);
    std.debug.print("UTF-8 encoding performance: {} iterations in {} ns\n", .{ iterations, elapsed });
}