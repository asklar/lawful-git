package main

import (
	"syscall"
	"unsafe"
)

// showPlatformDialog calls Win32 MessageBoxW directly.
// Runs in-process so our manifest's comctl32 v6 visual styles apply.
func showPlatformDialog(prompt string) bool {
	user32 := syscall.NewLazyDLL("user32.dll")
	messageBox := user32.NewProc("MessageBoxW")

	const (
		MB_YESNO       = 0x00000004
		MB_ICONWARNING = 0x00000030
		IDYES          = 6
	)

	text, _ := syscall.UTF16PtrFromString(prompt)
	title, _ := syscall.UTF16PtrFromString("lawful-git")

	ret, _, _ := messageBox.Call(
		0,
		uintptr(unsafe.Pointer(text)),
		uintptr(unsafe.Pointer(title)),
		uintptr(MB_YESNO|MB_ICONWARNING),
	)
	return ret == IDYES
}
