package main

import "core:os"
import d3d12 "vendor:directx/d3d12"
import "core:fmt"
import     "base:runtime"
import sdl "vendor:sdl3"
import     "core:log"


check :: proc(res: d3d12.HRESULT, message: string) {
    if (res >= 0) {
        return
    }

    fmt.printf("%v. Error code: %0x\n", message, u32(res))
    os.exit(-1)
}

sdl_log :: proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
	context = (transmute(^runtime.Context)userdata)^
	level: log.Level
	switch priority {
	case .INVALID, .TRACE, .VERBOSE, .DEBUG: level = .Debug
	case .INFO: level = .Info
	case .WARN: level = .Warning
	case .ERROR: level = .Error
	case .CRITICAL: level = .Fatal
	}
	log.logf(level, "SDL {}: {}", category, message)
}

sdl_assert :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: {}", sdl.GetError())
}
