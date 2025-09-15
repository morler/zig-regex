test "all" {
    _ = @import("range_set.zig");
    _ = @import("parse_test.zig");
    _ = @import("regex_test.zig");
    _ = @import("thompson_nfa2.zig");
    _ = @import("benchmark.zig");
    _ = @import("lazy_dfa_test.zig");
    _ = @import("utf8_test.zig");
}
