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

NRI_ABORT_ON_FAILURE :: proc(result: nri.Result, location := #caller_location) {
    if result != .Success {
        fmt.eprintfln("NRI failure: %v at %s:%d", result, location.file_path, location.line)
        os.exit(-1)
    }
}

NRI_Interface :: struct {
	using core: nri.Core_Interface,
	using swapchain: nri.Swap_Chain_Interface,
}

SwapChainTexture :: struct {
    acquire_semaphore: ^nri.Fence,
    release_semaphore: ^nri.Fence,
    texture          : ^nri.Texture,
    color_attachment : ^nri.Descriptor,
    attachment_format: nri.Format,
};

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

    window = sdl.CreateWindow("Hello World!", window_width, window_height, {.RESIZABLE}); sdl_assert(window != nil)
	defer sdl.DestroyWindow(window)

    NRI: NRI_Interface
    callback_interface := nri.Callback_Interface {
        MessageCallback = nri_message_callback,
        AbortExecution  = nri_abort_callback,
        user_arg        = nil,
    }

    nri_device : ^nri.Device
    graphics_api := nri.Graphics_API.D3D12
    device_creation_desc := nri.Device_Creation_Desc{
        // adapter_desc                          = ^Adapter_Desc,
        callback_interface                    = callback_interface,
        // allocation_callbacks                  = Allocation_Callbacks,
        // spirv_binding_offsets                 = SPIRV_Binding_Offsets,
        // vk_extensions                         = VK_Extensions,
        graphics_api                          = graphics_api,
        // shader_ext_register                   = u32,
        // shader_ext_space                      = u32,
        enable_validation                     = true,
        enable_graphics_api_validation        = true,
        // enable_d3d12_draw_parameters_emulation= true,
        // enable_d3d11_command_buffer_emulation = bool,
        // disable_vk_ray_tracing                = bool,
        // disable3rd_party_allocation_callbacks = bool,
    }
    if nri.CreateDevice(device_creation_desc, &nri_device) != .Success {
        fmt.printfln("Failed to init nri device")
        os.exit(-1)
    }
    
    NRI_ABORT_ON_FAILURE(nri.GetInterface(nri_device, "NriCoreInterface", size_of(NRI.core), &NRI.core))
    NRI_ABORT_ON_FAILURE(nri.GetInterface(nri_device, "NriSwapChainInterface", size_of(NRI.swapchain), &NRI.swapchain))

    window_handle := dxgi.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))

    command_queue : ^nri.Command_Queue
    NRI.GetCommandQueue(nri_device, .Graphics, &command_queue)

    frame_fence : ^nri.Fence
    NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &frame_fence))
    
    // Create the swapchain
    nri_swapchain_desc := nri.Swap_Chain_Desc{
        window           = {
            windows = nri.Windows_Window{window_handle},
            // x11    = X11_Window,
            // wayland= Wayland_Window,
            // metal  = Metal_Window,
        },
        command_queue     = command_queue,
        width             = u16(window_width),
        height            = u16(window_height),
        texture_num       = 2, // framebuffers
        format            = .BT709_G22_8BIT,
        vsync_interval    = 1,
        // queue_frame_num   = u8,
        // waitable          = bool,
        // allow_low_latency = bool,
    }
    swapchain : ^nri.Swap_Chain
    if NRI.CreateSwapChain(nri_device, nri_swapchain_desc, &swapchain) != .Success {
        fmt.printfln("Failed to create nri swachain")
        os.exit(-1)
    }

    swapchain_texture_num: u32
    swapchain_textures := NRI.GetSwapChainTextures(swapchain, &swapchain_texture_num)
    swapchain_format := NRI.GetTextureDesc(swapchain_textures[0]).format
    fmt.printfln("Swapchain format: %v", swapchain_format)
	fmt.printfln("Number of swapchain textures: %d", swapchain_texture_num)

	for i:u32=0; i<swapchain_texture_num; i+=1 {
		texture_view_desc := nri.Texture_2D_View_Desc{swapchain_textures[i], .Color_Attachment, swapchain_format, 0, 0, 0, 0}

		color_attachment : ^nri.Descriptor
		NRI_ABORT_ON_FAILURE(NRI.CreateTexture2DView(texture_view_desc, &color_attachment))

        SWAPCHAIN_SEMAPHORE :: ~u64(0)

		acquire_semaphore : ^nri.Fence
		NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, SWAPCHAIN_SEMAPHORE, &acquire_semaphore))
		// NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &acquire_semaphore))

		release_semaphore : ^nri.Fence
		NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, SWAPCHAIN_SEMAPHORE, &release_semaphore))
		// NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &release_semaphore))

		swapchain_texture := SwapChainTexture{
			acquire_semaphore = nil,
			release_semaphore = nil,
			texture           = swapchain_textures[i],
			color_attachment  = color_attachment,
			attachment_format = swapchain_format,
		}

        // swapchain_textures[i] = swapchain_texture

	}




    // Create vertex buffer
    vertex_buffer_desc := nri.Buffer_Desc{
        usage           = {.Vertex_Buffer},
        size            = size_of(triangleVertices),
        structure_stride= size_of(Vertex),
    }

    vertex_buffer : ^nri.Buffer
    NRI.CreateBuffer(nri_device, vertex_buffer_desc, &vertex_buffer)





}
