// Nils-Player launcher - v1.7
//
// Single-file wrapper: mpv, MediaInfo and the review config are embedded.
// First run unpacks them to %LOCALAPPDATA%\Nils-Player\<build-id>\ (a few seconds).
// Every later run just starts the cached mpv.exe directly, passing all arguments
// through, so "Open with", drag-onto-exe and file associations work.
// A new build gets a new build-id; older cached builds are removed.
package main

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

//go:embed payload.zip
var payload []byte

// Set at build time: -ldflags "-X main.buildID=<hash>"
var buildID = "dev"

const appName = "Nils-Player"

func fail(msg string) {
	t, _ := syscall.UTF16PtrFromString(appName)
	m, _ := syscall.UTF16PtrFromString(msg)
	syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(
		0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), 0x10)
	os.Exit(1)
}

func extract(dst string) error {
	zr, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return err
	}
	for _, f := range zr.File {
		p := filepath.Join(dst, filepath.FromSlash(f.Name))
		if !strings.HasPrefix(p, filepath.Clean(dst)+string(os.PathSeparator)) {
			return fmt.Errorf("bad path in payload: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(p)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(out, rc)
		rc.Close()
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func main() {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = os.TempDir()
	}
	root := filepath.Join(base, appName)
	dir := filepath.Join(root, buildID)
	marker := filepath.Join(dir, ".complete")

	if _, err := os.Stat(marker); err != nil {
		tmp := fmt.Sprintf("%s.tmp-%d", dir, os.Getpid())
		os.RemoveAll(tmp)
		if err := extract(tmp); err != nil {
			os.RemoveAll(tmp)
			fail("Could not unpack the player:\n" + err.Error())
		}
		os.WriteFile(filepath.Join(tmp, ".complete"), []byte(buildID), 0o644)
		if err := os.Rename(tmp, dir); err != nil {
			// Another instance may have finished first; use it if complete.
			os.RemoveAll(tmp)
			if _, err2 := os.Stat(marker); err2 != nil {
				os.RemoveAll(dir)
				fail("Could not install the player cache:\n" + err.Error())
			}
		}
	}

	cmd := exec.Command(filepath.Join(dir, "mpv.exe"), os.Args[1:]...)
	cmd.Dir = dir
	if err := cmd.Start(); err != nil {
		fail("Could not start mpv:\n" + err.Error())
	}

	// Cache left by the earlier name (mpv-review, v1.1-v1.3)
	os.RemoveAll(filepath.Join(base, "mpv-review"))

	// Remove cache folders from older builds
	if entries, err := os.ReadDir(root); err == nil {
		for _, e := range entries {
			if e.IsDir() && e.Name() != buildID && !strings.HasPrefix(e.Name(), buildID+".tmp-") {
				os.RemoveAll(filepath.Join(root, e.Name()))
			}
		}
	}
}
