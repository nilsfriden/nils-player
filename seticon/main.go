// seticon - v1.7 (build tool, runs under Windows or Wine)
// Replaces the icon of an exe: writes each image of an .ico as RT_ICON and
// rewrites the named icon group (mpv uses "IDI_ICON1" for its window/taskbar icon).
//
//   seticon <target.exe> <icon.ico> [group-name]
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

var (
	k32    = syscall.NewLazyDLL("kernel32.dll")
	begin  = k32.NewProc("BeginUpdateResourceW")
	update = k32.NewProc("UpdateResourceW")
	end    = k32.NewProc("EndUpdateResourceW")
)

const (
	rtIcon      = 3
	rtGroupIcon = 14
	langEnUS    = 1033
)

type entry struct {
	W, H, Colors, Reserved uint8
	Planes, BitCount       uint16
	Size, Offset           uint32
}

func wstr(s string) uintptr {
	p, _ := syscall.UTF16PtrFromString(s)
	return uintptr(unsafe.Pointer(p))
}

func die(f string, a ...any) {
	fmt.Fprintf(os.Stderr, f+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 3 {
		die("usage: seticon <target.exe> <icon.ico> [group-name]")
	}
	group := "IDI_ICON1"
	if len(os.Args) > 3 {
		group = os.Args[3]
	}
	ico, err := os.ReadFile(os.Args[2])
	if err != nil {
		die("%v", err)
	}
	r := bytes.NewReader(ico)
	var hdr struct{ Reserved, Type, Count uint16 }
	binary.Read(r, binary.LittleEndian, &hdr)
	if hdr.Type != 1 || hdr.Count == 0 {
		die("not an icon file")
	}
	entries := make([]entry, hdr.Count)
	binary.Read(r, binary.LittleEndian, entries)

	h, _, e := begin.Call(wstr(os.Args[1]), 0)
	if h == 0 {
		die("BeginUpdateResource: %v", e)
	}

	var grp bytes.Buffer
	binary.Write(&grp, binary.LittleEndian, hdr)
	for i, en := range entries {
		id := uint16(i + 1)
		data := ico[en.Offset : en.Offset+en.Size]
		ok, _, e := update.Call(h, rtIcon, uintptr(id), langEnUS,
			uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)))
		if ok == 0 {
			die("UpdateResource icon %d: %v", id, e)
		}
		binary.Write(&grp, binary.LittleEndian, struct {
			W, H, Colors, Reserved uint8
			Planes, BitCount       uint16
			Size                   uint32
			ID                     uint16
		}{en.W, en.H, en.Colors, en.Reserved, en.Planes, en.BitCount, en.Size, id})
	}
	g := grp.Bytes()
	if ok, _, e := update.Call(h, rtGroupIcon, wstr(group), langEnUS,
		uintptr(unsafe.Pointer(&g[0])), uintptr(len(g))); ok == 0 {
		die("UpdateResource group: %v", e)
	}
	if ok, _, e := end.Call(h, 0); ok == 0 {
		die("EndUpdateResource: %v", e)
	}
	fmt.Printf("set %d icon images in %s (group %s)\n", len(entries), os.Args[1], group)
}
