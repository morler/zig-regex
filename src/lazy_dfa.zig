const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoHashMap = std.AutoHashMap;

const compile = @import("compile.zig");
const Program = compile.Program;
const Instruction = compile.Instruction;
const InstructionData = compile.InstructionData;

const input_new = @import("input_new.zig");
const Input = input_new.Input;

const bit_vector = @import("bit_vector.zig");
const BitVector = bit_vector.BitVector;

// DFA 状态标识符
const StateId = u32;

// 输入字符类标识符
const ClassId = u16;

// 锚点上下文
pub const AnchorCtx = struct {
    is_start: bool = true,
    is_end: bool = false,
    is_multiline: bool = false,
    prev_char: ?u8 = null,
    next_char: ?u8 = null,
};

// DFA 状态表示
pub const DfaState = struct {
    // 状态标识符
    id: StateId,
    // 该状态对应的 NFA 状态集合
    nfa_states: BitVector,
    // 是否为匹配状态
    is_match: bool,
    // 匹配长度（如果 is_match 为 true）
    match_len: ?usize = null,
    // 转移表 - 使用线性搜索的简单实现
    transitions: ArrayListUnmanaged(struct { class_id: ClassId, target_id: StateId }),
    // 默认转移（用于未分类的字符）
    default_transition: ?StateId = null,
    // 状态是否已被最小化
    minimized: bool = false,

    pub fn init(_: Allocator, id: StateId, nfa_states: BitVector) !DfaState {
        return DfaState{
            .id = id,
            .nfa_states = nfa_states,
            .is_match = false,
            .transitions = .{},
            .default_transition = null,
            .minimized = false,
        };
    }

    pub fn deinit(self: *DfaState, allocator: Allocator) void {
        self.nfa_states.deinit();
        self.transitions.deinit(allocator);
    }

    // 添加转移 - 检查是否已存在相同的转移
    pub fn addTransition(self: *DfaState, allocator: Allocator, class_id: ClassId, target_id: StateId) !void {
        // 检查是否已存在相同的转移
        for (self.transitions.items) |transition| {
            if (transition.class_id == class_id and transition.target_id == target_id) {
                // 已存在，不重复添加
                return;
            }
        }
        try self.transitions.append(allocator, .{ .class_id = class_id, .target_id = target_id });
    }

    // 设置默认转移
    pub fn setDefaultTransition(self: *DfaState, target_id: StateId) void {
        self.default_transition = target_id;
    }

    // 获取转移目标
    pub fn getTransition(self: *const DfaState, class_id: ClassId) ?StateId {
        for (self.transitions.items) |transition| {
            if (transition.class_id == class_id) {
                return transition.target_id;
            }
        }
        return null;
    }
};

// 字符类分类器
pub const CharClassifier = struct {
    // 字符到类的映射
    char_to_class: AutoHashMap(u8, ClassId),
    // 类到字符集合的映射
    class_to_chars: ArrayListUnmanaged(ArrayListUnmanaged(u8)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !CharClassifier {
        return CharClassifier{
            .char_to_class = AutoHashMap(u8, ClassId).init(allocator),
            .class_to_chars = ArrayListUnmanaged(ArrayListUnmanaged(u8)).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CharClassifier) void {
        self.char_to_class.deinit();
        for (self.class_to_chars.items) |*class_chars| {
            class_chars.deinit(self.allocator);
        }
        self.class_to_chars.deinit(self.allocator);
    }

    // 添加字符到分类
    pub fn addChar(self: *CharClassifier, char: u8, class_id: ClassId) !void {
        try self.char_to_class.put(char, class_id);

        // 确保类列表足够大
        while (self.class_to_chars.items.len <= class_id) {
            try self.class_to_chars.append(self.allocator, ArrayListUnmanaged(u8).empty);
        }

        // 添加字符到类
        try self.class_to_chars.items[class_id].append(self.allocator, char);
    }

    // 获取字符的类 ID
    pub fn getClassId(self: *const CharClassifier, char: u8) ?ClassId {
        return self.char_to_class.get(char);
    }

    // 获取类的所有字符
    pub fn getClassChars(self: *const CharClassifier, class_id: ClassId) ?[]const u8 {
        if (class_id >= self.class_to_chars.items.len) {
            return null;
        }
        return self.class_to_chars.items[class_id].items;
    }

    // 获取类的数量
    pub fn getClassCount(self: *const CharClassifier) usize {
        return self.class_to_chars.items.len;
    }
};

// DFA 缓存 LRU 实现
pub const DfaCache = struct {
    // 缓存节点
    const CacheNode = struct {
        state_id: StateId,
        nfa_states_hash: u64,
        prev: ?*CacheNode = null,
        next: ?*CacheNode = null,
    };

    // 缓存容量
    capacity: usize,
    // 当前大小
    size: usize,
    // NFA 状态哈希到 DFA 状态的映射
    state_map: AutoHashMap(u64, StateId),
    // LRU 链表头
    head: ?*CacheNode,
    // LRU 链表尾
    tail: ?*CacheNode,
    // 所有节点的内存池
    node_pool: ArrayListUnmanaged(CacheNode),
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !DfaCache {
        return DfaCache{
            .capacity = capacity,
            .size = 0,
            .state_map = AutoHashMap(u64, StateId).init(allocator),
            .head = null,
            .tail = null,
            .node_pool = ArrayListUnmanaged(CacheNode).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DfaCache) void {
        self.state_map.deinit();
        self.node_pool.deinit(self.allocator);
    }

    // 计算 NFA 状态集合的哈希值
    fn computeNfaStatesHash(nfa_states: *const BitVector) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const bits = nfa_states.getBits();
        for (bits) |bit| {
            hasher.update(std.mem.asBytes(&bit));
        }
        return hasher.final();
    }

    // 查找已存在的DFA状态
    pub fn findState(self: *DfaCache, nfa_states: *const BitVector) !?StateId {
        const hash = computeNfaStatesHash(nfa_states);

        // 检查是否已存在
        if (self.state_map.get(hash)) |existing_id| {
            // 更新 LRU
            self.moveToFront(existing_id);
            return existing_id;
        }

        return null;
    }

    // 获取或创建 DFA 状态
    pub fn getOrCreateState(self: *DfaCache, nfa_states: *const BitVector, state_id: StateId) !?StateId {
        const hash = computeNfaStatesHash(nfa_states);

        // 检查是否已存在
        if (self.state_map.get(hash)) |existing_id| {
            // 更新 LRU
            self.moveToFront(existing_id);
            return existing_id;
        }

        // 缓存已满，淘汰最旧的
        if (self.size >= self.capacity) {
            self.evict();
        }

        // 创建新节点
        const node = try self.node_pool.addOne(self.allocator);
        node.* = CacheNode{
            .state_id = state_id,
            .nfa_states_hash = hash,
            .prev = null,
            .next = self.head,
        };

        // 插入到链表头部
        if (self.head) |head| {
            head.prev = node;
        }
        self.head = node;
        if (self.tail == null) {
            self.tail = node;
        }

        // 添加到映射
        try self.state_map.put(hash, state_id);
        self.size += 1;

        return state_id;
    }

    // 移动节点到头部
    fn moveToFront(self: *DfaCache, state_id: StateId) void {
        // 查找节点
        var node = self.head;
        while (node) |n| {
            if (n.state_id == state_id) {
                // 已经在头部，无需移动
                if (n.prev == null) return;

                // 从当前位置移除
                if (n.prev) |prev| {
                    prev.next = n.next;
                }
                if (n.next) |next| {
                    next.prev = n.prev;
                } else {
                    self.tail = n.prev;
                }

                // 移动到头部
                n.prev = null;
                n.next = self.head;
                if (self.head) |head| {
                    head.prev = n;
                }
                self.head = n;

                return;
            }
            node = n.next;
        }
    }

    // 淘汰最旧的节点
    fn evict(self: *DfaCache) void {
        if (self.tail) |tail| {
            // 从映射中移除
            _ = self.state_map.remove(tail.nfa_states_hash);

            // 从链表中移除
            if (tail.prev) |prev| {
                prev.next = null;
            } else {
                self.head = null;
            }
            self.tail = tail.prev;

            self.size -= 1;
        }
    }

    // 清空缓存
    pub fn clear(self: *DfaCache) void {
        self.state_map.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.size = 0;
        self.node_pool.clearRetainingCapacity();
    }
};

// Lazy DFA 引擎主结构
pub const LazyDfa = struct {
    program: *const Program,
    allocator: Allocator,

    // DFA 状态存储
    states: ArrayListUnmanaged(DfaState),
    // 初始状态
    start_state: ?StateId = null,
    // 当前状态
    current_state: ?StateId = null,

    // 字符分类器
    classifier: CharClassifier,

    // DFA 缓存
    cache: DfaCache,

    // 临时工作空间
    scratch_space: ScratchSpace,

    // 统计信息
    stats: Stats,

    // 临时工作空间
    const ScratchSpace = struct {
        // 用于 epsilon 闭包计算的临时位向量
        closure_buffer: BitVector,
        // 用于字符转移计算的临时位向量
        transition_buffer: BitVector,
        // 用于状态合并的临时位向量
        merge_buffer: BitVector,

        pub fn init(allocator: Allocator, nfa_size: usize) !ScratchSpace {
            return ScratchSpace{
                .closure_buffer = try BitVector.init(allocator, nfa_size),
                .transition_buffer = try BitVector.init(allocator, nfa_size),
                .merge_buffer = try BitVector.init(allocator, nfa_size),
            };
        }

        pub fn deinit(self: *ScratchSpace) void {
            self.closure_buffer.deinit();
            self.transition_buffer.deinit();
            self.merge_buffer.deinit();
        }

        pub fn clear(self: *ScratchSpace) void {
            self.closure_buffer.clear();
            self.transition_buffer.clear();
            self.merge_buffer.clear();
        }
    };

    // 统计信息
    const Stats = struct {
        states_created: usize = 0,
        cache_hits: usize = 0,
        cache_misses: usize = 0,
        transitions_computed: usize = 0,
        memory_used: usize = 0,

        pub fn hitRate(self: *const Stats) f64 {
            const total = self.cache_hits + self.cache_misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total));
        }
    };

    pub fn init(allocator: Allocator, program: *const Program) !LazyDfa {
        const nfa_size = program.insts.len;

        return LazyDfa{
            .program = program,
            .allocator = allocator,
            .states = ArrayListUnmanaged(DfaState).empty,
            .classifier = try CharClassifier.init(allocator),
            .cache = try DfaCache.init(allocator, 1024), // 默认缓存 1024 个状态
            .scratch_space = try ScratchSpace.init(allocator, nfa_size),
            .stats = Stats{},
        };
    }

    pub fn deinit(self: *LazyDfa) void {
        for (self.states.items) |*state| {
            state.deinit(self.allocator);
        }
        self.states.deinit(self.allocator);
        self.classifier.deinit();
        self.cache.deinit();
        self.scratch_space.deinit();
    }

    // 初始化 DFA 引擎
    pub fn initialize(self: *LazyDfa) !void {
        // 1. 构建字符分类器
        try self.buildCharClassifier();

        // 2. 创建初始状态
        try self.createStartState();

        // 3. 设置当前状态
        self.current_state = self.start_state;
    }

    // 构建字符分类器
    fn buildCharClassifier(self: *LazyDfa) !void {
        var next_class_id: ClassId = 0;

        // 分析 NFA 程序中的所有字符类
        for (self.program.insts) |inst| {
            switch (inst.data) {
                .Char => |char| {
                    // 如果字符还没有分类，创建一个新类
                    if (self.classifier.getClassId(char) == null) {
                        try self.classifier.addChar(char, next_class_id);
                        next_class_id += 1;
                    }
                },
                .ByteClass => |byte_class| {
                    // 为字节类中的所有字符分配相同的类ID
                    var class_assigned = false;
                    for (byte_class.ranges.items) |range| {
                        var c = range.min;
                        while (c <= range.max) : (c += 1) {
                            if (self.classifier.getClassId(c) == null) {
                                try self.classifier.addChar(c, next_class_id);
                                class_assigned = true;
                            }
                        }
                    }
                    if (class_assigned) {
                        next_class_id += 1;
                    }
                },
                .AnyCharNotNL => {
                    // 除了换行符外的所有字符作为一类
                    for (0..255) |c| {
                        if (c != '\n' and self.classifier.getClassId(@as(u8, @intCast(c))) == null) {
                            try self.classifier.addChar(@as(u8, @intCast(c)), next_class_id);
                        }
                    }
                    if (self.classifier.getClassId('\n') == null) {
                        try self.classifier.addChar('\n', next_class_id + 1);
                    }
                    next_class_id += 2;
                },
                else => {},
            }
        }
    }

    // 创建初始状态
    fn createStartState(self: *LazyDfa) !void {
        // 计算初始状态的 epsilon 闭包
        const start_pc = self.program.start;
        std.debug.print("DFA createStartState: start_pc = {}\n", .{start_pc});
        try self.computeEpsilonClosure(start_pc, &self.scratch_space.closure_buffer);
        std.debug.print("DFA createStartState: epsilon closure contains states: ", .{});
        for (self.scratch_space.closure_buffer.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        std.debug.print("{} ", .{pc});
                    }
                }
            }
        }
        std.debug.print("\n", .{});

        // 创建 DFA 状态
        const state_id = @as(StateId, @intCast(self.states.items.len));
        var state = try DfaState.init(
            self.allocator,
            state_id,
            try self.scratch_space.closure_buffer.clone()
        );

        // 检查是否为匹配状态
        state.is_match = self.isMatchState(&state.nfa_states);

        try self.states.append(self.allocator, state);
        self.start_state = state_id;
        self.stats.states_created += 1;
    }

    // 计算 epsilon 闭包
    fn computeEpsilonClosure(self: *LazyDfa, start_pc: usize, result: *BitVector) !void {
        result.clear();

        var stack = ArrayListUnmanaged(usize).empty;
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, start_pc);
        result.set(start_pc);

        while (stack.items.len > 0) {
            const pc = stack.pop() orelse unreachable;
            const inst = &self.program.insts[pc];

            switch (inst.data) {
                .Split => |branch_pc| {
                    // 处理 Split 指令的两个分支
                    const first_pc = inst.out;
                    if (!result.get(first_pc)) {
                        try stack.append(self.allocator, first_pc);
                        result.set(first_pc);
                    }
                    if (!result.get(branch_pc)) {
                        try stack.append(self.allocator, branch_pc);
                        result.set(branch_pc);
                    }
                },
                .Jump => {
                    // 处理 Jump 指令
                    if (!result.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        result.set(inst.out);
                    }
                },
                .Save => {
                    // Save 指令不消耗输入，继续处理
                    if (!result.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        result.set(inst.out);
                    }
                },
                .EmptyMatch => {
                    // EmptyMatch 指令不消耗输入，继续处理
                    if (!result.get(inst.out)) {
                        try stack.append(self.allocator, inst.out);
                        result.set(inst.out);
                    }
                },
                else => {
                    // 其他指令（Char, ByteClass, AnyCharNotNL, Match）消耗输入，停止扩展
                },
            }
        }
    }

    // 检查是否为匹配状态
    fn isMatchState(self: *const LazyDfa, nfa_states: *const BitVector) bool {
        // 检查状态集合中是否包含 Match 指令
        for (nfa_states.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        if (pc < self.program.insts.len) {
                            const inst = &self.program.insts[pc];
                            if (inst.data == .Match) {
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    // 执行匹配
    pub fn execute(self: *LazyDfa, input: *Input) !bool {
        std.debug.print("DFA execute: current_state = {?}\n", .{self.current_state});
        if (self.current_state == null) {
            return false;
        }

        var current_pos: usize = 0;
        var state_id = self.current_state.?;

        std.debug.print("DFA execute: input length = {}\n", .{input.getLength()});

        while (current_pos < input.getLength()) {
            const char = input.at(current_pos);
            std.debug.print("DFA execute: pos={}, char='{}'\n", .{current_pos, char});

            // 获取字符类
            const class_id = self.classifier.getClassId(char) orelse {
                std.debug.print("DFA execute: char '{}' not classified\n", .{char});
                // 未分类的字符，尝试默认转移
                const state = &self.states.items[state_id];
                if (state.default_transition) |default_id| {
                    state_id = default_id;
                    current_pos += 1;
                    continue;
                } else {
                    return false;
                }
            };
            // 获取当前状态
            if (state_id >= self.states.items.len) {
                return false;
            }
            const state = &self.states.items[state_id];

            // 检查是否已有转移
            if (state.getTransition(class_id)) |next_id| {
                state_id = next_id;
                current_pos += 1;
                continue;
            }

            // 需要计算新的转移
            const next_id = try self.computeTransition(state_id, class_id);
            if (next_id == null) {
                return false;
            }

            state_id = next_id.?;
            current_pos += 1;
        }

        // 检查最终状态是否为匹配状态
        const final_state = &self.states.items[state_id];
        std.debug.print("DFA execute: final state_id = {}, is_match = {}\n", .{state_id, final_state.is_match});
        return final_state.is_match;
    }

    // 计算状态转移
    fn computeTransition(self: *LazyDfa, state_id: StateId, class_id: ClassId) !?StateId {
        if (state_id >= self.states.items.len) {
            return null;
        }
        const state = &self.states.items[state_id];
        self.scratch_space.transition_buffer.clear();

        // 对 NFA 状态集合中的每个状态计算字符转移
        for (state.nfa_states.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        if (pc < self.program.insts.len) {
                            const inst = &self.program.insts[pc];
                            std.debug.print("DFA computeTransition: processing inst {} at pc {}\n", .{inst.data, pc});
                            try self.applyCharTransition(inst, class_id, &self.scratch_space.transition_buffer);
                        }
                    }
                }
            }
        }

        // Debug: 打印字符转移结果
        std.debug.print("DFA computeTransition: transition buffer after char transitions: ", .{});
        for (self.scratch_space.transition_buffer.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        std.debug.print("{} ", .{pc});
                    }
                }
            }
        }
        std.debug.print("\n", .{});

        // 计算转移后状态集合的 epsilon 闭包
        self.scratch_space.merge_buffer.clear();

        for (self.scratch_space.transition_buffer.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        try self.computeEpsilonClosure(pc, &self.scratch_space.merge_buffer);
                    }
                }
            }
        }

        // Debug: 打印最终 epsilon 闭包结果
        std.debug.print("DFA computeTransition: final epsilon closure: ", .{});
        for (self.scratch_space.merge_buffer.getBits(), 0..) |bit_word, bit_index| {
            if (bit_word != 0) {
                for (0..64) |bit_idx| {
                    const bit_offset: u6 = @intCast(bit_idx);
                    if ((bit_word & (@as(u64, 1) << bit_offset)) != 0) {
                        const pc = bit_index * 64 + bit_offset;
                        std.debug.print("{} ", .{pc});
                    }
                }
            }
        }

        // 检查缓存是否已有相同NFA状态集的DFA状态
        const cached_id = self.cache.findState(&self.scratch_space.merge_buffer) catch null;
        if (cached_id) |id| {
                    self.stats.cache_hits += 1;
            try state.addTransition(self.allocator, class_id, id);
            return id;
        }

        self.stats.cache_misses += 1;

        // 创建新状态 - 添加安全检查防止无限状态创建
        if (self.states.items.len >= 1000) {
            std.debug.print("DFA computeTransition: too many states created, potential infinite loop\n", .{});
            return error.TooManyStates;
        }
        const new_state_id = @as(StateId, @intCast(self.states.items.len));
        var new_state = try DfaState.init(
            self.allocator,
            new_state_id,
            try self.scratch_space.merge_buffer.clone()
        );

        new_state.is_match = self.isMatchState(&new_state.nfa_states);

        try self.states.append(self.allocator, new_state);
        // 重新获取state指针，因为append可能重新分配了内存
        const state_ptr = &self.states.items[state_id];
        try state_ptr.addTransition(self.allocator, class_id, new_state_id);

        // 将新状态添加到缓存
        _ = self.cache.getOrCreateState(&self.scratch_space.merge_buffer, new_state_id) catch {};

        self.stats.states_created += 1;
        self.stats.transitions_computed += 1;

        std.debug.print("DFA computeTransition: returning new_state_id={}\n", .{new_state_id});
        return new_state_id;
    }

    // 应用字符转移
    fn applyCharTransition(self: *LazyDfa, inst: *const Instruction, class_id: ClassId, result: *BitVector) !void {
        switch (inst.data) {
            .Char => |char| {
                if (self.classifier.getClassId(char)) |char_class_id| {
                    if (char_class_id == class_id) {
                        result.set(inst.out);
                    }
                }
            },
            .ByteClass => |byte_class| {
                // 检查字符是否在字节类中
                for (byte_class.ranges.items) |range| {
                    var c = range.min;
                    while (c <= range.max) : (c += 1) {
                        if (self.classifier.getClassId(c)) |char_class_id| {
                            if (char_class_id == class_id) {
                                result.set(inst.out);
                                break;
                            }
                        }
                    }
                }
            },
            .AnyCharNotNL => {
                // 任何非换行符都匹配
                const nl_class_id = self.classifier.getClassId('\n') orelse 256;
                if (class_id != nl_class_id) {
                    result.set(inst.out);
                }
            },
            else => {},
        }
    }

    // 获取统计信息
    pub fn getStats(self: *const LazyDfa) Stats {
        return self.stats;
    }

    // 重置到初始状态
    pub fn reset(self: *LazyDfa) void {
        self.current_state = self.start_state;
        self.cache.clear();
        self.scratch_space.clear();
    }
};

// 测试函数
pub fn testBasic() !void {
    const allocator = std.testing.allocator;

    // 创建简单的测试程序
    var program = try createTestProgram(allocator);
    defer program.deinit();

    // 创建 Lazy DFA
    var dfa = try LazyDfa.init(allocator, &program);
    defer dfa.deinit();

    // 初始化
    try dfa.initialize();

    // 测试匹配
    const test_input = "hello";
    var input = try input_new.Input.fromSlice(allocator, test_input);
    defer input.deinit();

    const result = try dfa.execute(&input);
    std.debug.print("Match result: {}\n", .{result});

    // 打印统计信息
    const stats = dfa.getStats();
    std.debug.print("States created: {}\n", .{stats.states_created});
    std.debug.print("Cache hit rate: {d:.2}%\n", .{stats.hitRate() * 100.0});
}

// 创建测试程序
fn createTestProgram(allocator: Allocator) !Program {
    // 创建匹配 "hello" 的简单程序
    var insts = try allocator.alloc(compile.Instruction, 7);
    errdefer allocator.free(insts);

    insts[0] = compile.Instruction.new(1, compile.InstructionData{ .Char = 'h' });
    insts[1] = compile.Instruction.new(2, compile.InstructionData{ .Char = 'e' });
    insts[2] = compile.Instruction.new(3, compile.InstructionData{ .Char = 'l' });
    insts[3] = compile.Instruction.new(4, compile.InstructionData{ .Char = 'l' });
    insts[4] = compile.Instruction.new(5, compile.InstructionData{ .Char = 'o' });
    insts[5] = compile.Instruction.new(6, compile.InstructionData{ .Save = 0 });
    insts[6] = compile.Instruction.new(0, compile.InstructionData.Match);

    return Program.init(allocator, insts, 0, 2);
}