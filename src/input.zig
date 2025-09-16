// 简化的输入处理模块
// 移除了复杂的comptime多态，使用简单的运行时分发

const std = @import("std");
const Assertion = @import("parse.zig").Assertion;

// 输入模式枚举
pub const InputMode = enum {
    bytes,  // 字节模式
    utf8,   // UTF-8模式
};

// 简化的输入结构体
pub const Input = struct {
    bytes: []const u8,
    byte_pos: usize,
    mode: InputMode,
    multiline: bool,
    is_ascii: bool, // ASCII快速路径标记

    // 初始化函数
    pub fn init(bytes: []const u8, mode: InputMode) Input {
        return Input{
            .bytes = bytes,
            .byte_pos = 0,
            .mode = mode,
            .multiline = false,
            .is_ascii = isAscii(bytes),
        };
    }

    pub fn initWithMultiline(bytes: []const u8, mode: InputMode, multiline: bool) Input {
        return Input{
            .bytes = bytes,
            .byte_pos = 0,
            .mode = mode,
            .multiline = multiline,
            .is_ascii = isAscii(bytes),
        };
    }

    // 基础访问方法
    pub fn current(self: Input) ?u21 {
        switch (self.mode) {
            .bytes => {
                if (self.byte_pos < self.bytes.len) {
                    return self.bytes[self.byte_pos];
                }
                return null;
            },
            .utf8 => {
                return self.getCurrentCodepoint();
            },
        }
    }

    pub fn advance(self: *Input) void {
        if (self.byte_pos >= self.bytes.len) return;

        switch (self.mode) {
            .bytes => {
                self.byte_pos += 1;
            },
            .utf8 => {
                const first_byte = self.bytes[self.byte_pos];
                // 1字节序列
                if (first_byte & 0x80 == 0) {
                    self.byte_pos += 1;
                    return;
                }
                // 2字节序列
                if (first_byte & 0xE0 == 0xC0) {
                    self.byte_pos += 2;
                    return;
                }
                // 3字节序列
                if (first_byte & 0xF0 == 0xE0) {
                    self.byte_pos += 3;
                    return;
                }
                // 4字节序列
                if (first_byte & 0xF8 == 0xF0) {
                    self.byte_pos += 4;
                    return;
                }
                // 无效序列，跳过1字节
                self.byte_pos += 1;
            },
        }
    }

    // 状态检查方法
    pub fn isConsumed(self: Input) bool {
        return self.byte_pos >= self.bytes.len;
    }

    pub fn clone(self: Input) Input {
        return Input{
            .bytes = self.bytes,
            .byte_pos = self.byte_pos,
            .mode = self.mode,
            .multiline = self.multiline,
            .is_ascii = self.is_ascii,
        };
    }

    // 词字符检测
    fn isWordCharByte(c: u8) bool {
        return switch (c) {
            '0'...'9', 'a'...'z', 'A'...'Z' => true,
            else => false,
        };
    }

    fn isWordCharUtf8(codepoint: u21) bool {
        if (codepoint <= 0x7F) {
            return switch (codepoint) {
                '0'...'9', 'a'...'z', 'A'...'Z' => true,
                else => false,
            };
        }
        // Unicode字母和数字 - 包含常见的欧洲语言字符
        return (codepoint >= 0x00C0 and codepoint <= 0x00D6) or  // 带重音的拉丁字母A-O
               (codepoint >= 0x00D8 and codepoint <= 0x00F6) or  // 带重音的拉丁字母P-o
               (codepoint >= 0x00F8 and codepoint <= 0x00FF) or  // 带重音的拉丁字母p-ÿ
               (codepoint >= 0x0100 and codepoint <= 0x017F) or  // 拉丁扩展A
               (codepoint >= 0x0180 and codepoint <= 0x024F) or  // 拉丁扩展B
               (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or  // CJK统一汉字
               (codepoint >= 0x20000 and codepoint <= 0x2A6DF);  // CJK扩展B
    }

    pub fn isCurrentWordChar(self: Input) bool {
        if (self.byte_pos >= self.bytes.len) return false;

        switch (self.mode) {
            .bytes => {
                return isWordCharByte(self.bytes[self.byte_pos]);
            },
            .utf8 => {
                const codepoint = self.getCurrentCodepoint() orelse return false;
                return isWordCharUtf8(codepoint);
            },
        }
    }

    pub fn isPreviousWordChar(self: Input) bool {
        if (self.byte_pos == 0) return false;

        switch (self.mode) {
            .bytes => {
                return isWordCharByte(self.bytes[self.byte_pos - 1]);
            },
            .utf8 => {
                const codepoint = self.getPreviousCodepoint() orelse return false;
                return isWordCharUtf8(codepoint);
            },
        }
    }

    pub fn isNextWordChar(self: Input) bool {
        const next_pos = switch (self.mode) {
            .bytes => self.byte_pos + 1,
            .utf8 => self.getNextUtf8Pos(self.byte_pos) orelse return false,
        };
        if (next_pos >= self.bytes.len) return false;

        switch (self.mode) {
            .bytes => {
                return isWordCharByte(self.bytes[next_pos]);
            },
            .utf8 => {
                const codepoint = self.getCodepointAt(next_pos) orelse return false;
                return isWordCharUtf8(codepoint);
            },
        }
    }

    // UTF-8辅助方法
    fn getCurrentCodepoint(self: Input) ?u21 {
        if (self.byte_pos >= self.bytes.len) return null;
        return self.getCodepointAt(self.byte_pos);
    }

    fn getPreviousCodepoint(self: Input) ?u21 {
        if (self.byte_pos == 0) return null;
        const prev_pos = self.getPreviousUtf8Pos(self.byte_pos) orelse return null;
        return self.getCodepointAt(prev_pos);
    }

    fn getCodepointAt(self: Input, pos: usize) ?u21 {
        if (pos >= self.bytes.len) return null;

        const first_byte = self.bytes[pos];

        // 1字节序列
        if (first_byte & 0x80 == 0) {
            return first_byte;
        }

        // 2字节序列
        if (first_byte & 0xE0 == 0xC0) {
            if (pos + 1 >= self.bytes.len) return null;
            const second_byte = self.bytes[pos + 1];
            if (second_byte & 0xC0 != 0x80) return null;
            return ((@as(u21, first_byte) & 0x1F) << 6) | (@as(u21, second_byte) & 0x3F);
        }

        // 3字节序列
        if (first_byte & 0xF0 == 0xE0) {
            if (pos + 2 >= self.bytes.len) return null;
            const second_byte = self.bytes[pos + 1];
            const third_byte = self.bytes[pos + 2];
            if (second_byte & 0xC0 != 0x80 or third_byte & 0xC0 != 0x80) return null;
            return ((@as(u21, first_byte) & 0x0F) << 12) |
                   ((@as(u21, second_byte) & 0x3F) << 6) |
                   (@as(u21, third_byte) & 0x3F);
        }

        // 4字节序列
        if (first_byte & 0xF8 == 0xF0) {
            if (pos + 3 >= self.bytes.len) return null;
            const second_byte = self.bytes[pos + 1];
            const third_byte = self.bytes[pos + 2];
            const fourth_byte = self.bytes[pos + 3];
            if (second_byte & 0xC0 != 0x80 or
                third_byte & 0xC0 != 0x80 or
                fourth_byte & 0xC0 != 0x80) return null;
            return ((@as(u21, first_byte) & 0x07) << 18) |
                   ((@as(u21, second_byte) & 0x3F) << 12) |
                   ((@as(u21, third_byte) & 0x3F) << 6) |
                   (@as(u21, fourth_byte) & 0x3F);
        }

        return null;
    }

    fn getNextUtf8Pos(self: Input, pos: usize) ?usize {
        if (pos >= self.bytes.len) return null;

        const first_byte = self.bytes[pos];

        if (first_byte & 0x80 == 0) return pos + 1;
        if (first_byte & 0xE0 == 0xC0) return pos + 2;
        if (first_byte & 0xF0 == 0xE0) return pos + 3;
        if (first_byte & 0xF8 == 0xF0) return pos + 4;
        return pos + 1;
    }

    fn getPreviousUtf8Pos(self: Input, pos: usize) ?usize {
        if (pos == 0) return null;

        var check_pos = pos - 1;
        while (check_pos > 0) {
            const byte = self.bytes[check_pos];
            if (byte & 0xC0 != 0x80) {
                return check_pos;
            }
            check_pos -= 1;
        }
        return 0;
    }

    // 空匹配断言
    pub fn isEmptyMatch(self: Input, match: Assertion) bool {
        switch (match) {
            .BeginLine => {
                if (!self.multiline) return self.byte_pos == 0;
                if (self.byte_pos == 0) return true;
                return self.bytes[self.byte_pos - 1] == '\n';
            },
            .EndLine => {
                if (!self.multiline) return self.byte_pos == self.bytes.len;
                if (self.byte_pos == self.bytes.len) return true;
                return self.bytes[self.byte_pos] == '\n';
            },
            .BeginText => return self.byte_pos == 0,
            .EndText => return self.byte_pos == self.bytes.len,
            .WordBoundaryAscii => {
                const current_is_word = self.isCurrentWordChar();
                const prev_is_word = self.isPreviousWordChar();
                return current_is_word != prev_is_word;
            },
            .NotWordBoundaryAscii => {
                const current_is_word = self.isCurrentWordChar();
                const prev_is_word = self.isPreviousWordChar();
                return current_is_word == prev_is_word;
            },
            else => return false,
        }
    }

    // 获取底层字节数据
    pub fn asBytes(self: Input) []const u8 {
        return self.bytes;
    }

    // 获取当前字节位置
    pub fn getBytePos(self: Input) usize {
        return self.byte_pos;
    }

    // 设置字节位置
    pub fn setBytePos(self: *Input, pos: usize) void {
        self.byte_pos = @min(pos, self.bytes.len);
    }
};

// 检查字节切片是否为纯ASCII
fn isAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 127) {
            return false;
        }
    }
    return true;
}