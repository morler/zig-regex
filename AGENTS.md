# Agent Guidelines for zig-regex

## Build/Test Commands
- `zig build test` - Run all tests
- `zig test src/regex_test.zig` - Run single test file
- `zig test src/parse_test.zig` - Run parser tests
- `zig test src/vm_test.zig` - Run VM tests
- `zig build c-example` - Build and run C example

## Code Style
- **Imports**: Use `@import` with relative paths, organize std imports first
- **Naming**: camelCase for functions, PascalCase for types, snake_case for variables
- **Error handling**: Use `!` for error unions, `try` for propagation, `catch` for handling
- **Memory**: Explicit allocator management, always call `deinit()` for cleanup
- **Testing**: Use `std.testing.allocator`, follow existing test patterns in test files
- **Comments**: Minimal, focus on "why" not "what", use doc comments for public APIs