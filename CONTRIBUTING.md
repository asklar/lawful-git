# Contributing to lawful-git

## Building

```sh
go build -o lawful-git .
```

Requires Go 1.21+. There are no external dependencies.

## Testing

```sh
bash tests/run_tests.sh
```

This builds the binary, creates an isolated temporary repo with a fake remote, and runs all rule types end-to-end. The suite exits 0 on full pass.

### Adding a test case

Tests live in `tests/run_tests.sh`. Use the existing harness functions:

```sh
# Expect lawful-git to block the command (exit 1, "❌ BLOCKED:" on stderr)
assert_blocked "description of test"   git -C "$REPO" <subcommand> <args>

# Expect the command to succeed without being blocked
assert_allowed "description of test"   git -C "$REPO" <subcommand> <args>

# Expect lawful-git to pass through (git itself may still fail)
assert_passes_through "description"    git -C "$REPO" <subcommand> <args>
```

Place new tests under the appropriate `=== section ===` heading, or add a new section for a new rule type.

## Adding a new rule type

1. Define a new struct in `main.go` (e.g. `type MyRule struct { ... }`)
2. Add a field for it on the `Config` struct with the appropriate JSON tag
3. Add an enforcement section in `applyRules()`
4. Document the rule in `README.md` under **Configuration reference → Rule types**
5. Add test cases covering both blocked and allowed scenarios

## Project structure

All application logic is in `main.go` — there are no packages or subdirectories. The test suite is a single bash script at `tests/run_tests.sh`. Install scripts (`install.sh`, `install.ps1`) are for end users.

## Cross-platform

The binary must compile and work on Linux, macOS, and Windows. Platform-specific behavior is isolated to `execRealGit()` in `main.go`. Avoid platform-specific imports outside that function.
