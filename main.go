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
	Command    string   `json:"command"`
	Subcommand string   `json:"subcommand"`
	Flags      []string `json:"flags"`
	Message    string   `json:"message"`
	Action     string   `json:"action"` // "block" (default) or "consent"
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
	ConsentCommand                string                           `json:"consent_command"`
}

var (
	// version is set at build time via -ldflags.
	version = "dev"

	// realGit is the resolved path to the actual git binary (not lawful-git).
	realGit string
	// gitContext holds global git options (e.g. ["-C", "/path"]) prepended to
	// every subprocess call so they operate on the correct repository.
	gitContext []string
	// repoRoot is the resolved repo root path, set during loadConfig.
	repoRoot string
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
// and returns the index of the first subcommand argument, plus accumulated
// repo-locating options (e.g. -C, --git-dir, --work-tree) for subprocess calls.
// Global options are documented at https://git-scm.com/docs/git#_options .
func parseGlobalOpts(args []string) (cmdIdx int, repoContext []string) {
	i := 0
	for i < len(args) {
		a := args[i]
		// Options that consume the next token
		if (a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" ||
			a == "--namespace" || a == "--super-prefix" || a == "--exec-path") && i+1 < len(args) {
			if a == "-C" || a == "--git-dir" || a == "--work-tree" {
				repoContext = append(repoContext, a, args[i+1])
			}
			i += 2
			continue
		}
		// Options that embed their value with = (no space)
		if strings.HasPrefix(a, "--git-dir=") || strings.HasPrefix(a, "--work-tree=") ||
			strings.HasPrefix(a, "--namespace=") || strings.HasPrefix(a, "--super-prefix=") ||
			strings.HasPrefix(a, "--exec-path=") {
			if strings.HasPrefix(a, "--git-dir=") || strings.HasPrefix(a, "--work-tree=") {
				repoContext = append(repoContext, a)
			}
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
			return len(args), repoContext
		}
		// Anything else is the subcommand
		break
	}
	return i, repoContext
}

// parseConfigFile reads and parses a JSONC config file.
// Returns nil, nil if the file does not exist.
func parseConfigFile(path, label string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil
	}
	cleaned := stripJSONComments(string(data))
	var cfg Config
	dec := json.NewDecoder(strings.NewReader(cleaned))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("invalid %s: %w", label, err)
	}
	return &cfg, nil
}

// globalConfigPath returns the path to the global config file.
func globalConfigPath() string {
	if p := os.Getenv("LAWFUL_GIT_GLOBAL_CONFIG"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".lawful-git.json")
}

// mergeConfigs combines a global and repo config. Arrays are unioned,
// booleans use OR logic, maps are merged (repo wins on key conflict),
// and consent_command uses repo if set.
func mergeConfigs(global, repo *Config) *Config {
	if global == nil {
		return repo
	}
	if repo == nil {
		return global
	}
	merged := Config{
		Blocked:                       append(append([]BlockedRule{}, global.Blocked...), repo.Blocked...),
		Require:                       append(append([]RequireRule{}, global.Require...), repo.Require...),
		ScopedPaths:                   append(append([]ScopedPathRule{}, global.ScopedPaths...), repo.ScopedPaths...),
		WorktreeOnlyBranches:          global.WorktreeOnlyBranches || repo.WorktreeOnlyBranches,
		RequireUpstreamBeforeBarePush: global.RequireUpstreamBeforeBarePush || repo.RequireUpstreamBeforeBarePush,
		CheckDirtyOnCheckout:          global.CheckDirtyOnCheckout || repo.CheckDirtyOnCheckout,
		ConsentCommand:                global.ConsentCommand,
	}
	if repo.ConsentCommand != "" {
		merged.ConsentCommand = repo.ConsentCommand
	}
	// Merge protected_branches maps (repo wins on key conflict).
	merged.ProtectedBranches = make(map[string]ProtectedBranchConfig)
	for k, v := range global.ProtectedBranches {
		merged.ProtectedBranches[k] = v
	}
	for k, v := range repo.ProtectedBranches {
		merged.ProtectedBranches[k] = v
	}
	return &merged
}

// loadConfig reads global (~/.lawful-git.json) and repo (.git-safety.json)
// configs, merges them, and validates the result.
// Returns nil, nil when no config exists at all — intentional passthrough.
func loadConfig() (*Config, error) {
	// Load global config.
	var globalCfg *Config
	if gp := globalConfigPath(); gp != "" {
		var err error
		globalCfg, err = parseConfigFile(gp, filepath.Base(gp))
		if err != nil {
			return nil, err
		}
	}

	// Load repo config.
	var repoCfg *Config
	root, err := runGitOutput("rev-parse", "--show-toplevel")
	if err == nil {
		configPath := filepath.Join(root, ".git-safety.json")
		repoCfg, err = parseConfigFile(configPath, ".git-safety.json")
		if err != nil {
			return nil, err
		}
		repoRoot = filepath.FromSlash(root)
	}

	if globalCfg == nil && repoCfg == nil {
		return nil, nil
	}

	merged := mergeConfigs(globalCfg, repoCfg)
	if err := validateConfig(merged); err != nil {
		return nil, err
	}
	return merged, nil
}

// stripJSONComments removes // line comments and /* */ block comments from
// JSONC input, preserving strings (comments inside quoted strings are kept).
func stripJSONComments(s string) string {
	var buf strings.Builder
	buf.Grow(len(s))
	i := 0
	for i < len(s) {
		// String literal — copy verbatim including any // or /* inside.
		if s[i] == '"' {
			buf.WriteByte('"')
			i++
			for i < len(s) {
				if s[i] == '\\' && i+1 < len(s) {
					buf.WriteByte(s[i])
					buf.WriteByte(s[i+1])
					i += 2
					continue
				}
				if s[i] == '"' {
					buf.WriteByte('"')
					i++
					break
				}
				buf.WriteByte(s[i])
				i++
			}
			continue
		}
		// Line comment — skip to end of line.
		if i+1 < len(s) && s[i] == '/' && s[i+1] == '/' {
			for i < len(s) && s[i] != '\n' {
				i++
			}
			continue
		}
		// Block comment — skip to closing */.
		if i+1 < len(s) && s[i] == '/' && s[i+1] == '*' {
			i += 2
			for i+1 < len(s) && !(s[i] == '*' && s[i+1] == '/') {
				i++
			}
			if i+1 < len(s) {
				i += 2 // skip */
			}
			continue
		}
		buf.WriteByte(s[i])
		i++
	}
	return buf.String()
}

// cfgErr formats a config validation error with a consistent prefix.
func cfgErr(format string, args ...interface{}) error {
	return fmt.Errorf("invalid .git-safety.json: "+format, args...)
}

// validateConfig checks for misconfigurations that would silently
// misbehave at runtime.
func validateConfig(cfg *Config) error {
	if cfg.ConsentCommand != "" {
		if _, err := exec.LookPath(cfg.ConsentCommand); err != nil {
			return cfgErr("consent_command: %q not found: %v", cfg.ConsentCommand, err)
		}
	}

	// Collect blocked command+flag pairs for cross-rule checks.
	type cmdFlag struct{ cmd, flag string }
	blockedSet := make(map[cmdFlag]bool)
	// Collect commands that are blocked outright (no flag/subcommand qualifiers).
	bareBlockedCmds := make(map[string]bool)

	for i, rule := range cfg.Blocked {
		if rule.Command == "" {
			return cfgErr("blocked[%d]: command is required", i)
		}
		if rule.Message == "" {
			return cfgErr("blocked[%d]: message is required", i)
		}
		for j, f := range rule.Flags {
			if !strings.HasPrefix(f, "-") {
				return cfgErr("blocked[%d]: flags[%d] %q must start with '-'", i, j, f)
			}
		}
		if rule.Subcommand != "" && strings.HasPrefix(rule.Subcommand, "-") {
			return cfgErr("blocked[%d]: subcommand %q must not start with '-'", i, rule.Subcommand)
		}
		if rule.Action != "" && rule.Action != "block" && rule.Action != "consent" {
			return cfgErr("blocked[%d]: action must be \"block\" or \"consent\", got %q", i, rule.Action)
		}
		for _, f := range rule.Flags {
			blockedSet[cmdFlag{rule.Command, f}] = true
		}
		if len(rule.Flags) == 0 && rule.Subcommand == "" {
			bareBlockedCmds[rule.Command] = true
		}
	}

	for i, rule := range cfg.Require {
		if rule.Command == "" {
			return cfgErr("require[%d]: command is required", i)
		}
		if rule.Message == "" {
			return cfgErr("require[%d]: message is required", i)
		}
		if len(rule.OneOfFlags) == 0 {
			return cfgErr("require[%d]: one_of_flags must not be empty", i)
		}
		for _, f := range rule.OneOfFlags {
			if !strings.HasPrefix(f, "-") {
				return cfgErr("require[%d]: one_of_flags entry %q must start with '-'", i, f)
			}
		}
		// Cross-rule: if the command is blocked outright, this require is dead code.
		if bareBlockedCmds[rule.Command] {
			return cfgErr("require[%d]: command %q is already blocked outright; this rule can never be reached", i, rule.Command)
		}
		// Cross-rule: if every flag in one_of_flags is also blocked, the command is unsatisfiable.
		allBlocked := true
		for _, f := range rule.OneOfFlags {
			if !blockedSet[cmdFlag{rule.Command, f}] {
				allBlocked = false
				break
			}
		}
		if allBlocked {
			return cfgErr("require[%d]: every flag in one_of_flags for command %q is also in a blocked rule; the command can never succeed", i, rule.Command)
		}
	}

	for i, rule := range cfg.ScopedPaths {
		if rule.Command == "" {
			return cfgErr("scoped_paths[%d]: command is required", i)
		}
		if rule.Message == "" {
			return cfgErr("scoped_paths[%d]: message is required", i)
		}
		for _, p := range rule.AllowedPrefixes {
			if err := validatePathPrefix(p); err != nil {
				return cfgErr("scoped_paths[%d]: allowed_prefixes entry %q: %s", i, p, err)
			}
		}
		for _, p := range rule.BlockedPaths {
			if err := validatePathPrefix(p); err != nil {
				return cfgErr("scoped_paths[%d]: blocked_paths entry %q: %s", i, p, err)
			}
		}
	}
	for branch, rule := range cfg.ProtectedBranches {
		if rule.Message == "" {
			return cfgErr("protected_branches[%q]: message is required", branch)
		}
		for _, p := range rule.AllowedPathPrefixes {
			if err := validatePathPrefix(p); err != nil {
				return cfgErr("protected_branches[%q]: allowed_path_prefixes entry %q: %s", branch, p, err)
			}
		}
	}
	return nil
}

// validatePathPrefix rejects paths that are absolute or use .. traversal.
func validatePathPrefix(p string) error {
	if strings.HasPrefix(p, "/") {
		return fmt.Errorf("starts with '/'; git paths are relative to the repo root")
	}
	if p == ".." || strings.HasPrefix(p, "../") || strings.Contains(p, "/../") || strings.HasSuffix(p, "/..") {
		return fmt.Errorf("contains '..'; path traversal is not allowed")
	}
	return nil
}

// block prints a BLOCKED message to stderr and exits 1.
func block(msg string) {
	fmt.Fprintf(os.Stderr, "❌ BLOCKED: %s\n", msg)
	os.Exit(1)
}

// consentFilePath returns a deterministic temp file path for a consent request.
// The filename is derived from the repo root and the command args so that
// different operations in the same repo don't collide, but retrying the
// same command finds the same file.
func consentFilePath(args []string) string {
	key := repoRoot + "\x00" + strings.Join(args, "\x00")
	h := uint64(0)
	for _, c := range key {
		h = h*31 + uint64(c)
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("lawful-consent-%016x", h))
}

// requestConsent handles a consent-required rule. On first attempt (no justification
// file), it prints instructions and exits. On retry (file exists), it reads the
// justification and prompts the user via consent_command or a platform-native dialog.
func requestConsent(cfg *Config, msg string, args []string) {
	consentFile := consentFilePath(args)
	justification, err := os.ReadFile(consentFile)
	if err != nil {
		// First attempt: no justification file — instruct the caller.
		fmt.Fprintf(os.Stderr, "⚠️  CONSENT REQUIRED: %s\n", msg)
		fmt.Fprintf(os.Stderr, "To proceed, write your justification to:\n  %s\nThen retry the command.\n", consentFile)
		os.Exit(1)
	}

	// Justification file exists — prompt for consent.
	justText := strings.TrimSpace(string(justification))

	// Always remove the consent file after reading (one-time use).
	os.Remove(consentFile)

	if justText == "" {
		fmt.Fprintf(os.Stderr, "❌ BLOCKED: Justification file is empty.\n")
		os.Exit(1)
	}

	approved := false
	if cfg.ConsentCommand != "" {
		approved = runConsentCommand(cfg.ConsentCommand, msg, justText, args)
	} else {
		approved = showConsentDialog(msg, justText, args)
	}

	if !approved {
		block(msg)
	}
	// Consent granted — return to caller, which will exec real git.
}

// runConsentCommand invokes an external consent command.
// It sends context as JSON on stdin. Exit 0 = approved.
func runConsentCommand(command, msg, justification string, args []string) bool {
	branch, _ := runGitOutput("rev-parse", "--abbrev-ref", "HEAD")

	payload := struct {
		Message       string   `json:"message"`
		Justification string   `json:"justification"`
		Args          []string `json:"args"`
		Repo          string   `json:"repo"`
		Branch        string   `json:"branch"`
	}{msg, justification, args, repoRoot, branch}

	data, _ := json.Marshal(payload)
	cmd := exec.Command(command)
	cmd.Stdin = strings.NewReader(string(data))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run() == nil
}

// showConsentDialog shows a platform-native dialog asking the user to approve.
// Set LAWFUL_GIT_CONSOLE_CONSENT=1 to force terminal prompt instead of GUI.
func showConsentDialog(msg, justification string, args []string) bool {
	branch, _ := runGitOutput("rev-parse", "--abbrev-ref", "HEAD")
	if branch == "" {
		branch = "(unknown)"
	}

	prompt := fmt.Sprintf(
		"Repo:   %s\nBranch: %s\nAction: git %s\n\nRule: %s\n\nJustification from agent:\n\"%s\"\n\nAllow this operation?",
		repoRoot, branch, strings.Join(args, " "), msg, justification)

	if os.Getenv("LAWFUL_GIT_CONSOLE_CONSENT") != "" {
		return showDialogTerminal(prompt)
	}

	return showPlatformDialog(prompt)
}

// showDialogMacOS uses osascript to show a native dialog.
func showDialogMacOS(prompt string) bool {
	escaped := strings.ReplaceAll(prompt, `"`, `\"`)
	script := fmt.Sprintf(`display dialog "%s" buttons {"Deny", "Allow"} default button "Deny" with icon caution with title "lawful-git"`, escaped)
	cmd := exec.Command("osascript", "-e", script)
	out, err := cmd.Output()
	if err != nil {
		return showDialogTerminal(prompt)
	}
	return strings.Contains(string(out), "Allow")
}

// isWSL reports whether we're running inside Windows Subsystem for Linux.
func isWSL() bool {
	data, err := os.ReadFile("/proc/version")
	if err != nil {
		return false
	}
	lower := strings.ToLower(string(data))
	return strings.Contains(lower, "microsoft") || strings.Contains(lower, "wsl")
}

// showDialogWSL calls powershell.exe to show a Windows-native MessageBox from WSL.
func showDialogWSL(prompt string) bool {
	escaped := strings.ReplaceAll(prompt, `"`, "`\"")
	escaped = strings.ReplaceAll(escaped, "\n", "`n")
	script := fmt.Sprintf(
		`Add-Type -AssemblyName System.Windows.Forms; `+
			`$result = [System.Windows.Forms.MessageBox]::Show("%s", "lawful-git", "YesNo", "Warning"); `+
			`if ($result -eq "Yes") { exit 0 } else { exit 1 }`,
		escaped)
	cmd := exec.Command("powershell.exe", "-NoProfile", "-Command", script)
	err := cmd.Run()
	if err == nil {
		return true
	}
	if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() == 1 {
		return false
	}
	return showDialogTerminal(prompt)
}

// showDialogTerminal prompts on the terminal as a last resort.
func showDialogTerminal(prompt string) bool {
	// Open /dev/tty (or CON on Windows) to read directly from the terminal,
	// even if stdin is piped.
	ttyPath := "/dev/tty"
	if runtime.GOOS == "windows" {
		ttyPath = "CON"
	}
	tty, err := os.Open(ttyPath)
	if err != nil {
		// No terminal available — cannot get consent.
		fmt.Fprintf(os.Stderr, "❌ BLOCKED: No terminal available to prompt for consent.\n")
		return false
	}
	defer tty.Close()

	fmt.Fprintf(os.Stderr, "\n%s\n\nAllow? [y/N] ", prompt)
	buf := make([]byte, 8)
	n, _ := tty.Read(buf)
	answer := strings.TrimSpace(strings.ToLower(string(buf[:n])))
	return answer == "y" || answer == "yes"
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

// positionalArgs returns non-flag arguments. After a "--" separator,
// all remaining arguments are treated as positional regardless of prefix.
func positionalArgs(args []string) []string {
	var result []string
	endOfFlags := false
	for _, a := range args {
		if !endOfFlags && a == "--" {
			endOfFlags = true
			continue
		}
		if endOfFlags || !strings.HasPrefix(a, "-") {
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
	// Two-pass: check hard blocks first, then consent rules. This avoids
	// asking for consent when a different rule would block anyway.
	var pendingConsent []BlockedRule
	for _, rule := range cfg.Blocked {
		if rule.Command != command {
			continue
		}
		if rule.Subcommand != "" {
			// Find the first non-flag argument for subcommand matching,
			// since flags may precede the subcommand (e.g. "git remote -v set-url").
			firstPositional := ""
			for _, a := range rest {
				if !strings.HasPrefix(a, "-") {
					firstPositional = a
					break
				}
			}
			if firstPositional != rule.Subcommand {
				continue
			}
		}
		if len(rule.Flags) > 0 {
			matched := false
			for _, f := range rule.Flags {
				if hasFlag(rest, f) {
					matched = true
					break
				}
				// Single-char short flags (e.g. "-f") also match inside bundles
				if len(f) == 2 && f[0] == '-' && f[1] != '-' {
					if hasFlagInBundle(rest, string(f[1])) {
						matched = true
						break
					}
				}
			}
			if !matched {
				continue
			}
		}
		if rule.Action == "consent" {
			pendingConsent = append(pendingConsent, rule)
		} else {
			block(rule.Message)
		}
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
			// check_dirty_on_checkout: block if any file after -- has uncommitted changes.
			// Batch all targets into one git diff call for efficiency.
			if cfg.CheckDirtyOnCheckout {
				var targets []string
				afterSep := false
				for _, a := range rest {
					if a == "--" {
						afterSep = true
						continue
					}
					if afterSep {
						targets = append(targets, a)
					}
				}
				if len(targets) > 0 {
					diffArgs := append([]string{"diff", "HEAD", "--name-only", "--"}, targets...)
					dirty, err := runGitOutput(diffArgs...)
					if err == nil && dirty != "" {
						block(fmt.Sprintf("One or more files have uncommitted changes. Checkout would discard them: %s", dirty))
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

	// --- consent rules (deferred until all hard rules have passed) ---
	for _, rule := range pendingConsent {
		requestConsent(cfg, rule.Message, args)
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
		// Strip leading '+' (force-push prefix on individual refspecs)
		refspec = strings.TrimPrefix(refspec, "+")
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

	// Handle --lawful-version before anything else (no git lookup needed)
	if hasFlag(args, "--lawful-version") {
		fmt.Printf("lawful-git version %s\n", version)
		os.Exit(0)
	}

	// Parse git global options (e.g. -C <path>) to locate the subcommand
	// and set up gitContext for all subprocess calls.
	cmdIdx, repoCtx := parseGlobalOpts(args)
	if len(repoCtx) > 0 {
		gitContext = repoCtx
	}

	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "lawful-git: config error: %v\n", err)
		fmt.Fprintf(os.Stderr, "See https://github.com/asklar/lawful-git#configuration-reference\n")
		os.Exit(1)
	}

	if cfg != nil && cmdIdx < len(args) {
		// Pass only the subcommand and its own args to applyRules,
		// not the global options already handled above.
		applyRules(cfg, args[cmdIdx:])
	}

	execRealGit(args)
}
