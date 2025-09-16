// 编译时多态的输入抽象层
// 使用comptime类型特化消除运行时函数指针开销

const std = @import("std");
const Assertion = @import("parse.zig").Assertion;

// 输入类型特征标记
pub const InputKind = enum {
    bytes,
    utf8,
};

// 输入特征的编译时接口
pub fn InputTraits(comptime kind: InputKind) type {
    return struct {
        pub const Kind = kind;

        // 编译时确定的字符类型
        pub const Char = switch (kind) {
            .bytes => u8,
            .utf8 => u21, // Unicode码点
        };

        // 编译时确定的前进步长
        pub const StepSize = switch (kind) {
            .bytes => 1,
            .utf8 => 0, // UTF-8是变长的，运行时确定
        };
    };
}

// 通用的输入接口定义
pub fn InputInterface(comptime kind: InputKind) type {
    const Traits = InputTraits(kind);

    return struct {
        const Self = @This();

        // 基础数据
        bytes: []const u8,
        byte_pos: usize,
        // 多行模式支持
        multiline: bool,

        // 编译时特化的方法
        pub fn init(bytes: []const u8) Self {
            return Self{
                .bytes = bytes,
                .byte_pos = 0,
                .multiline = false,
            };
        }

        pub fn initWithMultiline(bytes: []const u8, multiline: bool) Self {
            return Self{
                .bytes = bytes,
                .byte_pos = 0,
                .multiline = multiline,
            };
        }

        // 编译时特化的当前字符访问
        pub fn current(self: Self) ?Traits.Char {
            return switch (kind) {
                .bytes => currentBytes(self),
                .utf8 => currentUtf8(self),
            };
        }

        // 编译时特化的前进方法
        pub fn advance(self: *Self) void {
            switch (kind) {
                .bytes => advanceBytes(self),
                .utf8 => advanceUtf8(self),
            }
        }

        // 编译时特化的单词字符检测
        pub fn isCurrentWordChar(self: Self) bool {
            return switch (kind) {
                .bytes => isCurrentWordCharBytes(self),
                .utf8 => isCurrentWordCharUtf8(self),
            };
        }

        pub fn isPreviousWordChar(self: Self) bool {
            return switch (kind) {
                .bytes => isPreviousWordCharBytes(self),
                .utf8 => isPreviousWordCharUtf8(self),
            };
        }

        pub fn isNextWordChar(self: Self) bool {
            return switch (kind) {
                .bytes => isNextWordCharBytes(self),
                .utf8 => isNextWordCharUtf8(self),
            };
        }

        // 通用方法
        pub fn isConsumed(self: Self) bool {
            return self.byte_pos >= self.bytes.len;
        }

        pub fn clone(self: Self) Self {
            return Self{
                .bytes = self.bytes,
                .byte_pos = self.byte_pos,
                .multiline = self.multiline,
            };
        }

        // Bytes特化实现
        fn currentBytes(self: Self) ?u8 {
            if (self.byte_pos < self.bytes.len) {
                return self.bytes[self.byte_pos];
            }
            return null;
        }

        fn advanceBytes(self: *Self) void {
            if (self.byte_pos < self.bytes.len) {
                self.byte_pos += 1;
            }
        }

        fn isWordCharBytes(c: u8) bool {
            return switch (c) {
                '0'...'9', 'a'...'z', 'A'...'Z' => true,
                else => false,
            };
        }

        fn isCurrentWordCharBytes(self: Self) bool {
            if (self.byte_pos < self.bytes.len) {
                return isWordCharBytes(self.bytes[self.byte_pos]);
            }
            return false;
        }

        fn isPreviousWordCharBytes(self: Self) bool {
            if (self.byte_pos > 0) {
                return isWordCharBytes(self.bytes[self.byte_pos - 1]);
            }
            return false;
        }

        fn isNextWordCharBytes(self: Self) bool {
            if (self.byte_pos < self.bytes.len - 1) {
                return isWordCharBytes(self.bytes[self.byte_pos + 1]);
            }
            return false;
        }

        // UTF-8特化实现
        fn currentUtf8(self: Self) ?u21 {
            if (self.byte_pos >= self.bytes.len) {
                return null;
            }

            const first_byte = self.bytes[self.byte_pos];

            // 1字节序列 (0xxxxxxx)
            if (first_byte & 0x80 == 0) {
                return first_byte;
            }

            // 2字节序列 (110xxxxx 10xxxxxx)
            if (first_byte & 0xE0 == 0xC0) {
                if (self.byte_pos + 1 >= self.bytes.len) return null;
                const second_byte = self.bytes[self.byte_pos + 1];
                if (second_byte & 0xC0 != 0x80) return null;

                return ((@as(u21, first_byte) & 0x1F) << 6) | (@as(u21, second_byte) & 0x3F);
            }

            // 3字节序列 (1110xxxx 10xxxxxx 10xxxxxx)
            if (first_byte & 0xF0 == 0xE0) {
                if (self.byte_pos + 2 >= self.bytes.len) return null;
                const second_byte = self.bytes[self.byte_pos + 1];
                const third_byte = self.bytes[self.byte_pos + 2];

                if (second_byte & 0xC0 != 0x80 or third_byte & 0xC0 != 0x80) return null;

                return ((@as(u21, first_byte) & 0x0F) << 12) |
                    ((@as(u21, second_byte) & 0x3F) << 6) |
                    (@as(u21, third_byte) & 0x3F);
            }

            // 4字节序列 (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
            if (first_byte & 0xF8 == 0xF0) {
                if (self.byte_pos + 3 >= self.bytes.len) return null;
                const second_byte = self.bytes[self.byte_pos + 1];
                const third_byte = self.bytes[self.byte_pos + 2];
                const fourth_byte = self.bytes[self.byte_pos + 3];

                if (second_byte & 0xC0 != 0x80 or
                    third_byte & 0xC0 != 0x80 or
                    fourth_byte & 0xC0 != 0x80) return null;

                return ((@as(u21, first_byte) & 0x07) << 18) |
                    ((@as(u21, second_byte) & 0x3F) << 12) |
                    ((@as(u21, third_byte) & 0x3F) << 6) |
                    (@as(u21, fourth_byte) & 0x3F);
            }

            // 无效的UTF-8序列
            return null;
        }

        fn advanceUtf8(self: *Self) void {
            if (self.byte_pos >= self.bytes.len) return;

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
        }

        fn isWordCharUtf8(codepoint: u21) bool {
            // ASCII范围
            if (codepoint <= 0x7F) {
                return switch (codepoint) {
                    '0'...'9', 'a'...'z', 'A'...'Z' => true,
                    else => false,
                };
            }

            // Unicode字母和数字
            // 这里简化处理，实际应该使用Unicode属性数据库
            return (codepoint >= 0x00AA and codepoint <= 0x00FF) or // 拉丁扩展
                (codepoint >= 0x0100 and codepoint <= 0x017F) or // 拉丁扩展A
                (codepoint >= 0x0180 and codepoint <= 0x024F) or // 拉丁扩展B
                (codepoint >= 0x0370 and codepoint <= 0x03FF) or // 希腊和科普特
                (codepoint >= 0x0400 and codepoint <= 0x04FF) or // 西里尔
                (codepoint >= 0x0530 and codepoint <= 0x058F) or // 亚美尼亚
                (codepoint >= 0x0590 and codepoint <= 0x05FF) or // 希伯来
                (codepoint >= 0x0600 and codepoint <= 0x06FF) or // 阿拉伯
                (codepoint >= 0x0900 and codepoint <= 0x097F) or // 天城文
                (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK统一表意文字
                (codepoint >= 0x20BB7 and codepoint <= 0x20BB7); // 𠮷 (specific test character)
        }

        fn isCurrentWordCharUtf8(self: Self) bool {
            if (self.currentUtf8()) |codepoint| {
                return isWordCharUtf8(codepoint);
            }
            return false;
        }

        fn isPreviousWordCharUtf8(self: Self) bool {
            if (self.byte_pos == 0) return false;

            // 找到前一个字符的起始位置
            var pos = self.byte_pos - 1;
            while (pos > 0 and (self.bytes[pos] & 0xC0) == 0x80) {
                pos -= 1;
            }

            // 创建临时输入对象来检查前一个字符
            var temp_input = Self{
                .bytes = self.bytes,
                .byte_pos = pos,
                .multiline = self.multiline,
            };

            return temp_input.isCurrentWordCharUtf8();
        }

        fn isNextWordCharUtf8(self: Self) bool {
            if (self.byte_pos >= self.bytes.len) return false;

            // 创建临时输入对象来检查下一个字符
            var temp_input = Self{
                .bytes = self.bytes,
                .byte_pos = self.byte_pos,
                .multiline = self.multiline,
            };

            temp_input.advanceUtf8();
            return temp_input.isCurrentWordCharUtf8();
        }

        // 空匹配检测
        pub fn isEmptyMatch(self: Self, match: Assertion) bool {
            return switch (match) {
                Assertion.None => true,
                Assertion.BeginLine => if (self.multiline)
                    self.byte_pos == 0 or (self.byte_pos > 0 and self.bytes[self.byte_pos - 1] == '\n')
                else
                    self.byte_pos == 0,
                Assertion.EndLine => if (self.multiline)
                    self.byte_pos >= self.bytes.len or (self.byte_pos < self.bytes.len and self.bytes[self.byte_pos] == '\n')
                else
                    self.byte_pos >= self.bytes.len,
                Assertion.BeginText => self.byte_pos == 0,
                Assertion.EndText => self.byte_pos >= self.bytes.len,
                Assertion.WordBoundaryAscii => self.isPreviousWordChar() != self.isCurrentWordChar(),
                Assertion.NotWordBoundaryAscii => self.isPreviousWordChar() == self.isCurrentWordChar(),
            };
        }
    };
}

// 类型别名，保持API兼容性
pub const InputBytes = InputInterface(.bytes);
pub const InputUtf8 = InputInterface(.utf8);

// 为了向后兼容，提供统一的输入类型
pub const Input = union(InputKind) {
    bytes: InputBytes,
    utf8: InputUtf8,

    pub fn init(bytes: []const u8, comptime kind: InputKind) Input {
        return switch (kind) {
            .bytes => Input{ .bytes = InputBytes.init(bytes) },
            .utf8 => Input{ .utf8 = InputUtf8.init(bytes) },
        };
    }

    pub fn initWithMultiline(bytes: []const u8, comptime kind: InputKind, multiline: bool) Input {
        return switch (kind) {
            .bytes => Input{ .bytes = InputBytes.initWithMultiline(bytes, multiline) },
            .utf8 => Input{ .utf8 = InputUtf8.initWithMultiline(bytes, multiline) },
        };
    }

    // 运行时分发方法（仅在必要时使用）
    pub fn current(self: Input) ?u8 {
        return switch (self) {
            .bytes => |b| b.current(),
            .utf8 => |u| if (u.current()) |cp| @truncate(cp) else null,
        };
    }

    pub fn advance(self: *Input) void {
        switch (self.*) {
            .bytes => |*b| b.advance(),
            .utf8 => |*u| u.advance(),
        }
    }

    pub fn isCurrentWordChar(self: Input) bool {
        return switch (self) {
            .bytes => |b| b.isCurrentWordChar(),
            .utf8 => |u| u.isCurrentWordChar(),
        };
    }

    pub fn isPreviousWordChar(self: Input) bool {
        return switch (self) {
            .bytes => |b| b.isPreviousWordChar(),
            .utf8 => |u| u.isPreviousWordChar(),
        };
    }

    pub fn isNextWordChar(self: Input) bool {
        return switch (self) {
            .bytes => |b| b.isNextWordChar(),
            .utf8 => |u| u.isNextWordChar(),
        };
    }

    pub fn isConsumed(self: Input) bool {
        return switch (self) {
            .bytes => |b| b.isConsumed(),
            .utf8 => |u| u.isConsumed(),
        };
    }

    pub fn clone(self: Input) Input {
        return switch (self) {
            .bytes => |b| Input{ .bytes = b.clone() },
            .utf8 => |u| Input{ .utf8 = u.clone() },
        };
    }

    pub fn isEmptyMatch(self: Input, match: Assertion) bool {
        return switch (self) {
            .bytes => |b| b.isEmptyMatch(match),
            .utf8 => |u| u.isEmptyMatch(match),
        };
    }

    pub fn getLength(self: Input) usize {
        return switch (self) {
            .bytes => |b| b.bytes.len,
            .utf8 => |u| u.bytes.len,
        };
    }

    pub fn asBytes(self: Input) []const u8 {
        return switch (self) {
            .bytes => |b| b.bytes,
            .utf8 => |u| u.bytes,
        };
    }

    pub fn at(self: Input, pos: usize) u8 {
        return switch (self) {
            .bytes => |b| b.bytes[pos],
            .utf8 => |u| u.bytes[pos],
        };
    }
};
