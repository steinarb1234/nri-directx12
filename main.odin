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
    if result != .SUCCESS {
        fmt.eprintfln("NRI failure: %v at %s:%d", result, location.file_path, location.line)
        os.exit(-1)
    }
}

NRI_Interface :: struct {
	using core: nri.CoreInterface,
	using swapchain: nri.SwapChainInterface,
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
    callback_interface := nri.CallbackInterface {
        MessageCallback = nri_message_callback,
        AbortExecution  = nri_abort_callback,
        userArg        = nil,
    }

    nri_device : ^nri.Device
    graphics_api := nri.GraphicsAPI.D3D12
    device_creation_desc := nri.DeviceCreationDesc{
        graphicsAPI                      = graphics_api,
        // robustness                       = Robustness,
        // adapterDesc                      = ^AdapterDesc,
        callbackInterface                = callback_interface,
        // allocationCallbacks              = AllocationCallbacks,
        // queueFamilies                    = ^QueueFamilyDesc,
        // queueFamilyNum                   = u32,
        // d3dShaderExtRegister             = u32,
        // d3dZeroBufferSize                = u32,
        // vkBindingOffsets                 = VKBindingOffsets,
        // vkExtensions                     = VKExtensions,
        enableNRIValidation              = true,
        enableGraphicsAPIValidation      = true,
        // enableD3D11CommandBufferEmulation= bool,
        // enableD3D12RayTracingValidation  = bool,
        // enableMemoryZeroInitialization   = bool,
        // disableVKRayTracing              = bool,
        // disableD3D12EnhancedBarriers     = bool,
    }
    if nri.CreateDevice(&device_creation_desc, &nri_device) != .SUCCESS {
        fmt.printfln("Failed to init nri device")
        os.exit(-1)
    }
    
    NRI_ABORT_ON_FAILURE(nri.GetInterface(nri_device, "NriCoreInterface", size_of(NRI.core), &NRI.core))
    NRI_ABORT_ON_FAILURE(nri.GetInterface(nri_device, "NriSwapChainInterface", size_of(NRI.swapchain), &NRI.swapchain))

    window_handle := dxgi.HWND(sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))

    queue : ^nri.Queue
    NRI.GetQueue(nri_device, .GRAPHICS, 0, &queue)

    frame_fence : ^nri.Fence
    NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &frame_fence))
    
    // Create the swapchain
    nri_swapchain_desc := nri.SwapChainDesc{
        window        = {
            windows = nri.WindowsWindow{window_handle},
            // x11     = X11Window,
            // wayland = WaylandWindow,
            // metal   = MetalWindow,
        },
        queue         = queue,
        width         = nri.Dim_t(window_width),
        height        = nri.Dim_t(window_height),
        textureNum    = 2, // framboffers
        format        = .BT709_G22_8BIT,
        // flags         = SwapChainBits,
        // queuedFrameNum= u8,
        scaling       = .STRETCH,
        // gravityX      = Gravity,
        // gravityY      = Gravity,
        
        // window           = {
        //     windows = nri.Windows_Window{window_handle},
        //     // x11    = X11_Window,
        //     // wayland= Wayland_Window,
        //     // metal  = Metal_Window,
        // },
        // command_queue     = command_queue,
        // width             = u16(window_width),
        // height            = u16(window_height),
        // texture_num       = 2, // framebuffers
        // format            = .BT709_G22_8BIT,
        // vsync_interval    = 1,
        // queue_frame_num   = u8,
        // waitable          = bool,
        // allow_low_latency = bool,
    }
    swapchain : ^nri.SwapChain
    if NRI.CreateSwapChain(nri_device, &nri_swapchain_desc, &swapchain) != .SUCCESS {
        fmt.printfln("Failed to create nri swachain")
        os.exit(-1)
    }

    swapchain_texture_num: u32
    swapchain_textures := NRI.GetSwapChainTextures(swapchain, &swapchain_texture_num)
    swapchain_format := NRI.GetTextureDesc(swapchain_textures[0]).format
    fmt.printfln("Swapchain format: %v", swapchain_format)
	fmt.printfln("Number of swapchain textures: %d", swapchain_texture_num)

	for i:u32=0; i<swapchain_texture_num; i+=1 {
		texture_view_desc := nri.Texture2DViewDesc{swapchain_textures[i], .COLOR_ATTACHMENT, swapchain_format, 0, 0, 0, 0}

		color_attachment : ^nri.Descriptor
		NRI_ABORT_ON_FAILURE(NRI.CreateTexture2DView(&texture_view_desc, &color_attachment))

        SWAPCHAIN_SEMAPHORE :: ~u64(0)

		acquire_semaphore : ^nri.Fence
		NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, SWAPCHAIN_SEMAPHORE, &acquire_semaphore))
		// NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &acquire_semaphore))

		release_semaphore : ^nri.Fence
		NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, SWAPCHAIN_SEMAPHORE, &release_semaphore))
		// NRI_ABORT_ON_FAILURE(NRI.CreateFence(nri_device, 0, &release_semaphore))

		swapchain_texture := SwapChainTexture{
			acquire_semaphore = acquire_semaphore,
			release_semaphore = release_semaphore,
			texture           = swapchain_textures[i],
			color_attachment  = color_attachment,
			attachment_format = swapchain_format,
		}

        swapchain_textures[i] = swapchain_texture.texture
	}




    // Create vertex buffer
    vertex_buffer_desc := nri.BufferDesc{
        usage           = {.VERTEX_BUFFER},
        size            = size_of(triangleVertices),
        structureStride= size_of(Vertex),
    }

    vertex_buffer : ^nri.Buffer
    NRI.CreateBuffer(nri_device, &vertex_buffer_desc, &vertex_buffer)



    // Destroy 
    nri.DestroyDevice(nri_device)

}
