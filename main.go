package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// BlockedRule represents a rule that blocks a git command or flag.
type BlockedRule struct {
	Command      string `json:"command"`
	Subcommand   string `json:"subcommand"`
	Flag         string `json:"flag"`
	FlagInBundle string `json:"flag_in_bundle"`
	Message      string `json:"message"`
}

// RequireRule requires at least one of the listed flags to be present.
type RequireRule struct {
	Command    string   `json:"command"`
	OneOfFlags []string `json:"one_of_flags"`
	Message    string   `json:"message"`
}

// ScopedPathRule enforces that all non-flag path arguments start with an allowed prefix.
type ScopedPathRule struct {
	Command         string   `json:"command"`
	BlockedPaths    []string `json:"blocked_paths"`
	AllowedPrefixes []string `json:"allowed_prefixes"`
	Message         string   `json:"message"`
}

// ProtectedBranchConfig specifies the allowed path prefixes for pushes to a branch.
type ProtectedBranchConfig struct {
	AllowedPathPrefixes []string `json:"allowed_path_prefixes"`
	Message             string   `json:"message"`
}

// Config is the top-level .git-safety.json structure.
type Config struct {
	Blocked                       []BlockedRule                    `json:"blocked"`
	Require                       []RequireRule                    `json:"require"`
	ScopedPaths                   []ScopedPathRule                 `json:"scoped_paths"`
	ProtectedBranches             map[string]ProtectedBranchConfig `json:"protected_branches"`
	WorktreeOnlyBranches          bool                             `json:"worktree_only_branches"`
	RequireUpstreamBeforeBarePush bool                             `json:"require_upstream_before_bare_push"`
	CheckDirtyOnCheckout          bool                             `json:"check_dirty_on_checkout"`
}

var (
	// realGit is the resolved path to the actual git binary (not lawful-git).
	realGit string
	// gitContext holds global git options (e.g. ["-C", "/path"]) prepended to
	// every subprocess call so they operate on the correct repository.
	gitContext []string
)

// findRealGit locates the real git binary by walking PATH, skipping the current executable.
func findRealGit() (string, error) {
	self, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("cannot determine own path: %w", err)
	}
	self, err = filepath.EvalSymlinks(self)
	if err != nil {
		return "", fmt.Errorf("cannot resolve own path: %w", err)
	}

	gitName := "git"
	if runtime.GOOS == "windows" {
		gitName = "git.exe"
	}

	pathEnv := os.Getenv("PATH")
	for _, dir := range filepath.SplitList(pathEnv) {
		candidate := filepath.Join(dir, gitName)
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() {
			continue
		}
		resolved, err := filepath.EvalSymlinks(candidate)
		if err != nil {
			continue
		}
		if resolved == self {
			continue
		}
		return candidate, nil
	}
	return "", fmt.Errorf("real git binary not found in PATH")
}

// runGitOutput runs the real git with args (prepending gitContext) and returns stdout, trimmed.
func runGitOutput(args ...string) (string, error) {
	fullArgs := append(gitContext, args...)
	cmd := exec.Command(realGit, fullArgs...)
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

// parseGlobalOpts skips git's global options (like -C, -c, --git-dir) in args
// and returns the index of the first subcommand argument, plus the -C path if given.
// Global options are documented at https://git-scm.com/docs/git#_options .
func parseGlobalOpts(args []string) (cmdIdx int, dirChange string) {
	i := 0
	for i < len(args) {
		a := args[i]
		// Options that consume the next token
		if (a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" ||
			a == "--namespace" || a == "--super-prefix" || a == "--exec-path") && i+1 < len(args) {
			if a == "-C" {
				dirChange = args[i+1]
			}
			i += 2
			continue
		}
		// Options that embed their value with = (no space)
		if strings.HasPrefix(a, "--git-dir=") || strings.HasPrefix(a, "--work-tree=") ||
			strings.HasPrefix(a, "--namespace=") || strings.HasPrefix(a, "--super-prefix=") ||
			strings.HasPrefix(a, "--exec-path=") {
			i++
			continue
		}
		// Boolean global flags
		if a == "--bare" || a == "--no-pager" || a == "--paginate" ||
			a == "-p" || a == "-P" || a == "--no-optional-locks" ||
			a == "--no-replace-objects" || a == "--literal-pathspecs" ||
			a == "--glob-pathspecs" || a == "--noglob-pathspecs" ||
			a == "--icase-pathspecs" || a == "--html-path" ||
			a == "--man-path" || a == "--info-path" {
			i++
			continue
		}
		// Version / help — no subcommand follows
		if a == "--version" || a == "-v" || a == "--help" || a == "-h" {
			return len(args), dirChange
		}
		// Anything else is the subcommand
		break
	}
	return i, dirChange
}

// loadConfig reads and parses .git-safety.json from the repo root.
// Returns nil, nil when not in a git repo or when no config file exists.
func loadConfig() (*Config, error) {
	root, err := runGitOutput("rev-parse", "--show-toplevel")
	if err != nil {
		return nil, nil
	}

	configPath := filepath.Join(root, ".git-safety.json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, nil
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("invalid .git-safety.json: %w", err)
	}
	return &cfg, nil
}

// block prints a BLOCKED message to stderr and exits 1.
func block(msg string) {
	fmt.Fprintf(os.Stderr, "❌ BLOCKED: %s\n", msg)
	os.Exit(1)
}

// hasFlag reports whether the exact flag string appears in args.
func hasFlag(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

// hasFlagInBundle reports whether the single character char appears inside
// any short-flag bundle in args (e.g. char="a" matches "-a", "-am", "-cam").
func hasFlagInBundle(args []string, char string) bool {
	if len(char) != 1 {
		return false
	}
	c := char[0]
	for _, a := range args {
		// Must start with '-' and second char must not be '-' (not a long flag)
		if len(a) >= 2 && a[0] == '-' && a[1] != '-' {
			for i := 1; i < len(a); i++ {
				if a[i] == c {
					return true
				}
			}
		}
	}
	return false
}

// positionalArgs returns non-flag arguments (those not starting with '-').
func positionalArgs(args []string) []string {
	var result []string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			result = append(result, a)
		}
	}
	return result
}

// applyRules checks all configured rules against the parsed argv and calls block() on violation.
func applyRules(cfg *Config, args []string) {
	if len(args) == 0 {
		return
	}

	command := args[0]
	rest := args[1:]

	// --- blocked rules ---
	for _, rule := range cfg.Blocked {
		if rule.Command != command {
			continue
		}
		if rule.Subcommand != "" {
			if len(rest) == 0 || rest[0] != rule.Subcommand {
				continue
			}
		}
		if rule.Flag != "" {
			if !hasFlag(rest, rule.Flag) {
				continue
			}
		}
		if rule.FlagInBundle != "" {
			if !hasFlagInBundle(rest, rule.FlagInBundle) {
				continue
			}
		}
		block(rule.Message)
	}

	// --- require rules ---
	for _, rule := range cfg.Require {
		if rule.Command != command {
			continue
		}
		found := false
		for _, f := range rule.OneOfFlags {
			if hasFlag(rest, f) {
				found = true
				break
			}
		}
		if !found {
			block(rule.Message)
		}
	}

	// --- scoped_paths rules ---
	for _, rule := range cfg.ScopedPaths {
		if rule.Command != command {
			continue
		}

		hasBroadFlag := hasFlag(rest, "-A") || hasFlag(rest, "--all")
		posArgs := positionalArgs(rest)

		// Block explicitly listed paths
		for _, arg := range posArgs {
			for _, bp := range rule.BlockedPaths {
				if arg == bp {
					block(rule.Message)
				}
			}
		}

		// Block broad flags when no explicit path is given
		if hasBroadFlag && len(posArgs) == 0 {
			block(rule.Message)
		}

		// All positional args must start with an allowed prefix
		for _, arg := range posArgs {
			allowed := false
			for _, prefix := range rule.AllowedPrefixes {
				if strings.HasPrefix(arg, prefix) {
					allowed = true
					break
				}
			}
			if !allowed {
				block(rule.Message)
			}
		}
	}

	// --- worktree_only_branches ---
	if cfg.WorktreeOnlyBranches {
		if command == "switch" {
			block("git switch is not allowed in worktree-only mode. Use git checkout -- <file> for file restores.")
		}
		if command == "checkout" {
			hasSeparator := false
			for _, a := range rest {
				if a == "--" {
					hasSeparator = true
					break
				}
			}
			if !hasSeparator {
				block("git checkout without -- is not allowed in worktree-only mode. Use git checkout -- <file> for file restores.")
			}
			// check_dirty_on_checkout: block if any file after -- has uncommitted changes
			if cfg.CheckDirtyOnCheckout {
				afterSep := false
				for _, a := range rest {
					if a == "--" {
						afterSep = true
						continue
					}
					if afterSep && !strings.HasPrefix(a, "-") {
						diff, err := runGitOutput("diff", "HEAD", "--", a)
						if err == nil && diff != "" {
							block(fmt.Sprintf("File '%s' has uncommitted changes. Checkout would discard them.", a))
						}
					}
				}
			}
		}
	}

	// --- require_upstream_before_bare_push ---
	if cfg.RequireUpstreamBeforeBarePush && command == "push" {
		_, branch := parsePushTarget(rest)
		if branch == "" {
			_, err := runGitOutput("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
			if err != nil {
				block("No upstream configured. Use 'git push <remote> <branch>' to push explicitly.")
			}
		}
	}

	// --- protected_branches ---
	if len(cfg.ProtectedBranches) > 0 && command == "push" {
		remote, branch := parsePushTarget(rest)
		if branch == "" {
			branch, _ = runGitOutput("rev-parse", "--abbrev-ref", "HEAD")
		}

		if rule, ok := cfg.ProtectedBranches[branch]; ok {
			remoteBranch := remote + "/" + branch
			remoteSHA, err := runGitOutput("rev-parse", remoteBranch)
			if err != nil || remoteSHA == "" {
				// Remote branch doesn't exist yet; can't check — allow
				return
			}

			files, err := runGitOutput("diff", "--name-only", remoteSHA+"..HEAD")
			if err != nil || files == "" {
				return
			}

			for _, f := range strings.Split(files, "\n") {
				if f == "" {
					continue
				}
				allowed := false
				for _, prefix := range rule.AllowedPathPrefixes {
					if strings.HasPrefix(f, prefix) {
						allowed = true
						break
					}
				}
				if !allowed {
					block(rule.Message)
				}
			}
		}
	}
}

// parsePushTarget parses `git push` args to determine the remote and branch.
// Returns ("origin", "") when no explicit remote/refspec is provided.
func parsePushTarget(args []string) (remote, branch string) {
	remote = "origin"

	var positional []string
	skipNext := false
	endOfFlags := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if skipNext {
			skipNext = false
			continue
		}
		if a == "--" {
			endOfFlags = true
			continue
		}
		if !endOfFlags && strings.HasPrefix(a, "-") {
			// Flags that consume the next argument
			switch a {
			case "--repo", "--receive-pack", "--exec", "-o", "--push-option":
				skipNext = true
			}
			continue
		}
		positional = append(positional, a)
	}

	if len(positional) >= 1 {
		remote = positional[0]
	}
	if len(positional) >= 2 {
		refspec := positional[1]
		// Handle local:remote refspec syntax — take the remote side
		if idx := strings.LastIndex(refspec, ":"); idx >= 0 {
			refspec = refspec[idx+1:]
		}
		// Strip refs/heads/ prefix
		refspec = strings.TrimPrefix(refspec, "refs/heads/")
		branch = refspec
	}

	return remote, branch
}

// execRealGit replaces the current process with the real git on Unix,
// or runs it as a child and forwards the exit code on Windows.
func execRealGit(args []string) {
	if runtime.GOOS == "windows" {
		cmd := exec.Command(realGit, args...)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		err := cmd.Run()
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok {
				os.Exit(exitErr.ExitCode())
			}
			os.Exit(1)
		}
		os.Exit(0)
	}

	// Unix: exec() replaces the process entirely
	realGitPath, err := exec.LookPath(realGit)
	if err != nil {
		realGitPath = realGit
	}
	argv := append([]string{realGitPath}, args...)
	if err := syscall.Exec(realGitPath, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "lawful-git: exec failed: %v\n", err)
		os.Exit(1)
	}
}

func main() {
	var err error
	realGit, err = findRealGit()
	if err != nil {
		fmt.Fprintf(os.Stderr, "lawful-git: %v\n", err)
		os.Exit(1)
	}

	args := os.Args[1:]

	// Parse git global options (e.g. -C <path>) to locate the subcommand
	// and set up gitContext for all subprocess calls.
	cmdIdx, dirChange := parseGlobalOpts(args)
	if dirChange != "" {
		gitContext = []string{"-C", dirChange}
	}

	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "lawful-git: config error: %v\n", err)
		// Fall through: continue without rules rather than hard-failing
	}

	if cfg != nil && cmdIdx < len(args) {
		// Pass only the subcommand and its own args to applyRules,
		// not the global options already handled above.
		applyRules(cfg, args[cmdIdx:])
	}

	execRealGit(args)
}
