# {{PROJECT_NAME}} — Go Starter Guide

This guide documents conventions and setup procedures for {{PROJECT_NAME}}, a Go project.

## Project Overview

{{PROJECT_NAME}} is a **Go** project{{FRAMEWORK:+ with {{FRAMEWORK}}}} that runs on Go {{GO_VERSION}}.

**Quick Links:**
- Build command: `go build ./cmd/...`
- Test command: `{{TEST_CMD}}`
- Go version: `go version`

## Project Structure

```
{{PROJECT_NAME}}/
├── cmd/                    # Executable entry points
│   └── {{PROJECT_NAME}}/   # Main CLI/server
├── internal/               # Private packages (not importable)
│   ├── handlers/           # HTTP/gRPC handlers
│   ├── models/             # Data structures
│   ├── middleware/         # HTTP middleware
│   └── services/           # Business logic
├── pkg/                    # Public packages (importable by others)
├── api/                    # Proto files (if using gRPC)
├── tests/                  # Integration tests
├── go.mod                  # Module manifest
├── go.sum                  # Dependency lock
└── Makefile                # Build targets
```

## Build & Test

### Installation
```bash
go mod download
go mod verify
```

### Running Tests
```bash
{{TEST_CMD}}
```

### Building Binary
```bash
go build -o ./bin/{{PROJECT_NAME}} ./cmd/{{PROJECT_NAME}}
```

### Running the Binary
```bash
./bin/{{PROJECT_NAME}}
```

## Code Conventions

### Naming Conventions
- **Exported symbols**: PascalCase (e.g., `UserService`, `GetUser`)
- **Unexported symbols**: camelCase (e.g., `userService`, `getUser`)
- **Interfaces**: PascalCase (e.g., `Reader`, `Writer`)
- **Constants**: UPPER_SNAKE_CASE or PascalCase (e.g., `MaxRetries`, `defaultTimeout`)
- **Packages**: lowercase, no underscores (e.g., `handlers`, not `handler_utils`)

### Error Handling
- **Always** check and return errors explicitly
- Don't use `panic` in production code
- Wrap errors with context: `fmt.Errorf("operation failed: %w", err)`
- Use custom error types for domain errors

### Concurrency
- Use goroutines for concurrent work
- Protect shared state with sync.Mutex or channels
- Handle graceful shutdown with context.Context
- Set timeouts on all I/O operations

### Testing Requirements
- Test files: `*_test.go` in same package
- **Minimum 70% coverage** for new code
- Use `testing.T` for unit tests
- Use `testing.B` for benchmarks

### Code Style
- Use `gofmt` to format (automatically)
- Use `go vet` to check for errors
- Keep lines ≤ 120 characters where possible
- Document exported functions with comments

## Common Tasks

### Add a New Handler
```bash
# Create in internal/handlers/
# Follow interface pattern: func (h *Handler) HandleXxx(w http.ResponseWriter, r *http.Request)
# Add tests in same file: TestHandleXxx
```

### Update Dependencies
```bash
go get -u ./...
go mod tidy
```

### Generate Code from Proto
```bash
protoc --go_out=. --go-grpc_out=. api/proto/*.proto
```

### Run Benchmarks
```bash
go test -bench=. -benchmem ./...
```

### Check Code Quality
```bash
go vet ./...
golint ./... # or golangci-lint run
```

## Troubleshooting

### "Module not found" errors
- Ensure `go.mod` exists in project root
- Run `go mod tidy` to sync dependencies
- Check module name in `go.mod` (first line)

### Compilation failures
- Check Go version: `go version` (minimum {{GO_VERSION}})
- Ensure all imports are in `go.mod`: `go get <import>`
- Run `go build ./...` from project root

### Test timeout or hanging
- Add timeout: `go test -timeout 30s ./...`
- Check for goroutine leaks: use `go-test-timeout` or manual inspection
- Review for blocking channels or deadlocks

### Port already in use (server won't start)
- Find process: `lsof -i :{{PORT}}`
- Kill process: `kill -9 <PID>`
- Or use different port: environment variable or CLI flag

## Next Steps

1. **Verify build**: `go build ./...` should succeed
2. **Run tests**: `{{TEST_CMD}}` should pass
3. **Read ARCHITECTURE.md** for system design
4. **Check CODING-STANDARDS.md** for detailed conventions
5. **Follow DEFINITION-OF-DONE.md** when submitting PRs
