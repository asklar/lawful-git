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

To test global config behavior, set `LAWFUL_GIT_GLOBAL_CONFIG` inline:

```sh
LAWFUL_GIT_GLOBAL_CONFIG="$GLOBAL_CFG" assert_blocked "desc" git -C "$REPO" <args>
```

## Adding a new rule type

1. Define a new struct in `main.go` (e.g. `type MyRule struct { ... }`)
2. Add a field for it on the `Config` struct with the appropriate JSON tag
3. Add an enforcement section in `applyRules()`
4. Add validation in `validateConfig()`
5. Document the rule in `README.md` under **Configuration reference → Rule types**
5. Add test cases covering both blocked and allowed scenarios

## Project structure

- `main.go` — all application logic (config loading, merging, validation, rule enforcement, consent flow)
- `dialog_windows.go` — Win32 MessageBoxW syscall for consent dialogs (build-tagged)
- `dialog_other.go` — macOS/Linux/WSL consent dialogs (build-tagged)
- `tests/run_tests.sh` — end-to-end test suite
- `lawful-git.manifest` — Windows comctl32 v6 manifest
- `rsrc_windows_*.syso` — pre-built Windows resource objects (regenerate with `generate-syso.ps1`)

## Cross-platform

The binary must compile and work on Linux, macOS, and Windows. Platform-specific behavior is isolated to:

- `execRealGit()` in `main.go` (process replacement vs child process)
- `dialog_windows.go` and `dialog_other.go` (consent dialog UI)
