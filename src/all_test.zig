test "all" {
    _ = @import("range_set.zig");
    _ = @import("parse_test.zig");
    _ = @import("regex_test.zig");
    _ = @import("thompson_nfa.zig");
    _ = @import("benchmark.zig");
    // _ = @import("lazy_dfa_test.zig"); // 已删除 - 过度优化
    _ = @import("utf8_test.zig");
    _ = @import("unicode_regex_test.zig");
}
