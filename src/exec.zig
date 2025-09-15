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
    nfa.setSlots(slots);

    // 执行匹配
    const matched = try nfa.execute(input, prog_start);

    // 如果匹配成功，更新捕获组信息
    if (matched) {
        const match_result = nfa.getMatchResult();
        // Ensure at least 2 slots for whole-match bounds
        if (slots.items.len < 2) try slots.resize(allocator, 2);

        // 如果slot 0和1没有被正确设置，尝试从捕获组或match_result推导
        if (slots.items[0] == null or slots.items[1] == null) {
            // 没有捕获组或slot未设置，使用match_result
            // 直接使用 Thompson NFA 提供的匹配结果
            // 但确保开始位置不大于结束位置
            if (match_result.start) |start| {
                if (match_result.end) |end| {
                    if (start <= end) {
                        slots.items[0] = start;
                        slots.items[1] = end;
                    } else {
                        // 如果开始位置大于结束位置，使用结束位置作为开始位置
                        slots.items[0] = end;
                        slots.items[1] = end;
                    }
                } else {
                    slots.items[0] = start;
                }
            } else if (match_result.end) |end| {
                slots.items[1] = end;
            }
        }

        // 验证所有捕获组的边界，确保开始位置不大于结束位置
        var capture_idx: usize = 0;
        while (capture_idx + 1 < slots.items.len) : (capture_idx += 2) {
            if (slots.items[capture_idx]) |start| {
                if (slots.items[capture_idx + 1]) |end| {
                    if (start > end) {
                        // 如果捕获组边界无效，清除这个捕获组
                        slots.items[capture_idx] = null;
                        slots.items[capture_idx + 1] = null;
                    }
                }
            }
        }
    }

    return matched;
}