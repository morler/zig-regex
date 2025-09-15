// UTF-8 解码器
// 提供高效的UTF-8解码和编码功能

const std = @import("std");

// UTF-8解码结果
pub const DecodeResult = struct {
    codepoint: u21,
    byte_len: u3,
};

// UTF-8编码错误类型
pub const Utf8Error = error{
    InvalidUtf8Sequence,
    OverlongEncoding,
    InvalidCodepoint,
    UnexpectedContinuationByte,
    IncompleteSequence,
};

// UTF-8解码器
pub const Utf8Decoder = struct {
    // 解码单个UTF-8字符
    pub fn decodeFirst(bytes: []const u8) Utf8Error!DecodeResult {
        if (bytes.len == 0) return error.InvalidUtf8Sequence;

        const first_byte = bytes[0];

        // 1字节序列 (0xxxxxxx)
        if (first_byte & 0x80 == 0) {
            return DecodeResult{
                .codepoint = first_byte,
                .byte_len = 1,
            };
        }

        // 2字节序列 (110xxxxx 10xxxxxx)
        if (first_byte & 0xE0 == 0xC0) {
            return decodeTwoBytes(bytes);
        }

        // 3字节序列 (1110xxxx 10xxxxxx 10xxxxxx)
        if (first_byte & 0xF0 == 0xE0) {
            return decodeThreeBytes(bytes);
        }

        // 4字节序列 (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
        if (first_byte & 0xF8 == 0xF0) {
            return decodeFourBytes(bytes);
        }

        // 无效的UTF-8起始字节
        return error.InvalidUtf8Sequence;
    }

    // 在指定位置解码UTF-8字符
    pub fn decodeAt(bytes: []const u8, pos: usize) Utf8Error!DecodeResult {
        if (pos >= bytes.len) return error.InvalidUtf8Sequence;
        return decodeFirst(bytes[pos..]);
    }

    // 解码2字节UTF-8序列
    fn decodeTwoBytes(bytes: []const u8) Utf8Error!DecodeResult {
        if (bytes.len < 2) return error.IncompleteSequence;

        const first_byte = bytes[0];
        const second_byte = bytes[1];

        // 检查后续字节格式
        if (second_byte & 0xC0 != 0x80) return error.UnexpectedContinuationByte;

        // 提取码点
        const codepoint = ((@as(u21, first_byte) & 0x1F) << 6) | (@as(u21, second_byte) & 0x3F);

        // 检查过长的编码（例如用2字节编码ASCII字符）
        if (codepoint <= 0x7F) return error.OverlongEncoding;

        // 检查无效的2字节起始字节
        if (first_byte == 0xC0 or first_byte == 0xC1) return error.OverlongEncoding;

        return DecodeResult{
            .codepoint = codepoint,
            .byte_len = 2,
        };
    }

    // 解码3字节UTF-8序列
    fn decodeThreeBytes(bytes: []const u8) Utf8Error!DecodeResult {
        if (bytes.len < 3) return error.IncompleteSequence;

        const first_byte = bytes[0];
        const second_byte = bytes[1];
        const third_byte = bytes[2];

        // 检查后续字节格式
        if (second_byte & 0xC0 != 0x80 or third_byte & 0xC0 != 0x80) {
            return error.UnexpectedContinuationByte;
        }

        // 提取码点
        const codepoint = ((@as(u21, first_byte) & 0x0F) << 12) |
            ((@as(u21, second_byte) & 0x3F) << 6) |
            (@as(u21, third_byte) & 0x3F);

        // 检查过长的编码
        if (codepoint <= 0x7FF) return error.OverlongEncoding;

        // 检查代理对区域（无效的Unicode码点）
        if (0xD800 <= codepoint and codepoint <= 0xDFFF) return error.InvalidCodepoint;

        return DecodeResult{
            .codepoint = codepoint,
            .byte_len = 3,
        };
    }

    // 解码4字节UTF-8序列
    fn decodeFourBytes(bytes: []const u8) Utf8Error!DecodeResult {
        if (bytes.len < 4) return error.IncompleteSequence;

        const first_byte = bytes[0];
        const second_byte = bytes[1];
        const third_byte = bytes[2];
        const fourth_byte = bytes[3];

        // 检查后续字节格式
        if (second_byte & 0xC0 != 0x80 or
            third_byte & 0xC0 != 0x80 or
            fourth_byte & 0xC0 != 0x80) {
            return error.UnexpectedContinuationByte;
        }

        // 提取码点
        const codepoint = ((@as(u21, first_byte) & 0x07) << 18) |
            ((@as(u21, second_byte) & 0x3F) << 12) |
            ((@as(u21, third_byte) & 0x3F) << 6) |
            (@as(u21, fourth_byte) & 0x3F);

        // 检查过长的编码
        if (codepoint <= 0xFFFF) return error.OverlongEncoding;

        // 检查超出Unicode范围的码点
        if (codepoint > 0x10FFFF) return error.InvalidCodepoint;

        return DecodeResult{
            .codepoint = codepoint,
            .byte_len = 4,
        };
    }

    // 检查字节序列是否是有效的UTF-8
    pub fn validate(bytes: []const u8) bool {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const result = decodeFirst(bytes[pos..]) catch return false;
            pos += result.byte_len;
        }
        return true;
    }

    // 计算UTF-8字符串中的字符数量
    pub fn countCodepoints(bytes: []const u8) usize {
        var count: usize = 0;
        var pos: usize = 0;

        while (pos < bytes.len) {
            const result = decodeFirst(bytes[pos..]) catch break;
            count += 1;
            pos += result.byte_len;
        }

        return count;
    }

    // 获取UTF-8字符串的迭代器
    pub fn iterator(bytes: []const u8) Utf8Iterator {
        return Utf8Iterator.init(bytes);
    }
};

// UTF-8编码器
pub const Utf8Encoder = struct {
    // 编码单个Unicode码点为UTF-8
    pub fn encode(codepoint: u21, buffer: []u8) Utf8Error![]const u8 {
        if (codepoint > 0x10FFFF) return error.InvalidCodepoint;

        // 检查代理对区域（无效的Unicode码点）
        if (0xD800 <= codepoint and codepoint <= 0xDFFF) return error.InvalidCodepoint;

        if (codepoint <= 0x7F) {
            // 1字节序列
            if (buffer.len < 1) return error.IncompleteSequence;
            buffer[0] = @as(u8, @truncate(codepoint));
            return buffer[0..1];
        } else if (codepoint <= 0x7FF) {
            // 2字节序列
            if (buffer.len < 2) return error.IncompleteSequence;
            buffer[0] = 0xC0 | @as(u8, @truncate((codepoint >> 6) & 0x1F));
            buffer[1] = 0x80 | @as(u8, @truncate(codepoint & 0x3F));
            return buffer[0..2];
        } else if (codepoint <= 0xFFFF) {
            // 3字节序列
            if (buffer.len < 3) return error.IncompleteSequence;
            buffer[0] = 0xE0 | @as(u8, @truncate((codepoint >> 12) & 0x0F));
            buffer[1] = 0x80 | @as(u8, @truncate((codepoint >> 6) & 0x3F));
            buffer[2] = 0x80 | @as(u8, @truncate(codepoint & 0x3F));
            return buffer[0..3];
        } else {
            // 4字节序列
            if (buffer.len < 4) return error.IncompleteSequence;
            buffer[0] = 0xF0 | @as(u8, @truncate((codepoint >> 18) & 0x07));
            buffer[1] = 0x80 | @as(u8, @truncate((codepoint >> 12) & 0x3F));
            buffer[2] = 0x80 | @as(u8, @truncate((codepoint >> 6) & 0x3F));
            buffer[3] = 0x80 | @as(u8, @truncate(codepoint & 0x3F));
            return buffer[0..4];
        }
    }

    // 计算编码码点所需的字节数
    pub fn encodedLength(codepoint: u21) u3 {
        if (codepoint <= 0x7F) return 1;
        if (codepoint <= 0x7FF) return 2;
        if (codepoint <= 0xFFFF) return 3;
        if (codepoint <= 0x10FFFF) return 4;
        return 0; // 无效码点
    }

    // 编码码点序列
    pub fn encodeSlice(codepoints: []const u21, buffer: []u8) Utf8Error![]const u8 {
        var pos: usize = 0;
        for (codepoints) |cp| {
            const encoded = encode(cp, buffer[pos..]) catch return error.IncompleteSequence;
            pos += encoded.len;
        }
        return buffer[0..pos];
    }
};

// UTF-8迭代器
pub const Utf8Iterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) Utf8Iterator {
        return Utf8Iterator{
            .bytes = bytes,
            .pos = 0,
        };
    }

    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.pos >= self.bytes.len) return null;

        const result = Utf8Decoder.decodeFirst(self.bytes[self.pos..]) catch {
            // 跳过无效字节
            self.pos += 1;
            return null;
        };

        self.pos += result.byte_len;
        return result.codepoint;
    }

    pub fn peek(self: *Utf8Iterator) ?u21 {
        if (self.pos >= self.bytes.len) return null;

        const result = Utf8Decoder.decodeFirst(self.bytes[self.pos..]) catch return null;
        return result.codepoint;
    }

    pub fn hasNext(self: *Utf8Iterator) bool {
        return self.pos < self.bytes.len;
    }

    pub fn reset(self: *Utf8Iterator) void {
        self.pos = 0;
    }

    pub fn position(self: *Utf8Iterator) usize {
        return self.pos;
    }
};

// Unicode字符分类器
pub const UnicodeClassifier = struct {
    // 检查字符是否为字母
    pub fn isLetter(codepoint: u21) bool {
        // ASCII字母
        if (codepoint <= 0x7F) {
            return switch (codepoint) {
                'a'...'z', 'A'...'Z' => true,
                else => false,
            };
        }

        // Unicode字母类别（简化版本）
        return isUnicodeLetter(codepoint);
    }

    // 检查字符是否为数字
    pub fn isDigit(codepoint: u21) bool {
        // ASCII数字
        if (codepoint <= 0x7F) {
            return switch (codepoint) {
                '0'...'9' => true,
                else => false,
            };
        }

        // Unicode数字类别（简化版本）
        return isUnicodeDigit(codepoint);
    }

    // 检查字符是否为单词字符
    pub fn isWordChar(codepoint: u21) bool {
        return isLetter(codepoint) or isDigit(codepoint) or codepoint == '_';
    }

    // 检查字符是否为空白字符
    pub fn isWhitespace(codepoint: u21) bool {
        // ASCII空白字符
        if (codepoint <= 0x7F) {
            return switch (codepoint) {
                ' ', '\t', '\n', '\r', 0x0C, 0x0B => true, // \f and \v as hex values
                else => false,
            };
        }

        // Unicode空白字符（简化版本）
        return isUnicodeWhitespace(codepoint);
    }

    // 检查字符是否为标点符号
    pub fn isPunctuation(codepoint: u21) bool {
        // ASCII标点
        if (codepoint <= 0x7F) {
            return switch (codepoint) {
                '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
                ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
                else => false,
            };
        }

        // Unicode标点（简化版本）
        return isUnicodePunctuation(codepoint);
    }

    // 简化的Unicode字母检测
    fn isUnicodeLetter(codepoint: u21) bool {
        // 主要的Unicode字母范围（不完整，实际应使用Unicode数据库）
        return (codepoint >= 0x00AA and codepoint <= 0x00AA) or // ª
            (codepoint >= 0x00B5 and codepoint <= 0x00B5) or // µ
            (codepoint >= 0x00BA and codepoint <= 0x00BA) or // º
            (codepoint >= 0x00C0 and codepoint <= 0x00D6) or // À-Ö
            (codepoint >= 0x00D8 and codepoint <= 0x00F6) or // Ø-ö
            (codepoint >= 0x00F8 and codepoint <= 0x00FF) or // ø-ÿ
            (codepoint >= 0x0100 and codepoint <= 0x017F) or // 拉丁扩展A
            (codepoint >= 0x0180 and codepoint <= 0x024F) or // 拉丁扩展B
            (codepoint >= 0x0370 and codepoint <= 0x03FF) or // 希腊和科普特
            (codepoint >= 0x0400 and codepoint <= 0x04FF) or // 西里尔
            (codepoint >= 0x0530 and codepoint <= 0x058F) or // 亚美尼亚
            (codepoint >= 0x0590 and codepoint <= 0x05FF) or // 希伯来
            (codepoint >= 0x0600 and codepoint <= 0x06FF) or // 阿拉伯
            (codepoint >= 0x0900 and codepoint <= 0x097F) or // 天城文
            (codepoint >= 0x4E00 and codepoint <= 0x9FFF);   // CJK统一表意文字
    }

    // 简化的Unicode数字检测
    fn isUnicodeDigit(codepoint: u21) bool {
        // 主要的Unicode数字范围（不完整）
        return (codepoint >= 0x0660 and codepoint <= 0x0669) or // 阿拉伯-印度数字
            (codepoint >= 0x06F0 and codepoint <= 0x06F9) or // 波斯数字
            (codepoint >= 0x0966 and codepoint <= 0x096F) or // 天城文数字
            (codepoint >= 0xFF10 and codepoint <= 0xFF19);   // 全角数字
    }

    // 简化的Unicode空白检测
    fn isUnicodeWhitespace(codepoint: u21) bool {
        // 常见的Unicode空白字符
        return switch (codepoint) {
            0x00A0, // 不换行空格
            0x1680, // 奥格姆空格
            0x2000...0x200A, // 各种宽度空格
            0x2028, // 行分隔符
            0x2029, // 段落分隔符
            0x202F, // 窄不换行空格
            0x205F, // 中学数学空格
            0x3000, // 表意文字空格
            => true,
            else => false,
        };
    }

    // 简化的Unicode标点检测
    fn isUnicodePunctuation(codepoint: u21) bool {
        // 常见的Unicode标点范围
        return (codepoint >= 0x2000 and codepoint <= 0x206F) or // 通用标点
            (codepoint >= 0x3000 and codepoint <= 0x303F) or // CJK标点和符号
            (codepoint >= 0xFF00 and codepoint <= 0xFFEF);   // 半角和全角形式
    }
};

// UTF-8边界检测器
pub const Utf8Boundary = struct {
    // 检查位置是否在UTF-8字符边界上
    pub fn isBoundary(bytes: []const u8, pos: usize) bool {
        if (pos == 0) return true;
        if (pos >= bytes.len) return true;

        // 检查当前字节是否为UTF-8序列的起始字节
        const byte = bytes[pos];
        return (byte & 0xC0) != 0x80; // 不是连续字节
    }

    // 查找下一个UTF-8字符边界
    pub fn nextBoundary(bytes: []const u8, pos: usize) ?usize {
        if (pos >= bytes.len) return null;

        // 获取当前字符的字节长度
        const result = Utf8Decoder.decodeFirst(bytes[pos..]) catch return null;
        return pos + result.byte_len;
    }

    // 查找前一个UTF-8字符边界
    pub fn prevBoundary(bytes: []const u8, pos: usize) ?usize {
        if (pos == 0) return null;

        // 向后查找非连续字节
        var search_pos = pos - 1;
        while (search_pos > 0 and (bytes[search_pos] & 0xC0) == 0x80) {
            search_pos -= 1;
        }

        return search_pos;
    }

    // 计算从字节位置到字符位置的偏移
    pub fn byteToCharOffset(bytes: []const u8, byte_pos: usize) usize {
        var char_count: usize = 0;
        var current_pos: usize = 0;

        while (current_pos < byte_pos and current_pos < bytes.len) {
            const result = Utf8Decoder.decodeFirst(bytes[current_pos..]) catch {
                // 跳过无效字节，继续计算
                char_count += 1;
                current_pos += 1;
                continue;
            };
            char_count += 1;
            current_pos += result.byte_len;
        }

        return char_count;
    }

    // 计算从字符位置到字节位置的偏移
    pub fn charToByteOffset(bytes: []const u8, char_pos: usize) usize {
        var byte_pos: usize = 0;
        var current_char: usize = 0;

        while (current_char < char_pos and byte_pos < bytes.len) {
            const result = Utf8Decoder.decodeFirst(bytes[byte_pos..]) catch break;
            byte_pos += result.byte_len;
            current_char += 1;
        }

        return byte_pos;
    }
};