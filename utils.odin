package main

import "core:os"
import d3d12 "vendor:directx/d3d12"
import "core:fmt"
import     "base:runtime"
import sdl "vendor:sdl3"
import     "core:log"
import nri "libs/NRI-odin"


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
	if !ok do log.panicf("SDL Error: %s", sdl.GetError())
}

nri_message_callback :: proc "c" (
    level: nri.Message,
    file: cstring,
    line: u32,
    message: cstring,
    user_data: rawptr,
) {
    level_name := "INFO"
    switch level {
		case .INFO:    level_name = "INFO"
		case .WARNING: level_name = "WARN"
		case .ERROR:   level_name = "ERROR"
		case .MAX_NUM: level_name = "MAX_NUM"
    }
	context = runtime.default_context()
    fmt.printfln("[NRI %s] %s:%d - %s", level_name, file, line, message)
}

nri_abort_callback :: proc "c"(user_data: rawptr) {
	context = runtime.default_context()
    fmt.eprintfln("[NRI] AbortExecution called. Exiting.")
    nri.DestroyDevice(device)

    os.exit(-1)
}
