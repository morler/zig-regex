const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const compile = @import("compile.zig");
const Program = compile.Program;
const input_new = @import("input_new.zig");
const Input = input_new.Input;

// TODO: Implement new Thompson NFA engine
// This is a placeholder until the new engine is implemented
pub fn exec(allocator: Allocator, prog: Program, prog_start: usize, input: *Input, slots: *ArrayList(?usize)) !bool {
    _ = allocator;
    _ = prog;
    _ = prog_start;
    _ = input;
    _ = slots;
    @panic("exec function not implemented - Thompson NFA engine needs to be implemented");
}
