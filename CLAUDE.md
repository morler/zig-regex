# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Build and Test
- `zig build test` - Run all tests through the build system
- `zig test src/all_test.zig` - Run complete test suite across all modules
- `zig test src/regex_test.zig` - Test core regex functionality
- `zig test src/parse_test.zig` - Test parser implementation
- `zig test src/input_test.zig` - Test input handling
- `zig test src/utf8_test.zig` - Test UTF-8 handling
- `zig test src/lazy_dfa_test.zig` - Test lazy DFA implementation
- `zig test src/unicode_regex_test.zig` - Test Unicode regex features

### Individual Component Tests
- `zig test src/thompson_nfa2.zig` - Test Thompson NFA implementation
- `zig test src/benchmark.zig` - Run performance benchmarks
- `zig test src/performance_benchmark.zig` - Run specific performance tests
- `zig test src/memory_benchmark.zig` - Run memory usage benchmarks

## Architecture Overview

This is a comprehensive regex engine implementation in Zig with multiple execution strategies and optimizations.

### Core Components

**Main API (`src/regex.zig`)**: High-level public interface that provides:
- `Regex.compile()` - Parse and compile regex patterns
- `Regex.match()` - Full string matching
- `Regex.partialMatch()` - Partial string matching
- `Regex.captures()` - Capture group extraction
- `Captures` - Handle for accessing capture group results

**Parsing Pipeline**:
- `src/parse.zig` - Parser that converts regex strings to expression trees
- `src/input_new.zig` - Input handling with support for different encodings
- `src/range_set.zig` - Character class and range handling

**Compilation**:
- `src/compile.zig` - Compiles expression trees to instruction programs
- `src/comptime_*.zig` files - Compile-time optimizations and simplification

**Execution Engines** (Multiple strategies available):
1. **Thompson NFA** (`src/thompson_nfa.zig`, `src/thompson_nfa2.zig`) - Backtracking-free NFA execution
2. **Lazy DFA** (`src/lazy_dfa.zig`) - On-the-fly DFA construction from NFA
3. ** PikeVM** - Virtual machine for regex execution
4. **Literal Optimizations** (`src/literal_engine.zig`, `src/literal_extractor.zig`) - Fast literal prefix/suffix matching

**Optimizations**:
- `src/comptime_optimizer.zig` - Compile-time optimization passes
- `src/comptime_nfa_simplifier.zig` - NFA graph simplification
- `src/boyer_moore.zig` - Boyer-Moore string matching algorithm
- `src/bit_vector.zig` - Efficient bit vector operations for state management

**Unicode Support**:
- `src/utf8.zig` - UTF-8 encoding/decoding utilities
- `src/unicode_regex.zig` - Unicode-aware regex features

**Memory Management**:
- `src/memory_pool.zig` - Custom memory pool implementation
- `src/simple_memory_pool.zig` - Simplified memory pool

### Key Architectural Patterns

**Multiple Execution Strategies**: The engine supports different matching algorithms (NFA, DFA, PikeVM) that can be selected based on the regex pattern and input characteristics.

**Compile-time Optimization**: Heavy use of Zig's comptime features to optimize regex compilation, including literal extraction and NFA simplification.

**Memory Efficiency**: Custom memory pools and careful allocator management to minimize memory overhead during regex matching.

**Modular Design**: Clear separation between parsing, compilation, and execution phases, allowing for independent optimization of each component.

### Testing Strategy

Tests are organized by module in `src/*_test.zig` files:
- `src/all_test.zig` - Main test runner that imports all test modules
- Component-specific tests (e.g., `parse_test.zig`, `regex_test.zig`)
- Performance benchmarks in separate modules (e.g., `benchmark.zig`)
- Memory usage tracking tests (e.g., `memory_benchmark.zig`)

### Current Implementation Status

Based on git status and TODO tracking, the project is actively working on:
- Epsilon-closure implementation for NFA execution
- UTF-8 boundary handling improvements
- Performance optimizations and benchmarking
- Capture group and Unicode feature enhancements

The implementation follows Zig best practices with explicit allocator management, comprehensive error handling, and extensive test coverage.
- **使用Serena工具处理代码相关操作**