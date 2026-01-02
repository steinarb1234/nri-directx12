#+feature dynamic-literals

package main
import "core:os"
import "core:strings"
import d3d12 "vendor:directx/d3d12"
import "core:fmt"
import     "base:runtime"
import sdl "vendor:sdl3"
import     "core:log"
import nri "libs/NRI-odin"
import "core:path/filepath"


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

load_shader :: proc(graphics_api: nri.GraphicsAPI, shader_name: string, storage: ^[dynamic][]u8) -> nri.ShaderDesc {
    Shader :: struct {
        extension: cstring,
        stage    : nri.StageBits,
    }
    
    get_shader_extension :: #force_inline proc(graphicsAPI: nri.GraphicsAPI) -> string {
        if (graphicsAPI == .D3D11) {
            return ".dxbc";
        }
        else if (graphicsAPI == .D3D12) {
            return ".dxil";
        }
        return ".spirv";
    }

	// @(static) 
    shader_stage_bits := map[string]nri.StageBits {
        // {"",        nri.STAGEBITS_NONE},
        ".vs."     = {.VERTEX_SHADER},
        ".tcs."    = {.TESS_EVALUATION_SHADER},
        ".tes."    = {.TESS_EVALUATION_SHADER},
        ".gs."     = {.GEOMETRY_SHADER},
        ".fs."     = {.FRAGMENT_SHADER},
        ".cs."     = {.COMPUTE_SHADER},
        ".rgen."   = {.RAYGEN_SHADER},
        ".rmiss."  = {.MISS_SHADER},
        "<noimpl>" = {.INTERSECTION_SHADER},
        ".rchit."  = {.CLOSEST_HIT_SHADER},
        ".rahit."  = {.ANY_HIT_SHADER},
        "<noimpl>" = {.CALLABLE_SHADER},
    }

    shader_stage_filename := filepath.ext(shader_name) // e.g. "Triangle.vs" -> ".vs"
	shader_stage := shader_stage_bits[shader_stage_filename]

    SHADER_FOLDER :: "shaders/dxil/"
    shader_filename := strings.concatenate({SHADER_FOLDER, shader_name, get_shader_extension(graphics_api)})

	code, ok := os.read_entire_file(shader_filename, context.allocator)

	if !ok {
        fmt.eprintfln("Failed to load shader: %s", shader_filename)
        os.exit(-1)
	}

    shader_desc : nri.ShaderDesc = {
        stage         = shader_stage,
        bytecode      = rawptr(&code),
        size          = u64(len(code)),
        // entryPointName= "main",
        entryPointName= nil,
    }

    return shader_desc
}




