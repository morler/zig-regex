# Repository Guidelines

## Project Structure & Module Organization
- Source lives in `src/` (e.g., `regex.zig`, `compile.zig`, `thompson_nfa.zig`, `parse.zig`).
- Tests are colocated in `src/` as `*_test.zig` (see `src/all_test.zig`).
- C interop header in `include/regex.h`; examples in `example/`.
- Build files: `build.zig` and `build.zig.zon`.

## Build, Test, and Development Commands
- `zig build test` — run all tests via the build.
- `zig test src/all_test.zig` — full suite across modules.
- `zig test src/regex_test.zig` — regex functionality tests.
- `zig test src/parse_test.zig` — parser tests.
- `zig test src/input_test.zig` — input handling tests.
- `zig test src/performance_benchmark.zig` — performance benchmarks.

## Coding Style & Naming Conventions
- Imports: use `@import` with relative paths; list `std` imports first.
- Naming: camelCase functions, PascalCase types, snake_case variables.
- Errors: use error unions (`!`), `try` to propagate, `catch` to handle.
- Memory: pass allocators explicitly; ensure owned resources call `deinit()`.
- Comments: explain “why”; add doc comments for public APIs.

## Testing Guidelines
- Use `std.testing.allocator` and clean up allocations.
- Place tests near code in `src/*_test.zig`; mirror file names where possible.
- Cover edge cases (empty inputs, large classes, UTF-8 boundaries).
- Run `zig build test` locally before pushing.

## Commit & Pull Request Guidelines
- Commits: follow Conventional Commits (e.g., `feat:`, `fix:`, `chore:`); imperative, present tense.
- PRs: clear description, linked issues, tests updated/added; include benchmark output for perf-relevant changes.
- Keep diffs focused; avoid unrelated formatting. CI must pass.

## Agent-Specific Instructions
- Follow allocator and error rules above; keep changes minimal and consistent.
- Prefer localized tests in `src/*_test.zig` and update `src/all_test.zig` when adding suites.
