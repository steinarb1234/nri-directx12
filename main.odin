package main

import "core:fmt"
import "core:mem"
import "core:sys/windows"
import "core:os"
import sdl "vendor:sdl3"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"

import nri "libs/NRI-odin"


NUM_RENDERTARGETS :: 2
window : ^sdl.Window
window_height : i32 = 768
window_width  : i32 = 1024

SHADER_FILE :: "shaders.hlsl"
shaders_hlsl := #load(SHADER_FILE)



Vertex :: struct{
    position: [3]f32,
    color:    [3]f32,
}

triangleVertices := [3]Vertex{
    {{0.0,   0.5, 0.0}, {1, 0, 0}},
    {{0.5,  -0.5, 0.0}, {0, 1, 0}},
    {{-0.5, -0.5, 0.0}, {0, 0, 1}},
}







main :: proc() {
    // Init SDL and create window
    ok := sdl.Init({.AUDIO, .VIDEO}); sdl_assert(ok) 
    defer sdl.Quit()

    // wx := i32(640)
    // wy := i32(480)
    window = sdl.CreateWindow("Hello World!", window_width, window_height, {.OPENGL, .RESIZABLE}); sdl_assert(window != nil)
	defer sdl.DestroyWindow(window)

    


    nri_interface : nri.Core_Interface
    nri_device : ^nri.Device
    graphics_api := nri.Graphics_API.D3D12
    device_creation_desc := nri.Device_Creation_Desc{
        // adapter_desc                          = ^Adapter_Desc,
        // callback_interface                    = Callback_Interface,
        // allocation_callbacks                  = Allocation_Callbacks,
        // spirv_binding_offsets                 = SPIRV_Binding_Offsets,
        // vk_extensions                         = VK_Extensions,
        graphics_api                          = graphics_api,
        // shader_ext_register                   = u32,
        // shader_ext_space                      = u32,
        enable_validation                     = true,
        enable_graphics_api_validation        = true,
        // enable_d3d12_draw_parameters_emulation= bool,
        // enable_d3d11_command_buffer_emulation = bool,
        // disable_vk_ray_tracing                = bool,
        // disable3rd_party_allocation_callbacks = bool,
    }
    if nri.CreateDevice(device_creation_desc, &nri_device) != .Success {
        fmt.printfln("Failed to init nri device")
        os.exit(-1)
    }

    window_handle := dxgi.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
    // hwnd : nri.Window = nri.Window(window_handle)
    hwnd : nri.Window

    // Create the swapchain
    nri_swapchain_desc := nri.Swap_Chain_Desc{
        window           = {
            windows = nri.Windows_Window{window_handle},
            // x11    = X11_Window,
            // wayland= Wayland_Window,
            // metal  = Metal_Window,
        },
        // command_queue    = ^Command_Queue,
        width             = u16(window_width),
        height            = u16(window_height),
        texture_num       = 2, // framebuffers
        format            = .BT709_G22_8BIT,
        vsync_interval    = 1,
        // queue_frame_num   = u8,
        // waitable          = bool,
        // allow_low_latency = bool,
    }
    nri_swapchain : ^nri.Swap_Chain
    
    swapchain_interface : ^nri.Swap_Chain_Interface
    if swapchain_interface.CreateSwapChain(nri_device, nri_swapchain_desc, &nri_swapchain) != .Success {
        fmt.printfln("Failed to create nri swachain")
        os.exit(-1)
    }


    // Create vertex buffer
    vertex_buffer_desc := nri.Buffer_Desc{
        usage           = {.Vertex_Buffer},
        size            = size_of(triangleVertices),
        structure_stride= size_of(Vertex),
    }

    vertex_buffer : ^nri.Buffer
    nri_interface.CreateBuffer(nri_device, vertex_buffer_desc, &vertex_buffer)





}