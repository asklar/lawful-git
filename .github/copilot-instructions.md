# Copilot Instructions for lawful-git

## What this project is

lawful-git is a single-binary Go program that acts as a transparent drop-in replacement for `git`. It intercepts git invocations, enforces per-repo safety policies declared in `.git-safety.json`, then `exec`s the real git binary. If no config is found, it passes through silently.

## Build and test

```sh
# Build
go build -o lawful-git .

# Run the full test suite (builds automatically, then runs end-to-end tests)
bash tests/run_tests.sh
```

There is no unit test framework — tests are bash-based end-to-end tests in `tests/run_tests.sh` that build the binary, set up an isolated temp repo with a fake remote, and exercise every rule type. To add a single test case, use the existing harness functions:

- `assert_blocked "description" git -C "$REPO" <args>` — expects lawful-git to block with exit 1
- `assert_allowed "description" git -C "$REPO" <args>` — expects the command to succeed without being blocked
- `assert_passes_through "description" git -C "$REPO" <args>` — expects lawful-git to not block (git itself may still fail)

## Architecture

All logic lives in `main.go` — there are no packages or subdirectories. The flow is:

1. `findRealGit()` — walks PATH to locate the actual git binary, skipping itself
2. `parseGlobalOpts()` — strips git's global flags (e.g. `-C <path>`) to find the subcommand index; sets `gitContext` for subprocess calls
3. `loadConfig()` — resolves the repo root via `git rev-parse --show-toplevel`, reads `.git-safety.json`; returns nil (passthrough) if not in a repo or no config
4. `applyRules()` — checks all rule types against the parsed args; calls `block()` (print to stderr + exit 1) on violation
5. `execRealGit()` — on Unix, replaces the process via `syscall.Exec`; on Windows, runs git as a child and forwards the exit code

## Key conventions

- **Rule types** in `.git-safety.json` map directly to code sections in `applyRules()`: `blocked`, `require`, `scoped_paths`, `worktree_only_branches`, `check_dirty_on_checkout`, `require_upstream_before_bare_push`, `protected_branches`. When adding a new rule type, add a new struct, a new field on `Config`, and a new section in `applyRules()`.
- **Blocked rules** use AND logic: all specified fields (command, subcommand, flags) must match for the rule to fire. Short flags in the `flags` array (e.g. `"-f"`) also match inside bundled flags (e.g. `-xvf`).
- `block()` is the single exit path for violations — it prints `❌ BLOCKED: <message>` to stderr and exits 1. Tests rely on this exact prefix.
- Cross-platform: the binary must compile for Linux, macOS, and Windows. `execRealGit()` handles the platform split. The `go.mod` targets Go 1.21 with zero external dependencies.
- **Fail-closed on config errors**: if `.git-safety.json` exists but is malformed, lawful-git exits with an error rather than silently disabling rules.
- The repo's own `.git-safety.json` is a real config that dogfoods the tool — it restricts operations to the `my-project/` path prefix and blocks destructive commands.
