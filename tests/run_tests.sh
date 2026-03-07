#!/usr/bin/env bash
# tests/run_tests.sh — test suite for lawful-git
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# ── Build ──────────────────────────────────────────────────────────────────────
echo "Building lawful-git..."
(cd "$PROJECT_DIR" && go build -o lawful-git .) || { echo "❌ Build failed"; exit 1; }
echo "Build OK"
echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

REPO="$TMPDIR_ROOT/testrepo"
REMOTE="$TMPDIR_ROOT/remote.git"
BINDIR="$TMPDIR_ROOT/bin"
CLEAN_REPO="$TMPDIR_ROOT/cleanrepo"   # repo without .git-safety.json

mkdir -p "$REPO" "$BINDIR"

# Save the real git path BEFORE modifying PATH
REAL_GIT="$(command -v git)"

# Configure git identity (needed for commits)
GIT_CONFIG_GLOBAL_FILE="$TMPDIR_ROOT/.gitconfig"
export GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL_FILE"
"$REAL_GIT" config --global user.email "test@test.com"
"$REAL_GIT" config --global user.name "Test User"
"$REAL_GIT" config --global init.defaultBranch main
"$REAL_GIT" config --global advice.defaultBranchName false

# Init fake bare remote
"$REAL_GIT" init --bare "$REMOTE"

# Init test repo
"$REAL_GIT" init "$REPO"
"$REAL_GIT" -C "$REPO" remote add origin "$REMOTE"

# Create initial files
mkdir -p "$REPO/my-project" "$REPO/other"
echo "my-project initial" > "$REPO/my-project/file.txt"
echo "other initial"  > "$REPO/other/file.txt"

# Make initial commits (need 3+ so reset --soft HEAD~1 works later)
"$REAL_GIT" -C "$REPO" add .
"$REAL_GIT" -C "$REPO" commit -m "commit 1: initial"
echo "my-project v2" >> "$REPO/my-project/file.txt"
"$REAL_GIT" -C "$REPO" add my-project/file.txt
"$REAL_GIT" -C "$REPO" commit -m "commit 2: my-project update"
echo "my-project v3" >> "$REPO/my-project/file.txt"
"$REAL_GIT" -C "$REPO" add my-project/file.txt
"$REAL_GIT" -C "$REPO" commit -m "commit 3: my-project update 2"

# Push to fake remote to establish tracking
"$REAL_GIT" -C "$REPO" push -u origin main

# Copy lawful-git binary and config into test repo
cp "$PROJECT_DIR/lawful-git" "$BINDIR/lawful-git"
cp "$PROJECT_DIR/.git-safety.json" "$REPO/.git-safety.json"

# Create git symlink in BINDIR
ln -s "$BINDIR/lawful-git" "$BINDIR/git"

# Create clean repo (no .git-safety.json) for passthrough test
"$REAL_GIT" init "$CLEAN_REPO"
echo "clean" > "$CLEAN_REPO/readme.txt"
"$REAL_GIT" -C "$CLEAN_REPO" add .
"$REAL_GIT" -C "$CLEAN_REPO" commit -m "initial"

# Prepend fake bin dir to PATH so 'git' resolves to lawful-git
export PATH="$BINDIR:$PATH"

# Snapshot source repo state before tests so we can detect unintended modifications
SOURCE_STATUS_BEFORE=$("$REAL_GIT" -C "$PROJECT_DIR" status --porcelain 2>/dev/null || true)

# ── Test harness ───────────────────────────────────────────────────────────────

assert_blocked() {
    local desc="$1"
    shift
    local output exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "❌ FAIL: $desc (expected blocked, but exited 0)"
        FAIL=$((FAIL + 1))
    else
        echo "✅ PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_allowed() {
    local desc="$1"
    shift
    local output exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    # Fail only if lawful-git itself blocked it
    if echo "$output" | grep -qF "❌ BLOCKED:"; then
        echo "❌ FAIL: $desc (was BLOCKED by lawful-git)"
        FAIL=$((FAIL + 1))
    elif [ "$exit_code" -ne 0 ]; then
        echo "❌ FAIL: $desc (exited $exit_code: $output)"
        FAIL=$((FAIL + 1))
    else
        echo "✅ PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# assert_passes_through: lawful-git must NOT block it (git may still fail)
assert_passes_through() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qF "❌ BLOCKED:"; then
        echo "❌ FAIL: $desc (was BLOCKED by lawful-git)"
        FAIL=$((FAIL + 1))
    else
        echo "✅ PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# Safety check: ensure no test accidentally modifies the lawful-git source repo.
# We cd into the temp dir so any unqualified git command cannot touch PROJECT_DIR.
cd "$TMPDIR_ROOT"

# ── blocked (command) ──────────────────────────────────────────────────────────
echo "=== blocked (command) ==="
assert_blocked "git clean -fd blocked"   git -C "$REPO" clean -fd
assert_blocked "git rebase main blocked" git -C "$REPO" rebase main

# ── blocked (subcommand) ───────────────────────────────────────────────────────
echo ""
echo "=== blocked (subcommand) ==="
assert_blocked "git stash drop blocked"                        git -C "$REPO" stash drop
assert_blocked "git stash clear blocked"                       git -C "$REPO" stash clear
assert_blocked "git stash pop blocked"                         git -C "$REPO" stash pop
assert_allowed "git stash list allowed"                        git -C "$REPO" stash list
assert_blocked "git remote set-url blocked"                    git -C "$REPO" remote set-url origin https://evil.example
assert_blocked "git worktree remove blocked"                   git -C "$REPO" worktree remove foo

# ── blocked (flag) ────────────────────────────────────────────────────────────
echo ""
echo "=== blocked (flag) ==="
assert_blocked "git push --force blocked"             git -C "$REPO" push --force
assert_blocked "git push --force-with-lease blocked"  git -C "$REPO" push --force-with-lease
assert_blocked "git push -f blocked"                  git -C "$REPO" push -f
assert_blocked "git reset --hard blocked"             git -C "$REPO" reset --hard
assert_blocked "git reset --mixed blocked"            git -C "$REPO" reset --mixed
assert_blocked "git tag -d v1 blocked"                git -C "$REPO" tag -d v1
assert_allowed "git reset --soft HEAD~1 allowed"      git -C "$REPO" reset --soft HEAD~1
# Restore: go back to exactly where we were (ORIG_HEAD) to keep history linear with origin
"$REAL_GIT" -C "$REPO" reset --hard ORIG_HEAD

# ── blocked (--no-verify) ─────────────────────────────────────────────────────
echo ""
echo "=== blocked (--no-verify) ==="
assert_blocked "git commit --no-verify blocked"  git -C "$REPO" commit --no-verify -m "test"
assert_blocked "git push --no-verify blocked"    git -C "$REPO" push --no-verify
# git log does not accept --no-verify; we only verify lawful-git passes it through
assert_passes_through "git log --no-verify passes through (not gated)" git -C "$REPO" log --no-verify

# ── blocked (flag_in_bundle) ──────────────────────────────────────────────────
echo ""
echo "=== blocked (flag_in_bundle) ==="
assert_blocked "git commit -a -m blocked"   git -C "$REPO" commit -a -m "test"
assert_blocked "git commit -am blocked"     git -C "$REPO" commit -am "test"
# Stage a new file so 'git commit -m' succeeds
echo "staged content" > "$REPO/my-project/staged.txt"
"$REAL_GIT" -C "$REPO" add my-project/staged.txt
assert_allowed "git commit -m allowed"      git -C "$REPO" commit -m "test commit"

# ── require ───────────────────────────────────────────────────────────────────
echo ""
echo "=== require ==="
assert_blocked "git restore somefile blocked"           git -C "$REPO" restore my-project/file.txt
# Stage a file so 'git restore --staged' has something to unstage
echo "for staging" > "$REPO/my-project/tostage.txt"
"$REAL_GIT" -C "$REPO" add my-project/tostage.txt
assert_allowed "git restore --staged somefile allowed"  git -C "$REPO" restore --staged my-project/tostage.txt
# Discard the unstaged file
"$REAL_GIT" -C "$REPO" checkout -- my-project/tostage.txt 2>/dev/null || true
rm -f "$REPO/my-project/tostage.txt"

# ── scoped_paths ──────────────────────────────────────────────────────────────
echo ""
echo "=== scoped_paths ==="
assert_blocked "git add . blocked"                   git -C "$REPO" add .
assert_blocked "git add -A blocked"                  git -C "$REPO" add -A
# Provide a modified my-project file for the "allowed" add tests
echo "modified" >> "$REPO/my-project/file.txt"
assert_allowed "git add -A my-project/file.txt allowed"  git -C "$REPO" add -A my-project/file.txt
# Modify again (previous add staged it)
echo "modified2" >> "$REPO/my-project/file.txt"
assert_allowed "git add my-project/file.txt allowed"     git -C "$REPO" add my-project/file.txt
assert_blocked "git add other/file.txt blocked"      git -C "$REPO" add other/file.txt
# Clean up staged changes so later tests have a clean state
"$REAL_GIT" -C "$REPO" checkout HEAD -- my-project/file.txt

# ── worktree_only_branches ────────────────────────────────────────────────────
echo ""
echo "=== worktree_only_branches ==="
assert_blocked "git switch main blocked"          git -C "$REPO" switch main
assert_blocked "git checkout main blocked"        git -C "$REPO" checkout main
assert_allowed "git checkout -- clean file allowed" git -C "$REPO" checkout -- my-project/file.txt
# Make my-project/file.txt dirty
echo "dirty content" >> "$REPO/my-project/file.txt"
assert_blocked "git checkout -- dirty file blocked" git -C "$REPO" checkout -- my-project/file.txt
# Restore dirty file with real git
"$REAL_GIT" -C "$REPO" checkout -- my-project/file.txt

# ── protected_branches ────────────────────────────────────────────────────────
echo ""
echo "=== protected_branches ==="
# Commit touching non-my-project file → push should be blocked
echo "bad change" >> "$REPO/other/file.txt"
"$REAL_GIT" -C "$REPO" add other/file.txt
"$REAL_GIT" -C "$REPO" commit -m "touch non-my-project"
assert_blocked "push touching non-my-project file blocked" git -C "$REPO" push origin main
# Reset the bad commit
"$REAL_GIT" -C "$REPO" reset --hard HEAD~1

# Commit touching only my-project/ file → push should be allowed
echo "good change" >> "$REPO/my-project/file.txt"
"$REAL_GIT" -C "$REPO" add my-project/file.txt
"$REAL_GIT" -C "$REPO" commit -m "touch my-project only"
assert_allowed "push touching only my-project/ file allowed" git -C "$REPO" push origin main

# ── require_upstream_before_bare_push ──────────────────────────────────────────
echo ""
echo "=== require_upstream_before_bare_push ==="
# Create a branch with no upstream tracking
"$REAL_GIT" -C "$REPO" checkout -b no-upstream-branch
echo "no upstream content" > "$REPO/my-project/noup.txt"
"$REAL_GIT" -C "$REPO" add my-project/noup.txt
"$REAL_GIT" -C "$REPO" commit -m "commit on no-upstream branch"
assert_blocked "bare push without upstream blocked" git -C "$REPO" push
assert_passes_through "explicit push remote+branch allowed (no upstream)" git -C "$REPO" push origin no-upstream-branch
# Go back to main
"$REAL_GIT" -C "$REPO" checkout main
"$REAL_GIT" -C "$REPO" branch -D no-upstream-branch
# Bare push WITH upstream should be allowed (main has tracking)
assert_allowed "bare push with upstream allowed" git -C "$REPO" push

# ── push --delete / push -d ───────────────────────────────────────────────────
echo ""
echo "=== push --delete / push -d ==="
assert_blocked "git push --delete blocked" git -C "$REPO" push --delete origin somebranch
assert_blocked "git push -d blocked"       git -C "$REPO" push -d origin somebranch

# ── +refspec force push ───────────────────────────────────────────────────────
echo ""
echo "=== +refspec force push ==="
# +refspec is an alternative force-push syntax that should be caught by protected_branches
echo "plus refspec change" >> "$REPO/other/file.txt"
"$REAL_GIT" -C "$REPO" add other/file.txt
"$REAL_GIT" -C "$REPO" commit -m "change for +refspec test"
assert_blocked "push origin +main blocked (touches non-my-project)" git -C "$REPO" push origin +main
"$REAL_GIT" -C "$REPO" reset --hard HEAD~1

# ── subcommand with preceding flags ──────────────────────────────────────────
echo ""
echo "=== subcommand with preceding flags ==="
assert_blocked "git remote -v set-url blocked" git -C "$REPO" remote -v set-url origin https://evil.example

# ── --lawful-version ──────────────────────────────────────────────────────────
echo ""
echo "=== --lawful-version ==="
version_output=$(git --lawful-version 2>&1)
if echo "$version_output" | grep -qF "lawful-git version"; then
    echo "✅ PASS: git --lawful-version prints version"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: git --lawful-version did not print version (got: $version_output)"
    FAIL=$((FAIL + 1))
fi
# --version (without lawful-) should pass through to real git
assert_passes_through "git --version passes through to real git" git --version

# ── malformed config (fail-closed) ───────────────────────────────────────────
echo ""
echo "=== malformed config ==="
BAD_REPO="$TMPDIR_ROOT/badrepo"
"$REAL_GIT" init "$BAD_REPO"
echo "content" > "$BAD_REPO/file.txt"
"$REAL_GIT" -C "$BAD_REPO" add .
"$REAL_GIT" -C "$BAD_REPO" commit -m "initial"
echo "NOT VALID JSON{{{" > "$BAD_REPO/.git-safety.json"
assert_blocked "malformed .git-safety.json causes exit" git -C "$BAD_REPO" status

# ── --no-verify on other commands ─────────────────────────────────────────────
echo ""
echo "=== --no-verify on other commands ==="
# These commands will fail because there's nothing to cherry-pick/merge/am,
# but lawful-git should block them before git even tries.
assert_blocked "git cherry-pick --no-verify blocked" git -C "$REPO" cherry-pick --no-verify HEAD
assert_blocked "git merge --no-verify blocked"       git -C "$REPO" merge --no-verify somebranch
assert_blocked "git am --no-verify blocked"          git -C "$REPO" am --no-verify

# ── consent flow ──────────────────────────────────────────────────────────────
echo ""
echo "=== consent flow ==="
CONSENT_REPO="$TMPDIR_ROOT/consentrepo"
CONSENT_REMOTE="$TMPDIR_ROOT/consentremote.git"
"$REAL_GIT" init --bare "$CONSENT_REMOTE"
"$REAL_GIT" init "$CONSENT_REPO"
"$REAL_GIT" -C "$CONSENT_REPO" remote add origin "$CONSENT_REMOTE"
echo "content" > "$CONSENT_REPO/file.txt"
"$REAL_GIT" -C "$CONSENT_REPO" add .
"$REAL_GIT" -C "$CONSENT_REPO" commit -m "initial"
"$REAL_GIT" -C "$CONSENT_REPO" push -u origin main

# Config with a consent rule and a consent_command that always approves
cat > "$CONSENT_REPO/.git-safety.json" <<'EOF'
{
  "consent_command": "cat",
  "blocked": [
    { "command": "push", "flags": ["--force"], "action": "consent", "message": "Force push requires consent." },
    { "command": "clean", "message": "git clean is blocked." }
  ]
}
EOF

# First attempt without justification file → should exit non-zero with instructions
output=$(git -C "$CONSENT_REPO" push --force 2>&1) || true
if echo "$output" | grep -qF "CONSENT REQUIRED"; then
    echo "✅ PASS: consent rule prints instructions on first attempt"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: consent rule did not print instructions (got: $output)"
    FAIL=$((FAIL + 1))
fi

# Extract the consent file path from the output
consent_file=$(echo "$output" | grep -A1 "write your justification to:" | tail -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
if [ -n "$consent_file" ] && echo "$consent_file" | grep -q "^/"; then
    # Write justification and retry — consent_command is "cat" which always exits 0
    echo "Rebased to squash fixup commits" > "$consent_file"
    assert_passes_through "consent granted with justification file" git -C "$CONSENT_REPO" push --force
    # Verify consent file was cleaned up
    if [ ! -f "$consent_file" ]; then
        echo "✅ PASS: consent file cleaned up after use"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: consent file was not cleaned up"
        FAIL=$((FAIL + 1))
        rm -f "$consent_file"
    fi
else
    echo "❌ FAIL: could not extract consent file path from output"
    FAIL=$((FAIL + 1))
fi

# consent_command that denies (exits non-zero)
cat > "$CONSENT_REPO/.git-safety.json" <<'EOF'
{
  "consent_command": "false",
  "blocked": [
    { "command": "push", "flags": ["--force"], "action": "consent", "message": "Force push requires consent." }
  ]
}
EOF
# Set up a new consent file for a force push (need the path from a first attempt)
deny_output=$(git -C "$CONSENT_REPO" push --force 2>&1) || true
deny_consent_file=$(echo "$deny_output" | grep -A1 "write your justification to:" | tail -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
if [ -n "$deny_consent_file" ] && echo "$deny_consent_file" | grep -q "^/"; then
    echo "I really want to force push" > "$deny_consent_file"
    assert_blocked "consent_command denial blocks operation" git -C "$CONSENT_REPO" push --force
    # Verify consent file was cleaned up even after denial
    if [ ! -f "$deny_consent_file" ]; then
        echo "✅ PASS: consent file cleaned up after denial"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: consent file not cleaned up after denial"
        FAIL=$((FAIL + 1))
        rm -f "$deny_consent_file"
    fi
else
    echo "❌ FAIL: could not set up denial test"
    FAIL=$((FAIL + 1))
fi

# Empty justification file should be rejected
cat > "$CONSENT_REPO/.git-safety.json" <<'EOF'
{
  "consent_command": "cat",
  "blocked": [
    { "command": "push", "flags": ["--force"], "action": "consent", "message": "Force push requires consent." }
  ]
}
EOF
empty_output=$(git -C "$CONSENT_REPO" push --force 2>&1) || true
empty_consent_file=$(echo "$empty_output" | grep -A1 "write your justification to:" | tail -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
if [ -n "$empty_consent_file" ] && echo "$empty_consent_file" | grep -q "^/"; then
    echo "" > "$empty_consent_file"
    empty_retry_output=$(git -C "$CONSENT_REPO" push --force 2>&1) || true
    if echo "$empty_retry_output" | grep -qF "Justification file is empty"; then
        echo "✅ PASS: empty justification file rejected"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: empty justification file not rejected (got: $empty_retry_output)"
        FAIL=$((FAIL + 1))
    fi
    # Verify consent file was cleaned up even with empty justification
    if [ ! -f "$empty_consent_file" ]; then
        echo "✅ PASS: consent file cleaned up after empty justification"
        PASS=$((PASS + 1))
    else
        echo "❌ FAIL: consent file not cleaned up after empty justification"
        FAIL=$((FAIL + 1))
        rm -f "$empty_consent_file"
    fi
else
    echo "❌ FAIL: could not set up empty justification test"
    FAIL=$((FAIL + 1))
fi

# Validate consent_command receives correct JSON payload (repo, branch, args, message, justification)
VALIDATE_SCRIPT="$TMPDIR_ROOT/validate_consent.sh"
CONSENT_REPO_REALPATH=$(cd "$CONSENT_REPO" && pwd -P)
cat > "$VALIDATE_SCRIPT" <<SCRIPT
#!/bin/bash
# Read stdin JSON and validate all expected fields are present
input=\$(cat)
ok=true
for field in '"message"' '"justification"' '"args"' '"repo"' '"branch"'; do
    if ! echo "\$input" | grep -qF "\$field"; then
        echo "missing field: \$field" >&2
        ok=false
    fi
done
# Verify repo field contains the full native path (filepath.FromSlash applied)
if ! echo "\$input" | grep -qF "$CONSENT_REPO_REALPATH"; then
    echo "repo field does not contain expected full path: $CONSENT_REPO_REALPATH" >&2
    echo "got: \$input" >&2
    ok=false
fi
# Verify args contain --force
if ! echo "\$input" | grep -qF -- "--force"; then
    echo "args does not contain --force" >&2
    ok=false
fi
# Verify justification text is present
if ! echo "\$input" | grep -qF "payload test justification"; then
    echo "justification text not found" >&2
    ok=false
fi
if \$ok; then exit 0; else exit 1; fi
SCRIPT
chmod +x "$VALIDATE_SCRIPT"

cat > "$CONSENT_REPO/.git-safety.json" <<EOF
{
  "consent_command": "$VALIDATE_SCRIPT",
  "blocked": [
    { "command": "push", "flags": ["--force"], "action": "consent", "message": "Force push requires consent." }
  ]
}
EOF
payload_output=$(git -C "$CONSENT_REPO" push --force 2>&1) || true
payload_consent_file=$(echo "$payload_output" | grep -A1 "write your justification to:" | tail -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
if [ -n "$payload_consent_file" ] && echo "$payload_consent_file" | grep -q "^/"; then
    echo "payload test justification" > "$payload_consent_file"
    assert_passes_through "consent_command receives correct JSON payload" git -C "$CONSENT_REPO" push --force
else
    echo "❌ FAIL: could not set up payload validation test"
    FAIL=$((FAIL + 1))
fi

# Hard-blocked rules should still block even with consent_command configured
cat > "$CONSENT_REPO/.git-safety.json" <<'EOF'
{
  "consent_command": "cat",
  "blocked": [
    { "command": "push", "flags": ["--force"], "action": "consent", "message": "Force push requires consent." },
    { "command": "clean", "message": "git clean is blocked." }
  ]
}
EOF
assert_blocked "hard block still works with consent_command" git -C "$CONSENT_REPO" clean -fd

# Invalid action value in config
BADACTION_REPO="$TMPDIR_ROOT/badactionrepo"
"$REAL_GIT" init "$BADACTION_REPO"
echo "x" > "$BADACTION_REPO/f.txt"
"$REAL_GIT" -C "$BADACTION_REPO" add .
"$REAL_GIT" -C "$BADACTION_REPO" commit -m "initial"
cat > "$BADACTION_REPO/.git-safety.json" <<'EOF'
{ "blocked": [{ "command": "push", "flags": ["--force"], "action": "maybe", "message": "bad" }] }
EOF
assert_blocked "invalid action value rejected" git -C "$BADACTION_REPO" status
# Verify config errors include docs link
badaction_output=$(git -C "$BADACTION_REPO" status 2>&1) || true
if echo "$badaction_output" | grep -qF "github.com/asklar/lawful-git#configuration-reference"; then
    echo "✅ PASS: config error includes docs link"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: config error missing docs link (got: $badaction_output)"
    FAIL=$((FAIL + 1))
fi

# Invalid consent_command path
BAD_CONSENT_REPO="$TMPDIR_ROOT/badconsentrepo"
"$REAL_GIT" init "$BAD_CONSENT_REPO"
echo "x" > "$BAD_CONSENT_REPO/f.txt"
"$REAL_GIT" -C "$BAD_CONSENT_REPO" add .
"$REAL_GIT" -C "$BAD_CONSENT_REPO" commit -m "initial"
cat > "$BAD_CONSENT_REPO/.git-safety.json" <<'EOF'
{
  "consent_command": "/nonexistent/approval-tool",
  "blocked": [{ "command": "push", "flags": ["--force"], "action": "consent", "message": "bad" }]
}
EOF
assert_blocked "invalid consent_command path rejected" git -C "$BAD_CONSENT_REPO" status
bad_consent_output=$(git -C "$BAD_CONSENT_REPO" status 2>&1) || true
if echo "$bad_consent_output" | grep -qF "consent_command" && echo "$bad_consent_output" | grep -qF "/nonexistent/approval-tool"; then
    echo "✅ PASS: consent_command error names the bad path"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: consent_command error missing path details (got: $bad_consent_output)"
    FAIL=$((FAIL + 1))
fi
if echo "$bad_consent_output" | grep -qF "github.com/asklar/lawful-git#configuration-reference"; then
    echo "✅ PASS: consent_command error includes docs link"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: consent_command error missing docs link (got: $bad_consent_output)"
    FAIL=$((FAIL + 1))
fi

# ── additional edge cases ─────────────────────────────────────────────────────
echo ""
echo "=== additional edge cases ==="

# tag --delete (long form)
assert_blocked "git tag --delete v1 blocked" git -C "$REPO" tag --delete v1

# checkout -b blocked by worktree_only (no -- separator)
assert_blocked "git checkout -b newbranch blocked" git -C "$REPO" checkout -b newbranch

# add --all (long form of -A) blocked by scoped_paths
assert_blocked "git add --all blocked" git -C "$REPO" add --all

# restore -S (short form of --staged) allowed
echo "for short staged" > "$REPO/my-project/shortstage.txt"
"$REAL_GIT" -C "$REPO" add my-project/shortstage.txt
assert_allowed "git restore -S allowed" git -C "$REPO" restore -S my-project/shortstage.txt
rm -f "$REPO/my-project/shortstage.txt"

# global flag before blocked subcommand
assert_blocked "git --no-pager push --force blocked" git --no-pager -C "$REPO" push --force

# push with local:remote refspec syntax hitting protected_branches
echo "refspec change" >> "$REPO/other/file.txt"
"$REAL_GIT" -C "$REPO" add other/file.txt
"$REAL_GIT" -C "$REPO" commit -m "change for refspec test"
assert_blocked "push origin main:main blocked (non-my-project)" git -C "$REPO" push origin main:main
"$REAL_GIT" -C "$REPO" reset --hard HEAD~1

# empty config {} — valid JSON, no rules, should passthrough
EMPTY_CFG_REPO="$TMPDIR_ROOT/emptycfgrepo"
"$REAL_GIT" init "$EMPTY_CFG_REPO"
echo "content" > "$EMPTY_CFG_REPO/file.txt"
"$REAL_GIT" -C "$EMPTY_CFG_REPO" add .
"$REAL_GIT" -C "$EMPTY_CFG_REPO" commit -m "initial"
echo '{}' > "$EMPTY_CFG_REPO/.git-safety.json"
assert_allowed "empty config {} passes through" git -C "$EMPTY_CFG_REPO" status

# JSONC: line comments (//) are supported
JSONC_REPO="$TMPDIR_ROOT/jsoncrepo"
"$REAL_GIT" init "$JSONC_REPO"
echo "x" > "$JSONC_REPO/f.txt"
"$REAL_GIT" -C "$JSONC_REPO" add .
"$REAL_GIT" -C "$JSONC_REPO" commit -m "initial"
cat > "$JSONC_REPO/.git-safety.json" << 'EOF'
{
  // This is a line comment
  "blocked": [
    // Block clean
    { "command": "clean", "message": "no clean" }
  ]
}
EOF
assert_blocked "JSONC line comments work" git -C "$JSONC_REPO" clean -fd
assert_allowed "JSONC config loads without error" git -C "$JSONC_REPO" status

# JSONC: block comments (/* */) are supported
cat > "$JSONC_REPO/.git-safety.json" << 'EOF'
{
  /* Block comment explaining the config */
  "blocked": [
    { "command": "clean", /* inline block comment */ "message": "no clean" }
  ]
}
EOF
assert_blocked "JSONC block comments work" git -C "$JSONC_REPO" clean -fd

# JSONC: comments inside strings are preserved (not stripped)
cat > "$JSONC_REPO/.git-safety.json" << 'EOF'
{
  "blocked": [
    { "command": "clean", "message": "no clean // this is part of the message" }
  ]
}
EOF
clean_output=$(git -C "$JSONC_REPO" clean -fd 2>&1) || true
if echo "$clean_output" | grep -qF "// this is part of the message"; then
    echo "✅ PASS: comments inside strings are preserved"
    PASS=$((PASS + 1))
else
    echo "❌ FAIL: comment inside string was stripped (got: $clean_output)"
    FAIL=$((FAIL + 1))
fi

# blocked path after -- separator (git add -- .)
assert_blocked "git add -- . blocked" git -C "$REPO" add -- .

# absolute path prefix in config is rejected
ABS_PREFIX_REPO="$TMPDIR_ROOT/absprefixrepo"
"$REAL_GIT" init "$ABS_PREFIX_REPO"
echo "content" > "$ABS_PREFIX_REPO/file.txt"
"$REAL_GIT" -C "$ABS_PREFIX_REPO" add .
"$REAL_GIT" -C "$ABS_PREFIX_REPO" commit -m "initial"
cat > "$ABS_PREFIX_REPO/.git-safety.json" <<'EOF'
{ "scoped_paths": [{ "command": "add", "allowed_prefixes": ["/src/"], "message": "test" }] }
EOF
assert_blocked "absolute allowed_prefix rejected" git -C "$ABS_PREFIX_REPO" status

# unknown key in config (typo) is rejected
TYPO_REPO="$TMPDIR_ROOT/typorepo"
"$REAL_GIT" init "$TYPO_REPO"
echo "content" > "$TYPO_REPO/file.txt"
"$REAL_GIT" -C "$TYPO_REPO" add .
"$REAL_GIT" -C "$TYPO_REPO" commit -m "initial"
cat > "$TYPO_REPO/.git-safety.json" <<'EOF'
{ "worktree_only_branch": true }
EOF
assert_blocked "unknown key (typo) rejected" git -C "$TYPO_REPO" status

# empty command in blocked rule
EMPTY_CMD_REPO="$TMPDIR_ROOT/emptycmdrepo"
"$REAL_GIT" init "$EMPTY_CMD_REPO"
echo "x" > "$EMPTY_CMD_REPO/f.txt"
"$REAL_GIT" -C "$EMPTY_CMD_REPO" add .
"$REAL_GIT" -C "$EMPTY_CMD_REPO" commit -m "initial"
cat > "$EMPTY_CMD_REPO/.git-safety.json" <<'EOF'
{ "blocked": [{ "message": "no command" }] }
EOF
assert_blocked "empty command in blocked rule rejected" git -C "$EMPTY_CMD_REPO" status

# empty one_of_flags in require rule
EMPTY_FLAGS_REPO="$TMPDIR_ROOT/emptyflagsrepo"
"$REAL_GIT" init "$EMPTY_FLAGS_REPO"
echo "x" > "$EMPTY_FLAGS_REPO/f.txt"
"$REAL_GIT" -C "$EMPTY_FLAGS_REPO" add .
"$REAL_GIT" -C "$EMPTY_FLAGS_REPO" commit -m "initial"
cat > "$EMPTY_FLAGS_REPO/.git-safety.json" <<'EOF'
{ "require": [{ "command": "push", "one_of_flags": [], "message": "bad" }] }
EOF
assert_blocked "empty one_of_flags rejected" git -C "$EMPTY_FLAGS_REPO" status

# flags with short flag catches bundled usage
BUNDLE_REPO="$TMPDIR_ROOT/bundlerepo"
"$REAL_GIT" init "$BUNDLE_REPO"
echo "x" > "$BUNDLE_REPO/f.txt"
"$REAL_GIT" -C "$BUNDLE_REPO" add .
"$REAL_GIT" -C "$BUNDLE_REPO" commit -m "initial"
cat > "$BUNDLE_REPO/.git-safety.json" <<'EOF'
{ "blocked": [{ "command": "commit", "flags": ["-a"], "message": "no commit -a" }] }
EOF
echo "y" > "$BUNDLE_REPO/f.txt"
assert_blocked "short flag in flags catches bundled -am" git -C "$BUNDLE_REPO" commit -am "test"

# flag without leading dash
NO_DASH_REPO="$TMPDIR_ROOT/nodashrepo"
"$REAL_GIT" init "$NO_DASH_REPO"
echo "x" > "$NO_DASH_REPO/f.txt"
"$REAL_GIT" -C "$NO_DASH_REPO" add .
"$REAL_GIT" -C "$NO_DASH_REPO" commit -m "initial"
cat > "$NO_DASH_REPO/.git-safety.json" <<'EOF'
{ "blocked": [{ "command": "push", "flags": ["force"], "message": "bad" }] }
EOF
assert_blocked "flag without dash rejected" git -C "$NO_DASH_REPO" status

# subcommand starting with dash
DASH_SUB_REPO="$TMPDIR_ROOT/dashsubrepo"
"$REAL_GIT" init "$DASH_SUB_REPO"
echo "x" > "$DASH_SUB_REPO/f.txt"
"$REAL_GIT" -C "$DASH_SUB_REPO" add .
"$REAL_GIT" -C "$DASH_SUB_REPO" commit -m "initial"
cat > "$DASH_SUB_REPO/.git-safety.json" <<'EOF'
{ "blocked": [{ "command": "stash", "subcommand": "-v", "message": "bad" }] }
EOF
assert_blocked "subcommand starting with dash rejected" git -C "$DASH_SUB_REPO" status

# path traversal in allowed_prefixes
DOTDOT_REPO="$TMPDIR_ROOT/dotdotrepo"
"$REAL_GIT" init "$DOTDOT_REPO"
echo "x" > "$DOTDOT_REPO/f.txt"
"$REAL_GIT" -C "$DOTDOT_REPO" add .
"$REAL_GIT" -C "$DOTDOT_REPO" commit -m "initial"
cat > "$DOTDOT_REPO/.git-safety.json" <<'EOF'
{ "scoped_paths": [{ "command": "add", "allowed_prefixes": ["../escape/"], "message": "test" }] }
EOF
assert_blocked "path traversal in allowed_prefixes rejected" git -C "$DOTDOT_REPO" status

# require where command is blocked outright (dead code)
DEAD_REQ_REPO="$TMPDIR_ROOT/deadreqrepo"
"$REAL_GIT" init "$DEAD_REQ_REPO"
echo "x" > "$DEAD_REQ_REPO/f.txt"
"$REAL_GIT" -C "$DEAD_REQ_REPO" add .
"$REAL_GIT" -C "$DEAD_REQ_REPO" commit -m "initial"
cat > "$DEAD_REQ_REPO/.git-safety.json" <<'EOF'
{
  "blocked": [{ "command": "clean", "message": "blocked" }],
  "require": [{ "command": "clean", "one_of_flags": ["--dry-run"], "message": "require" }]
}
EOF
assert_blocked "require on bare-blocked command rejected" git -C "$DEAD_REQ_REPO" status

# require where all one_of_flags are also blocked (unsatisfiable)
UNSAT_REPO="$TMPDIR_ROOT/unsatrepo"
"$REAL_GIT" init "$UNSAT_REPO"
echo "x" > "$UNSAT_REPO/f.txt"
"$REAL_GIT" -C "$UNSAT_REPO" add .
"$REAL_GIT" -C "$UNSAT_REPO" commit -m "initial"
cat > "$UNSAT_REPO/.git-safety.json" <<'EOF'
{
  "blocked": [
    { "command": "push", "flags": ["--force"], "message": "no force" },
    { "command": "push", "flags": ["-f"], "message": "no force" }
  ],
  "require": [{ "command": "push", "one_of_flags": ["--force", "-f"], "message": "must force" }]
}
EOF
assert_blocked "unsatisfiable require (all flags blocked) rejected" git -C "$UNSAT_REPO" status

# ── passthrough ───────────────────────────────────────────────────────────────
echo ""
echo "=== passthrough ==="
assert_allowed "git status in repo without .git-safety.json" git -C "$CLEAN_REPO" status

# ── Verify source repo was not modified ───────────────────────────────────────
SOURCE_STATUS_AFTER=$("$REAL_GIT" -C "$PROJECT_DIR" status --porcelain 2>/dev/null || true)
if [ "$SOURCE_STATUS_BEFORE" != "$SOURCE_STATUS_AFTER" ]; then
    echo ""
    echo "❌ FAIL: Tests modified the source repo!"
    diff <(echo "$SOURCE_STATUS_BEFORE") <(echo "$SOURCE_STATUS_AFTER") || true
    FAIL=$((FAIL + 1))
else
    echo ""
    echo "✅ Source repo integrity verified"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
