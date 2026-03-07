# lawful-git

A data-driven git guardrail engine for AI agent sessions. `lawful-git` is a drop-in replacement for the `git` binary that enforces per-repo safety policies declared in a `.git-safety.json` file, then `exec`s the real `git` transparently.

---

## What it is

When invoked as `git`, `lawful-git`:

1. Resolves the repo root via `git rev-parse --show-toplevel`
2. Looks for `.git-safety.json` in that root
3. If found, enforces the rules declared in that file
4. If no config, or if outside a configured repo, execs the real git unchanged
5. On rule violation: prints `❌ BLOCKED: <message>` to stderr and exits 1
6. On success: `exec`s (replacing the process on Unix, forwarding exit code on Windows) the real git with all original args

It produces a single static binary. Cross-platform: Linux, macOS, Windows. No runtime dependencies.

---

## Installation

### Linux / macOS (one-liner)

```sh
git clone https://github.com/asklar/lawful-git
cd lawful-git
bash install.sh
```

#### Environment variable overrides

| Variable | Default | Description |
|---|---|---|
| `LAWFUL_GIT_INSTALL_DIR` | `/usr/local/lib/lawful-git` | Directory for the binary |
| `LAWFUL_GIT_SYMLINK` | `/usr/local/bin/git` | Symlink path that shadows real `git` |

Example:

```sh
LAWFUL_GIT_INSTALL_DIR=~/.local/lib/lawful-git \
LAWFUL_GIT_SYMLINK=~/.local/bin/git \
bash install.sh
```

#### Uninstall (Linux/macOS)

```sh
rm /usr/local/bin/git
rm -rf /usr/local/lib/lawful-git
```

---

### Windows (PowerShell)

```powershell
git clone https://github.com/asklar/lawful-git
cd lawful-git
.\install.ps1
```

Installs to `$env:LOCALAPPDATA\lawful-git\` and prepends that directory to the user `PATH` via the registry (ahead of the real git).

#### Uninstall (Windows)

```powershell
Remove-Item "$env:LOCALAPPDATA\lawful-git\lawful-git.exe"
# Then remove $env:LOCALAPPDATA\lawful-git from your user PATH in System Properties
```

---

## Configuration reference

Place `.git-safety.json` in the root of the repository you want to guard. All keys are optional.

```jsonc
{
  // Block git switch and git checkout without -- (worktree-only mode)
  "worktree_only_branches": true,

  // When true, also blocks `git checkout -- <file>` if the file is dirty
  "check_dirty_on_checkout": true,

  // Block bare `git push` when no upstream tracking branch is configured
  "require_upstream_before_bare_push": true,

  // Commands/flags/subcommands to block outright
  "blocked": [
    { "command": "clean",   "message": "git clean deletes untracked files." },
    { "command": "push",    "flag": "--force",      "message": "Force push requires approval." },
    { "command": "push",    "flag": "-f",           "message": "Force push requires approval." },
    { "command": "stash",   "subcommand": "drop",   "message": "git stash drop can lose stashed work." },
    { "command": "commit",  "flag_in_bundle": "a",  "message": "git commit -a stages all changes implicitly." }
  ],

  // Commands that must include at least one of the listed flags
  "require": [
    {
      "command": "restore",
      "one_of_flags": ["--staged", "-S"],
      "message": "git restore without --staged discards uncommitted changes."
    }
  ],

  // Path-scoping rules: all non-flag path args must start with allowed_prefixes
  "scoped_paths": [
    {
      "command": "add",
      "blocked_paths": ["."],
      "allowed_prefixes": ["my-project/"],
      "message": "git add must be scoped to my-project/. Use explicit paths."
    }
  ],

  // Per-branch push protection: diff against remote SHA and check file paths
  "protected_branches": {
    "main": {
      "allowed_path_prefixes": ["my-project/"],
      "message": "Direct pushes to main must only touch my-project/."
    }
  }
}
```

### Rule types

#### `blocked`

Blocks a git invocation when **all specified fields** match:

| Field | Matches | Example |
|---|---|---|
| `command` | `os.Args[1]` | `"push"` |
| `subcommand` | `os.Args[2]` | `"drop"` |
| `flag` | exact flag anywhere in args | `"--force"` |
| `flag_in_bundle` | single char inside short flag bundles | `"a"` catches `-a`, `-am`, `-cam` |

#### `require`

Requires at least one flag from `one_of_flags` to be present for the given command.

#### `scoped_paths`

For the given command, all non-flag positional arguments must start with one of the `allowed_prefixes`. Also blocks broad flags (`-A`, `--all`) when no explicit path argument is provided. Paths listed in `blocked_paths` are always rejected.

#### `worktree_only_branches`

When `true`:
- `git switch` is always blocked
- `git checkout` without a `--` separator is blocked
- `git checkout -- <file>` is allowed (file restore path)

Pair with `check_dirty_on_checkout: true` to also block `git checkout -- <file>` when the file has uncommitted changes.

#### `protected_branches`

When pushing to a listed branch, diffs the pushed commits against the remote tracking SHA and blocks if any changed file falls outside `allowed_path_prefixes`.

#### `require_upstream_before_bare_push`

When `true`, blocks `git push` (with no explicit refspec) when no upstream tracking branch is configured for the current branch.

---

## Testing

```sh
bash tests/run_tests.sh
```

The test suite builds the binary, creates an isolated temporary git repository, and runs all rule types end-to-end. It exits 0 on full pass.
