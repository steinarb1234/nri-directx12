#+feature dynamic-literals

package main

import      "core:os"
import      "core:strings"
import      "core:fmt"
import      "core:log"
import      "core:path/filepath"
import      "base:runtime"
import sdl  "vendor:sdl3"
import stbi "vendor:stb/image"
import nri  "libs/NRI-odin"


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
    get_shader_extension :: #force_inline proc(graphicsAPI: nri.GraphicsAPI) -> string {
        #partial switch graphicsAPI {
            case .D3D12: return ".dxil"
            // case .D3D11: return ".dxbc"
            // case .VK:    return ".spirv"
            case:
                fmt.eprintfln("Unsupported Graphics API for shader loading: %s", graphicsAPI)
                os.exit(-1)
        }
    }

    shader_stage_filename := filepath.ext(shader_name) // f.x. "Triangle.vs" -> ".vs"
    shader_stage : nri.StageBits
    switch shader_stage_filename {
        case ".vs"   : shader_stage = {.VERTEX_SHADER}
        case ".tcs"  : shader_stage = {.TESS_CONTROL_SHADER}
        case ".tes"  : shader_stage = {.TESS_EVALUATION_SHADER}
        case ".gs"   : shader_stage = {.GEOMETRY_SHADER}
        case ".fs"   : shader_stage = {.FRAGMENT_SHADER}
        case ".cs"   : shader_stage = {.COMPUTE_SHADER}
        case ".rgen" : shader_stage = {.RAYGEN_SHADER}
        case ".rmiss": shader_stage = {.MISS_SHADER}
        // case "<noimpl>": shader_stage = {.INTERSECTION_SHADER}
        case ".rchit": shader_stage = {.CLOSEST_HIT_SHADER}
        case ".ahit" : shader_stage = {.ANY_HIT_SHADER}
        // case "<noimpl>": shader_stage = {.CALLABLE_SHADER}
        case:
            fmt.eprintfln("Failed to determine shader stage for shader: %s", shader_name)
            os.exit(-1)
    }
    fmt.printfln("Loading shader: %s, stage: %s", shader_name, shader_stage)

    SHADER_FOLDER :: "shaders/"
    shader_filename := strings.concatenate({SHADER_FOLDER, shader_name, get_shader_extension(graphics_api)})

	code, ok := os.read_entire_file(shader_filename, context.allocator)
	if !ok {
        fmt.eprintfln("Failed to load shader: %s", shader_filename)
        os.exit(-1)
	}

    shader_desc : nri.ShaderDesc = {
        stage         = shader_stage,
        bytecode      = raw_data(code),
        size          = u64(len(code)),
        entryPointName= "main",
    }

    return shader_desc
}

load_texture :: proc(path: cstring, texture: ^Texture, compute_avg_color_and_alpha_mode: bool) -> bool {
    fmt.printfln("Loading texture '%s'...", path)

    width, height, nr_channels : i32
    image_data := stbi.load(path, &width, &height, &nr_channels, 4)
    assert(image_data != nil)

    // Postprocess texture
    texture.name     = path
    // texture.mips     = 
    texture.AlphaMode= .OPAQUE
    texture.format   = .RGBA8_UNORM
    texture.width    = u16(width)
    texture.height   = u16(height)
    // texture.depth    = u16
    texture.mipNum   = 1
    texture.layerNum = 1

    return true
}



