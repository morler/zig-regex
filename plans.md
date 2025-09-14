# Zig Regex 引擎重构开发计划

## 项目概述

当前 zig-regex 项目存在严重的性能和架构问题。本重构计划旨在彻底重写正则表达式引擎，采用现代多层架构，实现与 Rust regex 相当的性能水平。

## 当前问题分析

### 1. 架构问题
- **双引擎设计**：回溯引擎和 PikeVM 并存，增加复杂度
- **引擎选择逻辑**：基于简单启发式算法，分支预测失败率高
- **无优化层**：缺少字面量优化、DFA 缓存等关键优化

### 2. 性能问题
- **动态分配频繁**：PikeVM 每轮都重新分配 ArrayList
- **函数指针开销**：Input 抽象层使用函数指针，性能极差
- **内存效率低**：回溯引擎固定大小 bitset 浪费内存

### 3. 功能缺失
- **无 UTF-8 支持**：仅支持 ASCII 字符
- **无字面量优化**：缺少 Boyer-Moore、Aho-Corasick 等算法
- **无 DFA 支持**：无法实现接近 O(1) 的匹配性能

## 重构目标

### 性能目标
- 简单正则表达式匹配性能提升 100-1000 倍
- 复杂正则表达式保持线性时间复杂度
- 内存使用效率提升 10-50 倍
- 编译时间优化 50-80%

### 功能目标
- 完整的 UTF-8 支持
- 多层优化架构（字面量 → Lazy DFA → Thompson NFA）
- 支持所有标准正则表达式特性
- 提供同步和异步 API

### 架构目标
- 单一、清晰的引擎架构
- 零动态分配的热路径
- 编译时多态替代运行时多态
- 模块化设计，易于测试和维护

## 重构架构设计

### 多层引擎架构

```
Regex API (用户接口)
    ↓
Meta Engine (自动选择最优策略)
    ↓
┌─────────────────────────────────────┐
│           Optimization Layer          │
├─────────────────┬───────────────────┤
│ Literal Engine  │  Lazy DFA Engine  │
│ (Boyer-Moore,   │  (缓存 DFA 状态)   │
│  Aho-Corasick)  │                   │
└─────────────────┴───────────────────┘
    ↓
Thompson NFA Engine (基础引擎)
    ↓
Input Abstraction (编译时多态)
```

### 核心组件设计

#### 1. Meta Engine
```zig
pub const MetaEngine = struct {
    literal_engine: LiteralEngine,
    dfa_cache: DfaCache,
    nfa_engine: ThompsonNfa,
    
    pub fn exec(self: *MetaEngine, input: []const u8) !bool {
        // 1. 字面量快速扫描
        if (self.literal_engine.canExec(input)) {
            return self.literal_engine.exec(input);
        }
        
        // 2. 尝试 Lazy DFA
        if (self.dfa_cache.tryExec(input)) |result| {
            return result;
        }
        
        // 3. 回退到 Thompson NFA
        return self.nfa_engine.exec(input);
    }
};
```

#### 2. Literal Engine
```zig
pub const LiteralEngine = struct {
    boyer_moore: BoyerMoore,
    aho_corasick: AhoCorasick,
    
    pub fn canExec(self: *const LiteralEngine, prog: *const Program) bool {
        return prog.hasLiteralPrefix() or 
               prog.hasLiteralSet() or
               prog.hasFixedString();
    }
    
    pub fn exec(self: *LiteralEngine, input: []const u8) !bool {
        // 根据程序特性选择最优字面量算法
    }
};
```

#### 3. Thompson NFA Engine
```zig
pub const ThompsonNfa = struct {
    program: *const Program,
    thread_set: ThreadSet,
    
    pub fn exec(self: *ThompsonNfa, input: []const u8) !bool {
        var current = self.thread_set.empty();
        var next = self.thread_set.empty();
        
        // 使用位向量表示线程集合，避免动态分配
        current.add(self.program.start_state);
        
        while (!input.isConsumed()) {
            self.step(&current, &next, input.current());
            mem.swap(ThreadSet, &current, &next);
            next.clear();
            input.advance();
        }
        
        return current.containsMatch();
    }
};
```

#### 4. Lazy DFA Engine
```zig
pub const LazyDfa = struct {
    cache: std.AutoHashMap(State, DfaState),
    nfa: *const ThompsonNfa,
    
    pub fn tryExec(self: *LazyDfa, input: []const u8) ?bool {
        var current_state = self.startState();
        
        for (input) |char| {
            if (self.cache.get(current_state)) |dfa_state| {
                current_state = dfa_state.transition(char);
            } else {
                // 编译新的 DFA 状态
                const new_state = self.compileState(current_state);
                self.cache.put(current_state, new_state);
                current_state = new_state.transition(char);
            }
        }
        
        return current_state.isAccepting();
    }
};
```

## 开发阶段规划

### 第一阶段：基础架构重构（2-3 周）

#### 1.1 移除现有双引擎
- 删除 `vm_backtrack.zig` 和 `vm_pike.zig`
- 清理 `exec.zig` 中的引擎选择逻辑
- 简化 `compile.zig`，移除不必要的复杂性

#### 1.2 实现新的输入抽象层
- 移除函数指针，使用编译时多态
- 实现 `InputBytes` 和 `InputUtf8` 两种具体类型
- 优化字符访问性能，消除间接调用开销

#### 1.3 重写 Thompson NFA 引擎
- 使用位向量表示线程集合
- 实现高效的 NFA 执行算法
- 添加基本的性能测试和基准测试

**交付物：**
- 新的 Thompson NFA 引擎
- 性能提升 10-50 倍
- 完整的单元测试覆盖

### 第二阶段：字面量优化引擎（2-3 周）

#### 2.1 实现 Boyer-Moore 算法
- 单模式快速字符串匹配
- 支持坏字符规则和好后缀规则
- 集成到 Meta Engine 中

#### 2.2 实现 Aho-Corasick 算法
- 多模式快速字符串匹配
- 构建 trie 图和失败函数
- 支持动态模式集更新

#### 2.3 字面量提取和优化
- 在编译阶段提取字面量前缀
- 自动选择最优字面量匹配算法
- 实现字面量组合优化

**交付物：**
- 完整的字面量优化引擎
- 简单正则表达式性能提升 100-1000 倍
- 字面量优化测试套件

### 第三阶段：Lazy DFA 引擎（3-4 周）

#### 3.1 DFA 状态编译
- 从 NFA 状态编译 DFA 状态
- 处理状态爆炸问题
- 实现状态最小化算法

#### 3.2 DFA 缓存管理
- 实现 LRU 缓存策略
- 处理缓存失效和更新
- 优化内存使用效率

#### 3.3 DFA 执行引擎
- 实现高效的 DFA 状态转移
- 处理 Unicode 字符分类
- 集成捕获组支持

**交付物：**
- Lazy DFA 引擎
- 中等复杂度正则表达式性能提升 10-100 倍
- DFA 缓存管理测试

### 第四阶段：UTF-8 支持（2-3 周）

#### 4.1 UTF-8 解码和编码
- 实现高效的 UTF-8 解码器
- 处理无效 UTF-8 序列
- 支持 Unicode 字符属性

#### 4.2 Unicode 字符类
- 实现 Unicode 字符分类
- 支持 Unicode 属性匹配
- 优化字符类匹配性能

#### 4.3 Unicode 感知匹配
- 实现 Unicode 边界检测
- 支持 Unicode 规范化
- 处理 Unicode 大小写转换

**交付物：**
- 完整的 UTF-8 支持
- Unicode 兼容性测试
- 性能基准测试

### 第五阶段：API 重构和优化（2-3 周）

#### 5.1 高级 API 设计
- 重新设计 `Regex` API
- 支持同步和异步匹配
- 提供迭代器接口

#### 5.2 内存管理优化
- 实现对象池和内存复用
- 优化分配器使用
- 减少内存碎片

#### 5.3 编译时优化
- 支持编译时正则表达式验证
- 实现编译时常量折叠
- 优化编译时间性能

**交付物：**
- 现代化的 API 设计
- 内存使用效率提升 10-50 倍
- 完整的 API 文档和示例

### 第六阶段：测试和性能优化（2-3 周）

#### 6.1 全面测试覆盖
- 单元测试覆盖率达到 95%+
- 集成测试和回归测试
- 模糊测试和压力测试

#### 6.2 性能基准测试
- 建立全面的性能基准
- 与 Rust regex 进行对比测试
- 识别和解决性能瓶颈

#### 6.3 文档和示例
- 编写详细的 API 文档
- 提供丰富的使用示例
- 性能优化指南

**交付物：**
- 完整的测试套件
- 性能基准测试报告
- 用户文档和开发指南

## 技术实现细节

### 数据结构优化

#### 1. 位向量线程集合
```zig
pub const ThreadSet = struct {
    bits: []usize,
    capacity: usize,
    
    pub fn init(capacity: usize) ThreadSet {
        const word_count = (capacity + @bitSizeOf(usize) - 1) / @bitSizeOf(usize);
        return ThreadSet{
            .bits = allocator.alloc(usize, word_count),
            .capacity = capacity,
        };
    }
    
    pub fn add(self: *ThreadSet, state: usize) void {
        const word_index = state / @bitSizeOf(usize);
        const bit_index = state % @bitSizeOf(usize);
        self.bits[word_index] |= @as(usize, 1) << bit_index;
    }
    
    pub fn contains(self: *const ThreadSet, state: usize) bool {
        const word_index = state / @bitSizeOf(usize);
        const bit_index = state % @bitSizeOf(usize);
        return (self.bits[word_index] & (@as(usize, 1) << bit_index)) != 0;
    }
};
```

#### 2. 编译时多态输入抽象
```zig
pub fn Input(comptime T: type) type {
    return struct {
        data: T,
        pos: usize,
        
        pub fn current(self: *const @This()) ?T {
            if (self.pos < self.data.len) {
                return self.data[self.pos];
            }
            return null;
        }
        
        pub fn advance(self: *@This()) void {
            if (self.pos < self.data.len) {
                self.pos += 1;
            }
        }
        
        pub fn isConsumed(self: *const @This()) bool {
            return self.pos >= self.data.len;
        }
    };
}

pub const InputBytes = Input(u8);
pub const InputUtf8 = Input(unicode.CodePoint);
```

### 算法优化

#### 1. Boyer-Moore 实现
```zig
pub const BoyerMoore = struct {
    pattern: []const u8,
    bad_char: [256]isize,
    good_suffix: []isize,
    
    pub fn init(pattern: []const u8, allocator: Allocator) !BoyerMoore {
        var bm = BoyerMoore{
            .pattern = pattern,
            .bad_char = undefined,
            .good_suffix = try allocator.alloc(isize, pattern.len + 1),
        };
        
        // 预处理坏字符规则
        for (bm.bad_char) |*shift| {
            shift.* = pattern.len;
        }
        for (pattern, 0..) |c, i| {
            bm.bad_char[c] = @as(isize, pattern.len) - @as(isize, i) - 1;
        }
        
        // 预处理后缀规则
        // ... 实现后缀规则预处理
        
        return bm;
    }
    
    pub fn search(self: *const BoyerMoore, text: []const u8) ?usize {
        var i: usize = 0;
        while (i <= text.len - self.pattern.len) {
            var j = self.pattern.len;
            while (j > 0 and self.pattern[j - 1] == text[i + j - 1]) {
                j -= 1;
            }
            
            if (j == 0) {
                return i;
            }
            
            const bad_char_shift = self.bad_char[text[i + j - 1]];
            const good_suffix_shift = self.good_suffix[j];
            
            i += @max(bad_char_shift, good_suffix_shift);
        }
        
        return null;
    }
};
```

#### 2. Aho-Corasick 实现
```zig
pub const AhoCorasick = struct {
    root: *Node,
    patterns: [][]const u8,
    
    const Node = struct {
        children: [256]?*Node,
        fail: *Node,
        output: []const usize,
        is_end: bool,
    };
    
    pub fn init(patterns: [][]const u8, allocator: Allocator) !AhoCorasick {
        var ac = AhoCorasick{
            .root = try allocator.create(Node),
            .patterns = patterns,
        };
        
        // 构建 trie
        for (patterns, 0..) |pattern, i| {
            try ac.insert(pattern, i);
        }
        
        // 构建失败函数
        try ac.buildFail();
        
        return ac;
    }
    
    pub fn search(self: *const AhoCorasick, text: []const u8) []const usize {
        var matches = std.ArrayList(usize).init(allocator);
        defer matches.deinit();
        
        var current = self.root;
        for (text, 0..) |c, i| {
            while (current.children[c] == null and current != self.root) {
                current = current.fail;
            }
            
            if (current.children[c]) |child| {
                current = child;
            }
            
            // 收集匹配
            var output_node = current;
            while (output_node != self.root) {
                if (output_node.is_end) {
                    try matches.append(i - output_node.output.len + 1);
                }
                output_node = output_node.fail;
            }
        }
        
        return matches.toOwnedSlice();
    }
};
```

## 性能预期

### 各阶段性能提升预期

| 阶段 | 优化内容 | 性能提升 | 内存优化 |
|------|----------|----------|----------|
| 第一阶段 | Thompson NFA 重构 | 10-50x | 5-10x |
| 第二阶段 | 字面量优化 | 100-1000x | 2-5x |
| 第三阶段 | Lazy DFA | 10-100x | 10-50x |
| 第四阶段 | UTF-8 支持 | 0.5-2x | 1-2x |
| 第五阶段 | API 优化 | 2-5x | 10-50x |
| 第六阶段 | 综合优化 | 2-5x | 2-5x |

### 与 Rust regex 对比预期

| 场景 | 当前性能 | 重构后预期 | Rust regex |
|------|----------|------------|------------|
| 简单字面量匹配 | 极慢 | 0.5-1x | 1x |
| 简单正则表达式 | 慢 | 0.3-0.8x | 1x |
| 复杂正则表达式 | 极慢 | 0.5-0.9x | 1x |
| 大文本匹配 | 慢 | 0.7-0.9x | 1x |
| 内存使用 | 高 | 1-2x | 1x |

## 风险评估和缓解措施

### 技术风险

#### 1. 性能不达预期
**风险**：重构后性能无法达到预期目标
**缓解措施**：
- 每个阶段都进行详细的性能基准测试
- 与 Rust regex 进行持续对比
- 建立性能回归测试

#### 2. 架构复杂度过高
**风险**：多层架构增加维护难度
**缓解措施**：
- 保持模块间清晰的接口边界
- 实现详细的单元测试
- 编写架构文档和设计决策记录

#### 3. 兼容性问题
**风险**：API 变更破坏现有用户代码
**缓解措施**：
- 明确声明不保持向后兼容
- 提供迁移指南
- 实现兼容性测试套件

### 项目风险

#### 1. 开发时间超期
**风险**：重构时间超过预期
**缓解措施**：
- 分阶段交付，每个阶段都有明确的交付物
- 建立里程碑和检查点
- 保持灵活的开发计划

#### 2. 资源不足
**风险**：开发资源不足以完成重构
**缓解措施**：
- 优先实现核心功能
- 考虑分阶段发布
- 寻求社区贡献

## 成功标准

### 技术标准
- 所有正则表达式匹配保持线性时间复杂度
- 简单正则表达式匹配性能达到 Rust regex 的 50%+
- 内存使用效率提升 10-50 倍
- 编译时间优化 50-80%

### 质量标准
- 单元测试覆盖率达到 95%+
- 集成测试覆盖所有主要功能
- 模糊测试无内存泄漏和崩溃
- 性能回归测试通过

### 用户体验标准
- API 设计直观易用
- 文档完整且示例丰富
- 错误信息清晰准确
- 编译时错误检查完善

## 结论

本重构计划通过彻底重写正则表达式引擎，采用现代多层架构，实现与 Rust regex 相当的性能水平。重构分为六个阶段，每个阶段都有明确的目标和交付物。虽然这是一个 ambitious 的计划，但通过分阶段实施和持续优化，最终将产生一个高性能、现代化的 Zig 正则表达式引擎。

重构完成后，zig-regex 将成为 Zig 生态系统中性能最优的正则表达式库之一，为 Zig 开发者提供强大而高效的文本处理能力。