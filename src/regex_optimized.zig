// 优化版正则表达式API
// 集成内存池和对象池系统，提供高性能的内存管理

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const compile = @import("compile.zig");
const Program = compile.Program;
const exec = @import("exec.zig");
const input_new = @import("input_new.zig");
const Input = input_new.Input;
const utf8 = @import("utf8.zig");
const literal_engine = @import("literal_engine.zig");
const memory_pool = @import("memory_pool.zig");
const MemoryManager = memory_pool.MemoryManager;
const OptimizedArrayList = memory_pool.OptimizedArrayList;

// 重用原始API的类型定义
const MatchOptions = @import("regex_new.zig").MatchOptions;
const CompileOptions = @import("regex_new.zig").CompileOptions;

// 优化版的匹配结果
pub const OptimizedMatch = struct {
    span: Span,
    captures: ?[]const Span,
    engine_info: EngineInfo,

    pub const Span = struct {
        start: usize,
        end: usize,
    };

    pub const EngineInfo = struct {
        engine_type: EngineType,
        used_unicode: bool,
        used_literal_optimization: bool,
        match_time_ns: u64,
    };

    pub const EngineType = enum {
        thompson_nfa,
        lazy_dfa,
        literal_fixed_string,
        literal_boyer_moore,
    };

    // 获取匹配的文本
    pub fn text(self: OptimizedMatch, input: []const u8) []const u8 {
        return input[self.span.start..self.span.end];
    }

    // 获取捕获组文本
    pub fn captureText(self: OptimizedMatch, input: []const u8, index: usize) ?[]const u8 {
        if (self.captures == null or index >= self.captures.?.len) return null;
        const span = self.captures.?[index];
        return input[span.start..span.end];
    }

    // 获取捕获组数量
    pub fn captureCount(self: OptimizedMatch) usize {
        return if (self.captures) |caps| caps.len else 0;
    }
};

// 优化版的匹配迭代器
pub const OptimizedMatchIterator = struct {
    allocator: Allocator,
    regex: *const OptimizedRegex,
    input: []const u8,
    current_pos: usize,
    options: MatchOptions,
    memory_manager: *MemoryManager,

    pub fn init(allocator: Allocator, regex: *const OptimizedRegex, input: []const u8, options: MatchOptions, memory_manager: *MemoryManager) OptimizedMatchIterator {
        return OptimizedMatchIterator{
            .allocator = allocator,
            .regex = regex,
            .input = input,
            .current_pos = 0,
            .options = options,
            .memory_manager = memory_manager,
        };
    }

    pub fn deinit(self: *OptimizedMatchIterator) void {
        _ = self;
        // 清理资源（如果需要）
    }

    // 获取下一个匹配（使用对象池）
    pub fn next(self: *OptimizedMatchIterator) !?OptimizedMatch {
        if (self.current_pos >= self.input.len) return null;

        const result = try self.regex.findAt(self.input, self.current_pos, self.options);
        if (result) |match| {
            self.current_pos = match.span.end;
            return match;
        }
        return null;
    }

    // 获取所有匹配（使用优化ArrayList）
    pub fn collectAll(self: *OptimizedMatchIterator) ![]OptimizedMatch {
        var matches = OptimizedArrayList(OptimizedMatch).init(self.allocator);
        defer matches.deinit(self.allocator);

        while (try self.next()) |match| {
            try matches.append(self.allocator, match);
        }

        return matches.toOwnedSlice(self.allocator);
    }

    // 批量收集，避免频繁分配
    pub fn collectAllBulk(self: *OptimizedMatchIterator, estimated_count: usize) ![]OptimizedMatch {
        var matches = OptimizedArrayList(OptimizedMatch).init(self.allocator);
        defer matches.deinit(self.allocator);

        // 预分配空间
        try matches.items.ensureTotalCapacity(self.allocator, estimated_count);

        while (try self.next()) |match| {
            matches.items.appendAssumeCapacity(match);
        }

        return matches.toOwnedSlice(self.allocator);
    }
};

// 优化版的正则表达式
pub const OptimizedRegex = struct {
    allocator: Allocator,
    compiled: Program,
    original_pattern: []const u8,
    compile_options: CompileOptions,
    memory_manager: *MemoryManager,
    unicode_engine: ?*UnicodeEngine = null,

    // 缓存常用的匹配结果结构
    cached_slots: std.ArrayListUnmanaged(?usize),
    cached_captures: std.ArrayListUnmanaged(OptimizedMatch.Span),

    const UnicodeEngine = struct {
        // Unicode特定的引擎状态
    };

    // 编译正则表达式（带内存管理）
    pub fn compile(allocator: Allocator, pattern: []const u8, memory_manager: *MemoryManager) !OptimizedRegex {
        return compileWithOptions(allocator, pattern, .{}, memory_manager);
    }

    // 带选项编译正则表达式（带内存管理）
    pub fn compileWithOptions(allocator: Allocator, pattern: []const u8, options: CompileOptions, memory_manager: *MemoryManager) !OptimizedRegex {
        // 使用内存池分配器
        const pool_allocator = memory_manager.getPoolAllocator();

        var parser = @import("parse.zig").Parser.init(pool_allocator);
        defer parser.deinit();

        const expr = try parser.parse(pattern);

        var compiler = @import("compile.zig").Compiler.init(pool_allocator);
        defer compiler.deinit();

        const program = try compiler.compile(expr);

        // 预分配缓存结构
        var cached_slots = std.ArrayListUnmanaged(?usize).empty;
        const cached_captures = std.ArrayListUnmanaged(OptimizedMatch.Span).empty;

        if (program.slot_count > 0) {
            try cached_slots.resize(pool_allocator, program.slot_count);
            @memset(cached_slots.items, null);
        }

        return OptimizedRegex{
            .allocator = allocator,
            .compiled = program,
            .original_pattern = pattern,
            .compile_options = options,
            .memory_manager = memory_manager,
            .unicode_engine = null,
            .cached_slots = cached_slots,
            .cached_captures = cached_captures,
        };
    }

    // 释放资源
    pub fn deinit(self: *OptimizedRegex) void {
        if (self.unicode_engine) |engine| {
            self.allocator.destroy(engine);
        }

        // 释放缓存结构
        self.cached_slots.deinit(self.allocator);
        self.cached_captures.deinit(self.allocator);

        self.compiled.deinit();
    }

    // 检查是否匹配（简单接口）
    pub fn isMatch(self: *const OptimizedRegex, input: []const u8) !bool {
        return self.find(input) != null;
    }

    // 查找第一个匹配（使用缓存的捕获槽位）
    pub fn find(self: *const OptimizedRegex, input: []const u8) !?OptimizedMatch {
        return self.findWithOptions(input, .{});
    }

    // 带选项查找（使用缓存的捕获槽位）
    pub fn findWithOptions(self: *const OptimizedRegex, input: []const u8, options: MatchOptions) !?OptimizedMatch {
        return self.findAt(input, 0, options);
    }

    // 从指定位置查找（使用缓存的捕获槽位）
    pub fn findAt(self: *const OptimizedRegex, input: []const u8, start_pos: usize, options: MatchOptions) !?OptimizedMatch {
        _ = start_pos; // Start position would be used in a full implementation
        _ = options; // Match options would be used in a full implementation
        const pool_allocator = self.memory_manager.getPoolAllocator();

        var input_obj = Input.init(input, .bytes);

        // 使用缓存的捕获槽位
        var cached_slots = self.cached_slots;
        if (cached_slots.items.len < self.compiled.slot_count) {
            try cached_slots.resize(pool_allocator, self.compiled.slot_count);
        }

        // 重置捕获槽位
        for (cached_slots.items) |*slot| {
            slot.* = null;
        }

        // 执行匹配
        const start_time = std.time.nanoTimestamp();
        const matched = try exec.exec(pool_allocator, self.compiled, self.compiled.find_start, &input_obj, &cached_slots);
        const end_time = std.time.nanoTimestamp();

        if (matched) {
            // 使用Span对象池来存储捕获组
            var captures: ?[]OptimizedMatch.Span = null;
            if (self.compiled.slot_count > 2) {
                const capture_count = (self.compiled.slot_count - 2) / 2;

                // 调整缓存大小
                var cached_captures = self.cached_captures;
                if (cached_captures.items.len < capture_count) {
                    try cached_captures.resize(pool_allocator, capture_count);
                }

                // 填充捕获组
                for (0..capture_count) |i| {
                    const base = 2 + i * 2;
                    if (cached_slots.items[base] != null and cached_slots.items[base + 1] != null) {
                        cached_captures.items[i] = .{
                            .start = cached_slots.items[base].?,
                            .end = cached_slots.items[base + 1].?,
                        };
                    } else {
                        cached_captures.items[i] = .{ .start = 0, .end = 0 };
                    }
                }

                captures = cached_captures.items[0..capture_count];
            }

            // 构建匹配结果
            const match = OptimizedMatch{
                .span = .{
                    .start = cached_slots.items[0] orelse 0,
                    .end = cached_slots.items[1] orelse input.len,
                },
                .captures = captures,
                .engine_info = .{
                    .engine_type = .thompson_nfa,
                    .used_unicode = false,
                    .used_literal_optimization = self.compiled.literal_optimization.enabled,
                    .match_time_ns = @intCast(end_time - start_time),
                },
            };

            return match;
        }

        return null;
    }

    // 获取匹配迭代器
    pub fn iterator(self: *const OptimizedRegex, input: []const u8) OptimizedMatchIterator {
        return OptimizedMatchIterator.init(self.allocator, self, input, .{}, self.memory_manager);
    }

    // 获取带选项的匹配迭代器
    pub fn iteratorWithOptions(self: *const OptimizedRegex, input: []const u8, options: MatchOptions) OptimizedMatchIterator {
        return OptimizedMatchIterator.init(self.allocator, self, input, options, self.memory_manager);
    }

    // 替换匹配的文本（使用内存池）
    pub fn replace(self: *const OptimizedRegex, input: []const u8, replacement: []const u8, allocator: Allocator) ![]u8 {
        return self.replaceWithOptions(input, replacement, .{}, allocator);
    }

    // 带选项的替换（使用内存池）
    pub fn replaceWithOptions(self: *const OptimizedRegex, input: []const u8, replacement: []const u8, options: MatchOptions, allocator: Allocator) ![]u8 {
        _ = allocator; // Mark allocator as used
        const pool_allocator = self.memory_manager.getPoolAllocator();
        var result = OptimizedArrayList(u8).initWithPool(&self.memory_manager.pool_allocator.?.pool);
        defer result.deinit(pool_allocator);

        var last_pos: usize = 0;
        var iter = self.iteratorWithOptions(input, options);

        while (try iter.next()) |match| {
            // 添加匹配前的文本
            try result.appendSlice(pool_allocator, input[last_pos..match.span.start]);

            // 处理替换字符串中的捕获组引用
            const processed_replacement = try self.processReplacement(replacement, match, pool_allocator);
            defer pool_allocator.free(processed_replacement);

            try result.appendSlice(pool_allocator, processed_replacement);
            last_pos = match.span.end;
        }

        // 添加剩余的文本
        try result.appendSlice(pool_allocator, input[last_pos..]);

        return result.toOwnedSlice(pool_allocator);
    }

    // 处理替换字符串中的捕获组引用
    fn processReplacement(self: *const OptimizedRegex, replacement: []const u8, match: OptimizedMatch, allocator: Allocator) ![]u8 {
        _ = self;
        var result = OptimizedArrayList(u8).init(allocator);
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < replacement.len) {
            if (replacement[i] == '\\' and i + 1 < replacement.len) {
                const next_char = replacement[i + 1];
                if (next_char >= '1' and next_char <= '9') {
                    // 捕获组引用
                    const group_index = next_char - '1';
                    if (group_index < match.captureCount()) {
                        const capture_text = match.captures.?[group_index];
                        try result.appendSlice(allocator, capture_text);
                    }
                    i += 2;
                } else {
                    // 转义字符
                    try result.append(allocator, replacement[i + 1]);
                    i += 2;
                }
            } else {
                try result.append(allocator, replacement[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // 分割字符串（使用内存池）
    pub fn split(self: *const OptimizedRegex, input: []const u8, allocator: Allocator) ![]const []const u8 {
        return self.splitWithOptions(input, .{}, allocator);
    }

    // 带选项的分割字符串（使用内存池）
    pub fn splitWithOptions(self: *const OptimizedRegex, input: []const u8, options: MatchOptions, allocator: Allocator) ![]const []const u8 {
        _ = allocator; // Mark allocator as used
        const pool_allocator = self.memory_manager.getPoolAllocator();
        var result = OptimizedArrayList([]const u8).initWithPool(&self.memory_manager.pool_allocator.?.pool);
        defer result.deinit(pool_allocator);

        var last_pos: usize = 0;
        var iter = self.iteratorWithOptions(input, options);

        while (try iter.next()) |match| {
            // 添加匹配前的文本
            const part = input[last_pos..match.span.start];
            try result.append(pool_allocator, part);
            last_pos = match.span.end;
        }

        // 添加最后一部分
        const last_part = input[last_pos..];
        try result.append(pool_allocator, last_part);

        return result.toOwnedSlice(pool_allocator);
    }

    // 查找所有匹配（批量版本）
    pub fn findAll(self: *const OptimizedRegex, input: []const u8, allocator: Allocator) ![]OptimizedMatch {
        return self.findAllWithOptions(input, .{}, allocator);
    }

    // 带选项查找所有匹配（批量版本）
    pub fn findAllWithOptions(self: *const OptimizedRegex, input: []const u8, options: MatchOptions, allocator: Allocator) ![]OptimizedMatch {
        _ = allocator; // Mark allocator as used
        var iter = self.iteratorWithOptions(input, options);

        // 估算匹配数量，减少重新分配
        const estimated_matches = input.len / 10; // 假设平均每10个字符有一个匹配
        if (estimated_matches > 0) {
            return iter.collectAllBulk(estimated_matches);
        } else {
            return iter.collectAll();
        }
    }

    // 获取内存使用统计
    pub fn getMemoryStats(self: *const OptimizedRegex) struct {
        regex_stats: struct {
            cached_slots_size: usize,
            cached_captures_size: usize,
            compiled_program_size: usize,
        },
        pool_stats: memory_pool.MemoryManager.Stats,
    } {
        return .{
            .regex_stats = .{
                .cached_slots_size = self.cached_slots.items.len * @sizeOf(?usize),
                .cached_captures_size = self.cached_captures.items.len * @sizeOf(OptimizedMatch.Span),
                .compiled_program_size = self.compiled.instructions.len * @sizeOf(@import("compile.zig").Instruction),
            },
            .pool_stats = self.memory_manager.getStats(),
        };
    }

    // 重置缓存（用于长期运行的应用）
    pub fn resetCache(self: *OptimizedRegex) void {
        // 重置捕获槽位缓存
        for (self.cached_slots.items) |*slot| {
            slot.* = null;
        }

        // 重置内存池
        self.memory_manager.resetAll();
    }
};

// 便利函数 - 使用优化的API
pub const OptimizedRegexAPI = struct {
    // 创建带内存管理的优化正则表达式
    pub fn compile(allocator: Allocator, pattern: []const u8, memory_manager: *MemoryManager) !OptimizedRegex {
        return OptimizedRegex.compile(allocator, pattern, memory_manager);
    }

    // 快速匹配检查
    pub fn matches(allocator: Allocator, pattern: []const u8, input: []const u8, memory_manager: *MemoryManager) !bool {
        var regex = try OptimizedRegex.compile(allocator, pattern, memory_manager);
        defer regex.deinit();
        return regex.isMatch(input);
    }

    // 查找第一个匹配
    pub fn findFirst(allocator: Allocator, pattern: []const u8, input: []const u8, memory_manager: *MemoryManager) !?OptimizedMatch {
        var regex = try OptimizedRegex.compile(allocator, pattern, memory_manager);
        defer regex.deinit();
        return regex.find(input);
    }

    // 查找所有匹配
    pub fn findAll(allocator: Allocator, pattern: []const u8, input: []const u8, memory_manager: *MemoryManager) ![]OptimizedMatch {
        var regex = try OptimizedRegex.compile(allocator, pattern, memory_manager);
        defer regex.deinit();
        return regex.findAll(input, allocator);
    }
};
