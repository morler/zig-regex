const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const debug = std.debug;

const parser = @import("parse.zig");
const Parser = parser.Parser;
const ByteClass = parser.ByteClass;
const Expr = parser.Expr;
const Assertion = parser.Assertion;

const literal_extractor = @import("literal_extractor.zig");
const LiteralAnalyzer = literal_extractor.LiteralAnalyzer;
const LiteralInfo = literal_extractor.LiteralInfo;
const LiteralMatcher = literal_extractor.LiteralMatcher;

pub const InstructionData = union(enum) {
    Char: u8,
    ByteClass: ByteClass,
    AnyCharNotNL,
    EmptyMatch: Assertion,
    Match,
    Jump,
    Split: usize,
    Save: usize,
};

pub const Instruction = struct {
    out: usize,
    data: InstructionData,

    pub fn new(out: usize, data: InstructionData) Instruction {
        return Instruction{
            .out = out,
            .data = data,
        };
    }
};

const InstHole = union(enum) {
    Char: u8,
    ByteClass: ByteClass,
    EmptyMatch: Assertion,
    AnyCharNotNL,
    Split,
    Split1: usize,
    Split2: usize,
    Save: usize,
};

const PartialInst = union(enum) {
    Compiled: Instruction,
    Uncompiled: InstHole,

    pub fn fill(s: *PartialInst, i: usize) void {
        switch (s.*) {
            PartialInst.Uncompiled => |ih| {
                const compiled = switch (ih) {
                    InstHole.Char => |ch| Instruction.new(i, InstructionData{ .Char = ch }),

                    InstHole.EmptyMatch => |assertion| Instruction.new(i, InstructionData{ .EmptyMatch = assertion }),

                    InstHole.AnyCharNotNL => Instruction.new(i, InstructionData.AnyCharNotNL),

                    InstHole.ByteClass => |class| Instruction.new(i, InstructionData{ .ByteClass = class }),

                    InstHole.Split => Instruction.new(i, InstructionData.Jump),
                    InstHole.Split1 => |split| Instruction.new(split, InstructionData{ .Split = i }),
                    InstHole.Split2 => |split| Instruction.new(i, InstructionData{ .Split = split }),

                    InstHole.Save => |slot| Instruction.new(i, InstructionData{ .Save = slot }),
                };

                s.* = PartialInst{ .Compiled = compiled };
            },
            PartialInst.Compiled => {},
        }
    }
};

pub const Program = struct {
    insts: []Instruction,
    start: usize,
    find_start: usize,
    slot_count: usize,
    allocator: Allocator,

    // Literal fast path fields
    is_literal: bool = false,
    literal: []const u8 = "",

    pub fn init(allocator: Allocator, a: []Instruction, find_start: usize, slot_count: usize) Program {
        return Program{
            .allocator = allocator,
            .insts = a,
            .start = 0,
            .find_start = find_start,
            .slot_count = slot_count,
        };
    }

    pub fn initLiteral(allocator: Allocator, literal: []const u8) !Program {
        const literal_copy = try allocator.dupe(u8, literal);
        return Program{
            .allocator = allocator,
            .insts = &[_]Instruction{}, // Empty instructions for literals
            .start = 0,
            .find_start = 0,
            .slot_count = 2, // For start/end capture
            .is_literal = true,
            .literal = literal_copy,
        };
    }

    pub fn deinit(p: *Program) void {
        if (p.is_literal) {
            p.allocator.free(p.literal);
        } else {
            for (p.insts) |*inst| {
                switch (inst.data) {
                    .ByteClass => |*bc| {
                        bc.deinit(p.allocator);
                    },
                    else => {},
                }
            }
            p.allocator.free(p.insts);
        }
    }
};

const Hole = union(enum) {
    None,
    One: usize,
    Many: ArrayList(Hole),
};

const Patch = struct {
    entry: usize,
    hole: Hole,
};

pub const Compiler = struct {
    insts: ArrayList(PartialInst),
    allocator: Allocator,
    capture_index: usize,

    pub fn init(a: Allocator) Compiler {
        return Compiler{
            .insts = ArrayListUnmanaged(PartialInst).empty,
            .allocator = a,
            .capture_index = 0,
        };
    }

    pub fn deinit(c: *Compiler) void {
        c.insts.deinit(c.allocator);
    }

    fn nextCaptureIndex(c: *Compiler) usize {
        const s = c.capture_index;
        c.capture_index += 2;
        return s;
    }

    // Compile the regex expression
    pub fn compile(c: *Compiler, expr: *const Expr) !Program {
        // Fast path: check if this is a simple literal
        var analyzer = LiteralAnalyzer.init(c.allocator);
        defer analyzer.deinit();

        var literal_info = try analyzer.analyze(expr);
        defer literal_info.deinit(c.allocator);

        if (literal_info.is_literal) {
            return Program.initLiteral(c.allocator, literal_info.literal);
        }

        // surround in a full program match
        const entry = c.insts.items.len;
        const index = c.nextCaptureIndex();
        try c.pushCompiled(Instruction.new(entry + 1, InstructionData{ .Save = index }));

        // compile the main expression
        const patch = try c.compileInternal(expr);

        c.fillToNext(patch.hole);
        const h = try c.pushHole(InstHole{ .Save = index + 1 });

        // fill any holes to end at the next instruction which will be a match
        c.fillToNext(h);
        try c.pushCompiled(Instruction.new(0, InstructionData.Match));

        var p = ArrayListUnmanaged(Instruction).empty;
        defer p.deinit(c.allocator);

        for (c.insts.items) |e| {
            switch (e) {
                PartialInst.Compiled => |x| {
                    try p.append(c.allocator, x);
                },
                else => |_| {
                    @panic("uncompiled instruction encountered during compilation");
                },
            }
        }

        // To facilitate fast finding (matching non-anchored to the start) we simply append a
        // .*? to the start of our instructions. We push the fragment with this set of instructions
        // at the end of the compiled set. We perform an anchored search by entering normally and
        // a non-anchored by jumping to this patch before starting.
        //
        // 1: compiled instructions
        // 2: match
        // ... # We add the following
        // 3: split 1, 4
        // 4: any 3
        const fragment_start = c.insts.items.len;
        const fragment = [_]Instruction{
            // Split to main program (pc 0) and to the scanner (fragment_start + 1)
            Instruction.new(0, InstructionData{ .Split = fragment_start + 1 }),
            // Any char, jump back to split
            Instruction.new(fragment_start, InstructionData.AnyCharNotNL),
        };
        try p.appendSlice(c.allocator, &fragment);

        const program = Program.init(c.allocator, try p.toOwnedSlice(c.allocator), fragment_start, c.capture_index);

        return program;
    }

    fn compileInternal(c: *Compiler, expr: *const Expr) Allocator.Error!Patch {
        switch (expr.*) {
            Expr.Literal => |lit| {
                const h = try c.pushHole(InstHole{ .Char = lit });
                return Patch{ .hole = h, .entry = c.insts.items.len - 1 };
            },
            Expr.ByteClass => |classes| {
                // Similar, we use a special instruction.
                const h = try c.pushHole(InstHole{ .ByteClass = try classes.dupe(c.allocator) });
                return Patch{ .hole = h, .entry = c.insts.items.len - 1 };
            },
            Expr.AnyCharNotNL => {
                const h = try c.pushHole(InstHole.AnyCharNotNL);
                return Patch{ .hole = h, .entry = c.insts.items.len - 1 };
            },
            Expr.EmptyMatch => |assertion| {
                const h = try c.pushHole(InstHole{ .EmptyMatch = assertion });
                return Patch{ .hole = h, .entry = c.insts.items.len - 1 };
            },
            Expr.Repeat => |repeat| {
                // Case 1: *
                if (repeat.min == 0 and repeat.max == null) {
                    return c.compileStar(repeat.subexpr, repeat.greedy);
                }
                // Case 2: +
                else if (repeat.min == 1 and repeat.max == null) {
                    return c.compilePlus(repeat.subexpr, repeat.greedy);
                }
                // Case 3: ?
                else if (repeat.min == 0 and repeat.max != null and repeat.max.? == 1) {
                    return c.compileQuestion(repeat.subexpr, repeat.greedy);
                }
                // Case 4: {m,}
                else if (repeat.max == null) {
                    // e{2,} => eee*
                    // fixed min concatenation
                    const p = try c.compileInternal(repeat.subexpr);
                    var hole = p.hole;
                    const entry = p.entry;

                    var i: usize = 1;
                    while (i < repeat.min) : (i += 1) {
                        var new_subexpr = try repeat.subexpr.clone(c.allocator);
                        defer new_subexpr.deinit(c.allocator);
                        const ep = try c.compileInternal(&new_subexpr);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    // add final e* infinite capture
                    var new_subexpr = try repeat.subexpr.clone(c.allocator);
                    defer new_subexpr.deinit(c.allocator);
                    const st = try c.compileStar(&new_subexpr, repeat.greedy);
                    c.fill(hole, st.entry);

                    return Patch{ .hole = st.hole, .entry = entry };
                }
                // Case 5: {m,n} and {m}
                else {
                    // e{3,6} => eee?e?e?e?
                    const p = try c.compileInternal(repeat.subexpr);
                    var hole = p.hole;
                    const entry = p.entry;

                    var i: usize = 1;
                    while (i < repeat.min) : (i += 1) {
                        var new_subexpr = try repeat.subexpr.clone(c.allocator);
                        defer new_subexpr.deinit(c.allocator);
                        const ep = try c.compileInternal(&new_subexpr);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    // repeated optional concatenations
                    while (i < repeat.max.?) : (i += 1) {
                        var new_subexpr = try repeat.subexpr.clone(c.allocator);
                        defer new_subexpr.deinit(c.allocator);
                        const ep = try c.compileQuestion(&new_subexpr, repeat.greedy);
                        c.fill(hole, ep.entry);
                        hole = ep.hole;
                    }

                    return Patch{ .hole = hole, .entry = entry };
                }
            },
            Expr.Concat => |subexprs| {
                // Compile each item in the sub-expression
                const f = subexprs.items[0];

                // First patch
                const p = try c.compileInternal(f);
                var hole = p.hole;
                const entry = p.entry;

                // tie together patches from concat arguments
                for (subexprs.items[1..]) |e| {
                    const ep = try c.compileInternal(e);
                    // fill the previous patch hole to the current entry
                    c.fill(hole, ep.entry);
                    // current hole is now the next fragment
                    hole = ep.hole;
                }

                return Patch{ .hole = hole, .entry = entry };
            },
            Expr.Capture => |subexpr| {
                // 1: save 1, 2
                // 2: subexpr
                // 3: restore 1, 4
                // ...

                // Create a partial instruction with a hole outgoing at the current location.
                const entry = c.insts.items.len;

                const index = c.nextCaptureIndex();

                try c.pushCompiled(Instruction.new(entry + 1, InstructionData{ .Save = index }));
                const p = try c.compileInternal(subexpr);
                c.fillToNext(p.hole);

                const h = try c.pushHole(InstHole{ .Save = index + 1 });

                return Patch{ .hole = h, .entry = entry };
            },
            Expr.Alternate => |subexprs| {
                // Alternation with one path does not make sense
                debug.assert(subexprs.items.len >= 2);

                // Alternates are simply a series of splits into the sub-expressions, with each
                // subexpr having the same output hole (after the final subexpr).
                //
                // 1: split 2, 4
                // 2: subexpr1
                // 3: jmp 8
                // 4: split 5, 7
                // 5: subexpr2
                // 6: jmp 8
                // 7: subexpr3
                // 8: ...

                const entry = c.insts.items.len;
                var holes = ArrayListUnmanaged(Hole).empty;
                errdefer holes.deinit(c.allocator);

                var last_hole: Hole = .None;

                // This compiles one branch of the split at a time.
                for (subexprs.items[0 .. subexprs.items.len - 1]) |subexpr| {
                    c.fillToNext(last_hole);

                    // next entry will be a sub-expression
                    //
                    // We fill the second part of this hole on the next sub-expression.
                    last_hole = try c.pushHole(InstHole{ .Split1 = c.insts.items.len + 1 });

                    // compile the subexpression
                    const p = try c.compileInternal(subexpr);

                    // store outgoing hole for the subexpression
                    try holes.append(c.allocator, p.hole);
                }

                // one entry left, push a sub-expression so we end with a double-subexpression.
                const p = try c.compileInternal(subexprs.items[subexprs.items.len - 1]);
                c.fill(last_hole, p.entry);

                // push the last sub-expression hole
                try holes.append(c.allocator, p.hole);

                // return many holes which are all to be filled to the next instruction
                return Patch{ .hole = Hole{ .Many = holes }, .entry = entry };
            },
            Expr.PseudoLeftParen => {
                @panic("internal error, encountered PseudoLeftParen");
            },
        }

        return Patch{ .hole = Hole.None, .entry = c.insts.items.len };
    }

    fn compileStar(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: split 2, 4
        // 2: subexpr
        // 3: jmp 1
        // 4: ...

        // We do not know where the second branch in this split will go (unsure yet of
        // the length of the following subexpr. Need a hole.

        // Create a partial instruction with a hole outgoing at the current location.
        const entry = c.insts.items.len;

        // * or *? variant, simply switch the branches, the matcher manages precedence
        // of the executing threads.
        const partial_inst = if (greedy)
            InstHole{ .Split1 = c.insts.items.len + 1 }
        else
            InstHole{ .Split2 = c.insts.items.len + 1 };

        const h = try c.pushHole(partial_inst);

        // compile the subexpression
        const p = try c.compileInternal(expr);

        // sub-expression to jump
        c.fillToNext(p.hole);

        // Jump back to the entry split
        try c.pushCompiled(Instruction.new(entry, InstructionData.Jump));

        // Return a filled patch set to the first split instruction.
        return Patch{ .hole = h, .entry = entry };
    }

    fn compilePlus(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: subexpr
        // 2: split 1, 3
        // 3: ...
        //
        // NOTE: We can do a lookahead on non-greedy here to improve performance.
        const p = try c.compileInternal(expr);

        // Create the next expression in place
        c.fillToNext(p.hole);

        // split 3, 1 (non-greedy)
        // Point back to the upcoming next instruction (will always be filled).
        const partial_inst = if (greedy)
            InstHole{ .Split1 = p.entry }
        else
            InstHole{ .Split2 = p.entry };

        const h = try c.pushHole(partial_inst);

        // split to the next instruction
        return Patch{ .hole = h, .entry = p.entry };
    }

    fn compileQuestion(c: *Compiler, expr: *Expr, greedy: bool) !Patch {
        // 1: split 2, 3

        // 2: subexpr
        // 3: ...

        // Create a partial instruction with a hole outgoing at the current location.
        const partial_inst = if (greedy)
            InstHole{ .Split1 = c.insts.items.len + 1 }
        else
            InstHole{ .Split2 = c.insts.items.len + 1 };

        const h = try c.pushHole(partial_inst);

        // compile the subexpression
        const p = try c.compileInternal(expr);

        var holes = ArrayListUnmanaged(Hole).empty;
        errdefer holes.deinit(c.allocator);
        try holes.append(c.allocator, h);
        try holes.append(c.allocator, p.hole);

        // Return a filled patch set to the first split instruction.
        return Patch{ .hole = Hole{ .Many = holes }, .entry = p.entry - 1 };
    }

    // Push a compiled instruction directly onto the stack.
    fn pushCompiled(c: *Compiler, i: Instruction) !void {
        try c.insts.append(c.allocator, PartialInst{ .Compiled = i });
    }

    // Push a instruction with a hole onto the set
    fn pushHole(c: *Compiler, i: InstHole) !Hole {
        const h = c.insts.items.len;
        try c.insts.append(c.allocator, PartialInst{ .Uncompiled = i });
        return Hole{ .One = h };
    }

    // Patch an individual hole with the specified output address.
    fn fill(c: *Compiler, hole: Hole, goto1: usize) void {
        switch (hole) {
            Hole.None => {},
            Hole.One => |pc| c.insts.items[pc].fill(goto1),
            Hole.Many => |holes| {
                for (holes.items) |hole1|
                    c.fill(hole1, goto1);
                @constCast(&holes).deinit(c.allocator);
            },
        }
    }

    // Patch a hole to point to the next instruction
    fn fillToNext(c: *Compiler, hole: Hole) void {
        c.fill(hole, c.insts.items.len);
    }

};

// Direct compiler that combines parsing and compilation for better performance
pub const DirectCompiler = struct {
    insts: ArrayListUnmanaged(PartialInst),
    allocator: Allocator,
    capture_index: usize,
    pos: usize,
    pattern: []const u8,

    pub fn init(allocator: Allocator) DirectCompiler {
        return DirectCompiler{
            .insts = ArrayListUnmanaged(PartialInst).empty,
            .allocator = allocator,
            .capture_index = 0,
            .pos = 0,
            .pattern = "",
        };
    }

    pub fn deinit(self: *DirectCompiler) void {
        self.insts.deinit(self.allocator);
    }

    pub fn compilePattern(allocator: Allocator, pattern: []const u8) !Program {
        // Fast path: check if this is a simple literal pattern
        var analyzer = LiteralAnalyzer.init(allocator);
        defer analyzer.deinit();

        var literal_info = try analyzer.analyzePattern(pattern);
        defer literal_info.deinit(allocator);

        if (literal_info.is_literal) {
            return Program.initLiteral(allocator, literal_info.literal);
        }

        var compiler = DirectCompiler.init(allocator);
        defer compiler.deinit();

        compiler.pattern = pattern;

        // Directly compile the pattern without intermediate AST
        try compiler.compileRegexPattern();

        return compiler.buildProgram();
    }

    fn compileRegexPattern(self: *DirectCompiler) !void {
        const entry = self.insts.items.len;
        const index = self.nextCaptureIndex();
        try self.pushCompiled(Instruction.new(entry + 1, InstructionData{ .Save = index }));

        // Parse and compile directly
        const patch = try self.compileExpression();

        self.fillToNext(patch.hole);
        const h = try self.pushHole(InstHole{ .Save = index + 1 });

        self.fillToNext(h);
        try self.pushCompiled(Instruction.new(0, InstructionData.Match));
    }

    fn compileExpression(self: *DirectCompiler) !Patch {
        // Simple implementation for basic regex patterns
        // This would be expanded to handle all regex features
        if (self.pos >= self.pattern.len) {
            return Patch{ .hole = Hole.None, .entry = self.insts.items.len };
        }

        const ch = self.pattern[self.pos];
        self.pos += 1;

        switch (ch) {
            '.' => {
                const h = try self.pushHole(InstHole.AnyCharNotNL);
                return Patch{ .hole = h, .entry = self.insts.items.len - 1 };
            },
            '*' => {
                // Handle repetition
                if (self.pos > 0) {
                    self.pos -= 1; // Backtrack to get the character to repeat
                    return self.compileRepeat();
                }
                return error.InvalidRegex;
            },
            else => {
                const h = try self.pushHole(InstHole{ .Char = ch });
                return Patch{ .hole = h, .entry = self.insts.items.len - 1 };
            }
        }
    }

    fn compileRepeat(self: *DirectCompiler) !Patch {
        if (self.pos >= self.pattern.len) return error.InvalidRegex;

        const ch = self.pattern[self.pos];
        self.pos += 1; // Skip the character
        self.pos += 1; // Skip the '*' operator

        // Implement greedy * quantifier
        _ = try self.pushHole(InstHole.Split);
        _ = try self.pushHole(InstHole{ .Char = ch });
        const jump_hole = try self.pushHole(InstHole{ .Split1 = self.insts.items.len - 2 });

        return Patch{ .hole = jump_hole, .entry = self.insts.items.len - 1 };
    }

    fn nextCaptureIndex(self: *DirectCompiler) usize {
        const s = self.capture_index;
        self.capture_index += 2;
        return s;
    }

    fn pushCompiled(self: *DirectCompiler, inst: Instruction) !void {
        try self.insts.append(self.allocator, PartialInst{ .Compiled = inst });
    }

    fn pushHole(self: *DirectCompiler, hole: InstHole) !Hole {
        try self.insts.append(self.allocator, PartialInst{ .Uncompiled = hole });
        return Hole{ .One = self.insts.items.len - 1 };
    }

    fn fillToNext(self: *DirectCompiler, hole: Hole) void {
        const next_idx = self.insts.items.len;
        switch (hole) {
            Hole.None => {},
            Hole.One => |pc| self.insts.items[pc].fill(next_idx),
            Hole.Many => |holes| {
                for (holes.items) |hole1|
                    self.fillToNext(hole1);
                @constCast(&holes).deinit(self.allocator);
            },
        }
    }

    fn buildProgram(self: *DirectCompiler) !Program {
        var p = ArrayListUnmanaged(Instruction).empty;
        defer p.deinit(self.allocator);

        for (self.insts.items) |e| {
            switch (e) {
                PartialInst.Compiled => |x| {
                    try p.append(self.allocator, x);
                },
                PartialInst.Uncompiled => |h| {
                    // Convert holes to compiled instructions
                    const inst = self.holeToInstruction(h, self.insts.items.len);
                    try p.append(self.allocator, inst);
                },
            }
        }

        const fragment_start = if (p.items.len > 0) p.items.len - 1 else 0;
        return Program.init(self.allocator, try p.toOwnedSlice(self.allocator), fragment_start, self.capture_index);
    }

    fn holeToInstruction(self: *DirectCompiler, hole: InstHole, next_pos: usize) Instruction {
        _ = self; // Mark as used
        return switch (hole) {
            .Char => |ch| Instruction.new(next_pos, InstructionData{ .Char = ch }),
            .ByteClass => |classes| Instruction.new(next_pos, InstructionData{ .ByteClass = classes }),
            .AnyCharNotNL => Instruction.new(next_pos, InstructionData.AnyCharNotNL),
            .EmptyMatch => |assertion| Instruction.new(next_pos, InstructionData{ .EmptyMatch = assertion }),
            .Split => Instruction.new(next_pos, InstructionData{ .Split = next_pos + 1 }),
            .Split1 => |target| Instruction.new(target, InstructionData{ .Split = next_pos }),
            .Split2 => |target| Instruction.new(target, InstructionData{ .Split = next_pos - 1 }),
            .Save => |idx| Instruction.new(next_pos, InstructionData{ .Save = idx }),
        };
    }
};
