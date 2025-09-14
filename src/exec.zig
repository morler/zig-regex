const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const compile = @import("compile.zig");
const Program = compile.Program;
const input_new = @import("input_new.zig");
const Input = input_new.Input;
const thompson_nfa = @import("thompson_nfa2.zig");
const ThompsonNfa = thompson_nfa.ThompsonNfa;

// 使用 Thompson NFA 引擎执行正则表达式匹配
pub fn exec(allocator: Allocator, prog: Program, prog_start: usize, input: *Input, slots: *ArrayList(?usize)) !bool {
    // 创建 Thompson NFA 引擎
    var nfa = try ThompsonNfa.init(allocator, &prog);
    defer nfa.deinit();

    // 准备捕获槽位供引擎写入
    // 确保 slots 的长度至少为程序需要的 slot_count
    if (slots.items.len < prog.slot_count) try slots.resize(allocator, prog.slot_count);
    // Initialize capture slots to null
    var i: usize = 0;
    while (i < slots.items.len) : (i += 1) {
        slots.items[i] = null;
    }
    nfa.setSlots(&slots.*);

    // 执行匹配
    const matched = try nfa.execute(input, prog_start);

    // 如果匹配成功，更新捕获组信息
    if (matched) {
        const match_result = nfa.getMatchResult();
        // Ensure at least 2 slots for whole-match bounds
        if (slots.items.len < 2) try slots.resize(allocator, 2);
        if (match_result.start) |start| slots.items[0] = start;
        if (match_result.end) |end| slots.items[1] = end;
    }

    return matched;
}
