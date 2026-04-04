# {{PROJECT_NAME}} — Rust Starter Guide

This guide documents conventions and setup procedures for {{PROJECT_NAME}}, a Rust project.

## Project Overview

{{PROJECT_NAME}} is a **Rust** project{{FRAMEWORK:+ using {{FRAMEWORK}}}}.

**Quick Links:**
- Build command: `cargo build`
- Test command: `{{TEST_CMD}}`
- Run command: `cargo run`

## Project Structure

```
{{PROJECT_NAME}}/
├── src/                    # Source code
│   ├── main.rs             # Binary entry point (if binary)
│   ├── lib.rs              # Library entry point
│   ├── handlers/           # HTTP/Request handlers
│   ├── models/             # Data structures
│   └── utils/              # Utilities
├── tests/                  # Integration tests
├── benches/                # Benchmarks
├── examples/               # Example programs
├── Cargo.toml              # Project manifest
├── Cargo.lock              # Dependency lock
└── clippy.toml             # Clippy linter config
```

## Build & Test

### Installation
```bash
# Ensure Rust is installed: https://rustup.rs/
rustup update
```

### Building
```bash
cargo build                # Debug build
cargo build --release      # Optimized release build
```

### Running Tests
```bash
{{TEST_CMD}}
```

### Running Benchmarks
```bash
cargo bench
```

### Running Code Quality Checks
```bash
cargo clippy -- -D warnings  # Linter (fail on warnings)
cargo fmt --check            # Format check
```

## Code Conventions

### Naming Conventions
- **Types/Structs**: PascalCase (e.g., `UserService`, `ApiResponse`)
- **Functions/Methods**: snake_case (e.g., `handle_request`, `create_user`)
- **Constants**: UPPER_SNAKE_CASE (e.g., `MAX_RETRIES`, `DEFAULT_TIMEOUT`)
- **Modules**: lowercase (e.g., `user_service`, `api_handlers`)
- **Private items**: prefix with `_` for intentionally unused (e.g., `_internal`)

### Ownership & Borrowing
- **Prefer borrowing** over moving values (use `&T`, `&mut T`)
- **Return owned values** only when necessary
- **Use lifetimes** explicitly when needed
- **Avoid `clone()`** without justification (measure performance impact)

### Error Handling
- **Use `Result<T, E>`** instead of panicking
- **Custom error types**: implement `std::error::Error` + `Display`
- **Use `?` operator** in functions that return `Result`
- **Never `unwrap()`** without justification (use `expect()` with message instead)

### Unsafe Code
- **Mark all unsafe blocks** with a comment explaining why
- **Minimize unsafe code** — prefer safe abstractions
- **Test unsafe code** extensively with edge cases
- Example:
  ```rust
  // SAFETY: Data is guaranteed to be valid UTF-8 by the parser
  unsafe { std::str::from_utf8_unchecked(data) }
  ```

### Testing Requirements
- Test files: `#[cfg(test)]` modules in same file
- **Minimum 70% coverage** for new code
- Use `#[test]` attribute for unit tests
- Use `#[tokio::test]` for async tests
- Integration tests: in `tests/` directory

### Code Style
- Use `cargo fmt` to auto-format (don't commit unformatted code)
- Use `cargo clippy` to catch common mistakes
- Follow Rust API guidelines: https://rust-lang.github.io/api-guidelines/
- Keep functions small and focused

## Common Tasks

### Add a New Module
```rust
// In src/lib.rs or src/main.rs
mod user_service;
pub use user_service::*;

// In src/user_service.rs
pub struct UserService { /* ... */ }
pub fn create_user(name: &str) -> Result<User, Error> { /* ... */ }
```

### Add a Test
```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_create_user() {
        let user = create_user("John").expect("Should create user");
        assert_eq!(user.name, "John");
    }
}
```

### Update Dependencies
```bash
cargo update
cargo tree                # View dependency tree
cargo outdated           # Check for newer versions
```

### Optimize Release Binary
```bash
# In Cargo.toml
[profile.release]
opt-level = 3
lto = true
codegen-units = 1
```

### Profile Performance
```bash
cargo bench
perf record -g ./target/release/{{PROJECT_NAME}}
perf report
```

## Troubleshooting

### Compilation errors
- Check Rust version: `rustc --version` (pin in `rust-toolchain.toml`)
- Update toolchain: `rustup update`
- Clean and rebuild: `cargo clean && cargo build`

### Lifetime issues ("borrowed value does not live long enough")
- Review borrowing pattern (consider cloning if justified)
- Use `'static` lifetime for owned data
- Document lifetime requirements in function signature

### Unsafe code warnings
- Ensure every `unsafe {}` block has a SAFETY comment
- Consider alternatives: safe abstractions or different approach
- Use `#[allow(unsafe_code)]` sparingly with justification

### Async/await deadlocks or timeouts
- Add explicit timeout: `tokio::time::timeout(Duration::from_secs(10), future).await`
- Avoid blocking operations in async code
- Use `task::spawn_blocking` for sync operations

### Large binary size
- Use `cargo build --release`
- Strip symbols: `strip ./target/release/{{PROJECT_NAME}}`
- Enable LTO in Cargo.toml (slows compilation, reduces size)

## Next Steps

1. **Verify build**: `cargo build` should succeed
2. **Run tests**: `{{TEST_CMD}}` should pass
3. **Check code quality**: `cargo clippy` and `cargo fmt --check`
4. **Read ARCHITECTURE.md** for system design
5. **Check CODING-STANDARDS.md** for detailed conventions
6. **Follow DEFINITION-OF-DONE.md** when submitting PRs
