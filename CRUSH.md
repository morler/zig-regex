# CRUSH.md - Zig Regex Development Commands & Style

## Build/Test Commands
- `zig build test` - Run all tests
- `zig test src/all_test.zig` - Full test suite
- `zig test src/regex_test.zig` - Regex functionality tests
- `zig test src/parse_test.zig` - Parser tests
- `zig test src/input_test.zig` - Input handling tests
- `zig test src/performance_benchmark.zig` - Performance benchmarks

## Code Style Guidelines
- **Imports**: `@import` with relative paths, list `std` imports first
- **Naming**: camelCase functions, PascalCase types, snake_case variables
- **Error Handling**: Use error unions (`!`), `try` to propagate, `catch` to handle
- **Memory**: Pass allocators explicitly, ensure owned resources call `deinit()`
- **Comments**: Explain "why", add doc comments for public APIs
- **Testing**: Use `std.testing.allocator`, place tests in `src/*_test.zig` files