// mi-helper - v1.7
// Small console tool that talks to MediaInfo.dll (next to this exe).
//
//   mi-helper report <file>   full MediaInfo text report
//   mi-helper tc <file>       first-frame source timecode (prints nothing if none)
//   mi-helper info <file>     key=value lines: tc, format, profile, commercial, bitdepth, width, height, fps
//
// Called from the mpv Lua scripts. Exit code 0 on success, 1 on error.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

const (
	streamGeneral = 0
	streamVideo   = 1
	streamOther   = 4
	infoText      = 1
	infoName      = 0
)

type mediaInfo struct {
	h                                         uintptr
	new, open, inform, get, option, close, del *syscall.LazyProc
}

func wstr(s string) uintptr {
	p, _ := syscall.UTF16PtrFromString(s)
	return uintptr(unsafe.Pointer(p))
}

func gostr(p uintptr) string {
	if p == 0 {
		return ""
	}
	var buf []uint16
	for i := uintptr(0); ; i += 2 {
		c := *(*uint16)(unsafe.Pointer(p + i))
		if c == 0 {
			break
		}
		buf = append(buf, c)
	}
	return syscall.UTF16ToString(buf)
}

func load() (*mediaInfo, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}
	dll := syscall.NewLazyDLL(filepath.Join(filepath.Dir(exe), "MediaInfo.dll"))
	if err := dll.Load(); err != nil {
		return nil, fmt.Errorf("cannot load MediaInfo.dll: %w", err)
	}
	m := &mediaInfo{
		new:    dll.NewProc("MediaInfo_New"),
		open:   dll.NewProc("MediaInfo_Open"),
		inform: dll.NewProc("MediaInfo_Inform"),
		get:    dll.NewProc("MediaInfo_Get"),
		option: dll.NewProc("MediaInfo_Option"),
		close:  dll.NewProc("MediaInfo_Close"),
		del:    dll.NewProc("MediaInfo_Delete"),
	}
	m.h, _, _ = m.new.Call()
	if m.h == 0 {
		return nil, fmt.Errorf("MediaInfo_New failed")
	}
	return m, nil
}

func (m *mediaInfo) Get(kind, num int, param string) string {
	r, _, _ := m.get.Call(m.h, uintptr(kind), uintptr(num), wstr(param), infoText, infoName)
	return gostr(r)
}

func (m *mediaInfo) count(kind int) int {
	n := 0
	fmt.Sscan(m.Get(kind, 0, "StreamCount"), &n)
	return n
}

func (m *mediaInfo) timecode() string {
	// Video stream first (MOV tmcd linked to video, many camera formats)
	if tc := m.Get(streamVideo, 0, "TimeCode_FirstFrame"); tc != "" {
		return tc
	}
	// Then "Other" streams (QuickTime timecode track, MXF material/source package)
	for i := 0; i < m.count(streamOther); i++ {
		if tc := m.Get(streamOther, i, "TimeCode_FirstFrame"); tc != "" {
			return tc
		}
	}
	return m.Get(streamGeneral, 0, "TimeCode_FirstFrame")
}

func main() {
	if len(os.Args) != 3 || (os.Args[1] != "report" && os.Args[1] != "tc" && os.Args[1] != "info") {
		fmt.Fprintln(os.Stderr, "usage: mi-helper report|tc|info <file>")
		os.Exit(1)
	}
	m, err := load()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer m.del.Call(m.h)

	if r, _, _ := m.open.Call(m.h, wstr(os.Args[2])); r == 0 {
		fmt.Fprintln(os.Stderr, "MediaInfo could not open the file")
		os.Exit(1)
	}
	defer m.close.Call(m.h)

	switch os.Args[1] {
	case "tc":
		if tc := m.timecode(); tc != "" {
			fmt.Println(tc)
		}
		return
	case "info":
		fmt.Println("tc=" + m.timecode())
		fmt.Println("format=" + m.Get(streamVideo, 0, "Format"))
		fmt.Println("profile=" + m.Get(streamVideo, 0, "Format_Profile"))
		fmt.Println("commercial=" + m.Get(streamVideo, 0, "Format_Commercial_IfAny"))
		fmt.Println("bitdepth=" + m.Get(streamVideo, 0, "BitDepth"))
		fmt.Println("width=" + m.Get(streamVideo, 0, "Width"))
		fmt.Println("height=" + m.Get(streamVideo, 0, "Height"))
		fmt.Println("fps=" + m.Get(streamVideo, 0, "FrameRate"))
		return
	}
	m.option.Call(m.h, wstr("Inform"), wstr(""))
	r, _, _ := m.inform.Call(m.h, 0)
	fmt.Print(gostr(r))
}
