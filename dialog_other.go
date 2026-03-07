//go:build !windows

package main

import (
	"os/exec"
	"runtime"
)

// showPlatformDialog tries WSL (powershell.exe), macOS (osascript),
// Linux (zenity), then falls back to terminal.
func showPlatformDialog(prompt string) bool {
	switch {
	case isWSL():
		if _, err := exec.LookPath("powershell.exe"); err == nil {
			return showDialogWSL(prompt)
		}
		return showDialogTerminal(prompt)
	case runtime.GOOS == "darwin":
		return showDialogMacOS(prompt)
	default:
		if _, err := exec.LookPath("zenity"); err == nil {
			return showDialogZenity(prompt)
		}
		return showDialogTerminal(prompt)
	}
}

func showDialogZenity(prompt string) bool {
	cmd := exec.Command("zenity", "--question", "--title=lawful-git",
		"--text="+prompt, "--ok-label=Allow", "--cancel-label=Deny",
		"--icon-name=dialog-warning", "--width=400")
	return cmd.Run() == nil
}
