package main

import "core:fmt"
import "core:sys/windows"
import "core:os"
import sdl "vendor:sdl3"
import d3d12 "vendor:directx/d3d12"

// Nvidia NRI
import nri "libs/NRI-odin"

// Imgui
// DISABLE_DOCKING :: #config(DISABLE_DOCKING, false) // Allows moving imgui window out of the main window
// import "libs/odin-imgui/imgui_impl_nri"
// import    "libs/odin-imgui/imgui_impl_opengl3"
// import    "libs/odin-imgui/imgui_impl_dx12"
import im "libs/odin-imgui"
import    "libs/odin-imgui/imgui_impl_sdl3"



NRI_ABORT_ON_FAILURE :: proc(result: nri.Result, location := #caller_location) {
    if result != .SUCCESS {
        fmt.eprintfln("NRI failure: %v at %s:%d", result, location.file_path, location.line)
        nri.DestroyDevice(device)
        os.exit(-1)
    }
}

NRI_Interface :: struct {
    using core     : nri.CoreInterface,
    using swapchain: nri.SwapChainInterface,
    using helper   : nri.HelperInterface,
    using streamer : nri.StreamerInterface,
	// using imgui    : nri.ImguiInterface, // Requires compiling NRI with imgui extension enabled
}

SwapChainTexture :: struct {
    acquire_semaphore: ^nri.Fence,
    release_semaphore: ^nri.Fence,
    texture          : ^nri.Texture,
    color_attachment : ^nri.Descriptor,
    attachment_format: nri.Format,
};

Frame :: struct {
    command_allocator             : ^nri.CommandAllocator,
    command_buffer                : ^nri.CommandBuffer,
    constant_buffer_view          : ^nri.Descriptor,
    constant_buffer_descriptor_set: ^nri.DescriptorSet,
    constant_buffer_view_offset   : u64,
}

NUM_RENDERTARGETS :: 2
BUFFERED_FRAME_MAX_NUM :: 2
swapchain_textures : [NUM_RENDERTARGETS]SwapChainTexture

QueuedFrame :: struct {
    command_allocator: ^nri.CommandAllocator,
    command_buffer: ^nri.CommandBuffer,
};
queued_frames : [queued_frame_num]QueuedFrame

vsync_interval :: false
when vsync_interval {queued_frame_num :: 2}
else                {queued_frame_num :: 3}

window : ^sdl.Window
window_height : i32 = 768
window_width  : i32 = 1024

device : ^nri.Device

SHADER_FILE :: "shaders.hlsl"
shaders_hlsl := #load(SHADER_FILE)

ConstantBufferLayout :: struct {
    color: [3]f32,
    scale: f32,
}

Vertex :: struct{
    position: [3]f32,
    color:    [3]f32,
    // uv:       [2]f32,
}

triangle_vertices :: [3]Vertex{
    {{0.0,   0.5, 0.0}, {1, 0, 0}},
    {{0.5,  -0.5, 0.0}, {0, 1, 0}},
    {{-0.5, -0.5, 0.0}, {0, 0, 1}},
}

Index :: u16

triangle_indeces :: [3]Index{0, 1, 2}


main :: proc() {
    // Init SDL and create window
    ok := sdl.Init({.AUDIO, .VIDEO}); sdl_assert(ok) 
    defer sdl.Quit()

    window = sdl.CreateWindow("Hello World!", window_width, window_height, {.RESIZABLE}); sdl_assert(window != nil)
	defer sdl.DestroyWindow(window)

    // -------- Init NRI ---------
    graphics_api := nri.GraphicsAPI.D3D12

	adapters_num : u32 = 1 // This should choose the best adapter (graphics card)
	adapter_desc : nri.AdapterDesc // Getting multiple adapters with [^]nri.AdapterDesc is buggy
	NRI_ABORT_ON_FAILURE(nri.EnumerateAdapters(&adapter_desc, &adapters_num))
    // fmt.printfln("Adapter: %v", adapter_desc)

    callback_interface := nri.CallbackInterface {
        MessageCallback = nri_message_callback,
        AbortExecution  = nri_abort_callback,
        userArg         = nil,
    }
    device_creation_desc := nri.DeviceCreationDesc{
        graphicsAPI                      = graphics_api,
        // robustness                       = Robustness,
        adapterDesc                      = &adapter_desc,
        callbackInterface                = callback_interface,
        // allocationCallbacks              = AllocationCallbacks,
        // queueFamilies                    = ^QueueFamilyDesc,
        // queueFamilyNum                   = u32,
        // d3dShaderExtRegister             = u32,
        // d3dZeroBufferSize                = u32,
        // vkBindingOffsets                 = VKBindingOffsets,
        // vkExtensions                     = VKExtensions,
        enableNRIValidation              = true,
        // enableGraphicsAPIValidation      = true, // Note: Enabled causes lag for window interactions
        // enableD3D11CommandBufferEmulation= bool,
        // enableD3D12RayTracingValidation  = bool,
        // enableMemoryZeroInitialization   = bool,
        // disableVKRayTracing              = bool,
        // disableD3D12EnhancedBarriers     = bool,
    }
	// device : ^nri.Device
    if nri.CreateDevice(&device_creation_desc, &device) != .SUCCESS {
        fmt.printfln("Failed to init nri device")
        os.exit(-1)
    }
    
    NRI: NRI_Interface
    NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriCoreInterface", size_of(NRI.core), &NRI.core))
    NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriSwapChainInterface", size_of(NRI.swapchain), &NRI.swapchain))
    NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriHelperInterface", size_of(NRI.helper), &NRI.helper))
    NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriStreamerInterface", size_of(NRI.streamer), &NRI.streamer))
    // NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NRIImguiInterface", size_of(NRI.imgui), &NRI.imgui))


    streamer_desc := nri.StreamerDesc{
        dynamicBufferMemoryLocation  = .HOST_UPLOAD,
        dynamicBufferDesc            = {
            size            = 0,
            structureStride = 0,
            usage           = {.VERTEX_BUFFER, .INDEX_BUFFER},
        },
        // constantBufferSize           = u64,
        constantBufferMemoryLocation = .HOST_UPLOAD,
        queuedFrameNum               = queued_frame_num,
    }
    streamer : ^nri.Streamer
    NRI_ABORT_ON_FAILURE(NRI.CreateStreamer(device, &streamer_desc, &streamer))

    command_queue : ^nri.Queue
    NRI_ABORT_ON_FAILURE(NRI.GetQueue(device, .GRAPHICS, 0, &command_queue))
    
    frame_fence : ^nri.Fence
    NRI_ABORT_ON_FAILURE(NRI.CreateFence(device, 0, &frame_fence))
    
    window_handle := sdl.GetPointerProperty(sdl.GetWindowProperties(window), sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
    
    // Create swapchain
    nri_swapchain_desc := nri.SwapChainDesc{
        window        = {
            windows = nri.WindowsWindow{window_handle},
            // x11     = nri.X11Window,
            // wayland = nri.WaylandWindow,
            // metal   = nri.MetalWindow,
        },
        queue         = command_queue,
        width         = nri.Dim_t(window_width),
        height        = nri.Dim_t(window_height),
        textureNum    = 2, // frambuffers
        format        = .BT709_G22_8BIT,
        // flags         = SwapChainBits,
        // queuedFrameNum= u8,
        scaling       = .STRETCH,
        // gravityX      = Gravity,
        // gravityY      = Gravity,
    }
    swapchain : ^nri.SwapChain
    if NRI.CreateSwapChain(device, &nri_swapchain_desc, &swapchain) != .SUCCESS {
        fmt.printfln("Failed to create nri swachain")
        os.exit(-1)
    }

    { // Create swapchain textures
        swapchain_texture_num: u32
        nri_swapchain_textures := NRI.GetSwapChainTextures(swapchain, &swapchain_texture_num)
        swapchain_format := NRI.GetTextureDesc(nri_swapchain_textures[0]).format
        for i:u32=0; i<swapchain_texture_num; i+=1 {
            texture_view_desc := nri.Texture2DViewDesc{nri_swapchain_textures[i], .COLOR_ATTACHMENT, swapchain_format, 0, 0, 0, 0}

            color_attachment : ^nri.Descriptor
            NRI_ABORT_ON_FAILURE(NRI.CreateTexture2DView(&texture_view_desc, &color_attachment))

            SWAPCHAIN_SEMAPHORE :: ~u64(0)

            acquire_semaphore : ^nri.Fence
            NRI_ABORT_ON_FAILURE(NRI.CreateFence(device, SWAPCHAIN_SEMAPHORE, &acquire_semaphore))

            release_semaphore : ^nri.Fence
            NRI_ABORT_ON_FAILURE(NRI.CreateFence(device, SWAPCHAIN_SEMAPHORE, &release_semaphore))

            swapchain_texture := SwapChainTexture{
                acquire_semaphore = acquire_semaphore,
                release_semaphore = release_semaphore,
                texture           = nri_swapchain_textures[i],
                color_attachment  = color_attachment,
                attachment_format = swapchain_format,
            }

            swapchain_textures[i] = swapchain_texture
        }
    }
    
    frames : [BUFFERED_FRAME_MAX_NUM]Frame 
    for &frame in frames[:] {
        NRI_ABORT_ON_FAILURE(NRI.CreateCommandAllocator(command_queue, &frame.command_allocator))
        NRI_ABORT_ON_FAILURE(NRI.CreateCommandBuffer(frame.command_allocator, &frame.command_buffer))
    }


	im_interface : nri.ImguiInterface
	nri_imgui : ^nri.Imgui
    { // Init Imgui 
		im.CHECKVERSION()
		im.CreateContext()
		// defer im.DestroyContext()
		io := im.GetIO()

        // io.BackendFlags += {.HasMouseCursors}
        // io.BackendFlags += {.RendererHasVtxOffset}
        io.BackendFlags += {.RendererHasTextures}

        // im.FontAtlas_AddFontDefault(io.Fonts)

        
	    
		imgui_impl_sdl3.InitForOther(window)

	    NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriImguiInterface", size_of(im_interface), &im_interface))

	    imgui_desc := nri.ImguiDesc{
	        descriptorPoolSize = 1024
	    }
	    NRI_ABORT_ON_FAILURE(im_interface.CreateImgui(device, &imgui_desc, &nri_imgui))
	}


    { // Pipeline layout
        sampler_desc := nri.SamplerDesc{
            filters                = {
                min = .LINEAR,
                mag = .LINEAR,
                mip = .LINEAR,
	            ext = .AVERAGE, // requires "features.textureFilterMinMax"
            },
            anisotropy             = 4,
            // mipBias                = f32,
            // mipMin                 = f32,
            mipMax                 = 16.0,
            addressModes           = {
                u = .MIRRORED_REPEAT,
                v = .MIRRORED_REPEAT,
                w = .MIRRORED_REPEAT,
            },
            // compareOp              = CompareOp,
            // borderColor            = Color,
            // isInteger              = bool,
            // unnormalizedCoordinates= bool,           // requires "shaderFeatures.unnormalizedCoordinates"
        }

        root_constant := nri.RootConstantDesc{
            registerIndex = 1,
            size          = size_of(f32),
            shaderStages  = {.FRAGMENT_SHADER},
        }
        rootSampler := nri.RootSamplerDesc{0, sampler_desc, {.FRAGMENT_SHADER}}
        // setConstantBuffer := nri.DescriptorRangeDesc{0, 1, .CONSTANT_BUFFER,}
        // setTexture := nri.DescriptorRangeDesc{0, 1, .TEXTURE, {.FRAGMENT_SHADER}, }
    }

    frame_index := 0
    game_loop: for {
        { // Handle keyboard and mouse input
			e: sdl.Event
			for sdl.PollEvent(&e) {
				imgui_impl_sdl3.ProcessEvent(&e)
				#partial switch e.type {
                    case .QUIT:
                        break game_loop
                        
					case .KEY_DOWN: // holding .KEY_DOWN has a delay then repeats downs, designed for writing text
						#partial switch e.key.scancode {
						case .ESCAPE:
							break game_loop
					}
                }
            }
		}
        
        buffered_frame_index := frame_index % BUFFERED_FRAME_MAX_NUM
        frame := frames[buffered_frame_index]

        recycled_semaphore_index := frame_index % len(swapchain_textures)
        swapchain_acquire_semaphore := swapchain_textures[recycled_semaphore_index].acquire_semaphore

        current_swapchain_texture_index : u32 = 0
        NRI.AcquireNextTexture(swapchain, swapchain_acquire_semaphore, &current_swapchain_texture_index)

        swapchain_texture := swapchain_textures[current_swapchain_texture_index]

        command_buffer := frame.command_buffer
        NRI.BeginCommandBuffer(command_buffer, nil)
        {
            texture_barriers := nri.TextureBarrierDesc{
                texture    = swapchain_texture.texture,
                // before     = AccessLayoutStage,
                after      = {
                    access = {.COLOR_ATTACHMENT},
                    layout = .COLOR_ATTACHMENT,
                    stages = {.COLOR_ATTACHMENT},
                },
                // mipOffset  = Dim_t,
                mipNum     = 1,               // can be "REMAINING"
                // layerOffset= Dim_t,
                layerNum   = 1,               // can be "REMAINING"
                // planes     = PlaneBits,
                // srcQueue   = ^Queue,
                // dstQueue   = ^Queue,
            }

            barrier_desc := nri.BarrierDesc{
                // globals   = [^]GlobalBarrierDesc,
                // globalNum = u32,
                // buffers   = [^]BufferBarrierDesc,
                // bufferNum = u32,
                textures  = &texture_barriers,
                textureNum= 1,
            }
            NRI.CmdBarrier(command_buffer, &barrier_desc)

            attachments_desc := nri.AttachmentsDesc{
                // depthStencil= ^Descriptor,
                // shadingRate = ^Descriptor,      // requires "tiers.shadingRate >= 2"
                colors      = &swapchain_texture.color_attachment,
                colorNum    = 1,
                // viewMask    = u32,              // if non-0, requires "viewMaxNum > 1"
            }

            imgui_copy : nri.CopyImguiDataDesc
            imgui_draw_data : ^im.DrawData
            { // Imgui prepare frame
                imgui_impl_sdl3.NewFrame()
                im.NewFrame()
    
                im.ShowDemoWindow()
    
                im.Render()
    
                imgui_draw_data = im.GetDrawData()
                draw_lists_im := imgui_draw_data.CmdLists.Data
                draw_lists_nri := cast(^^nri.ImDrawList)draw_lists_im
                textures := im.GetPlatformIO().Textures
                texture_data_im := textures.Data
                texture_data_nri := cast(^^nri.ImTextureData)texture_data_im
                imgui_copy = nri.CopyImguiDataDesc{
                    drawLists   = draw_lists_nri,
                    drawListNum = u32(imgui_draw_data.CmdLists.Size),
                    textures    = texture_data_nri,
                    textureNum  = u32(textures.Size),
                }
                
                im_interface.CmdCopyImguiData(command_buffer, streamer, nri_imgui, &imgui_copy)
            }


            NRI.CmdBeginRendering(command_buffer, &attachments_desc)
            {
                // ... annotation

                // Clear screen
                clear_desc := nri.ClearDesc{
                    value               = {
                        color = {
                            f = {1.0, 0.0, 0.0, 1.0}
                        }
                    },
                    planes              = {.COLOR},
                    colorAttachmentIndex= 0,
                }
                rect1 := nri.Rect{0, 0, nri.Dim_t(window_width), nri.Dim_t(window_height)}
                NRI.CmdClearAttachments(command_buffer, &clear_desc, 1, &rect1, 1)
            
				{ // Imgui present

					draw_imgui_desc := nri.DrawImguiDesc{
					    drawLists       = imgui_copy.drawLists,
					    drawListNum     = imgui_copy.drawListNum,
					    displaySize     = {u16(imgui_draw_data.DisplaySize.x), u16(imgui_draw_data.DisplaySize.y)},
					    hdrScale        = 1.0,
					    attachmentFormat= swapchain_texture.attachment_format,
					    linearColor     = true,
					}
					im_interface.CmdDrawImgui(command_buffer, nri_imgui, &draw_imgui_desc)
				}
            
            }
            NRI.CmdEndRendering(command_buffer)

            texture_barriers.before = texture_barriers.after
            texture_barriers.after = {
                access = {},
                layout = .PRESENT,
                stages = nri.STAGEBITS_NONE,
            }
            NRI.CmdBarrier(command_buffer, &barrier_desc)
        }
        NRI.EndCommandBuffer(command_buffer)

        { // Submit
            texture_acquired_fence := nri.FenceSubmitDesc{
                fence = swapchain_acquire_semaphore,
                // value = u64,
                stages= {.COLOR_ATTACHMENT},
            }

            rendering_finished_fence := nri.FenceSubmitDesc{
                fence = swapchain_texture.release_semaphore
            }

            queue_submit_desc := nri.QueueSubmitDesc{
                waitFences      = &texture_acquired_fence,
                waitFenceNum    = 1,
                commandBuffers  = &frame.command_buffer,
                commandBufferNum= 1,
                signalFences    = &rendering_finished_fence,
                signalFenceNum  = 1,
                swapChain       = swapchain,           // required if "NRILowLatency" is enabled in the swap chain
            }
            NRI.QueueSubmit(command_queue, &queue_submit_desc)
        }

        // Present
        NRI.QueuePresent(swapchain, swapchain_texture.release_semaphore)


        // if frame_index >= BUFFERED_FRAME_MAX_NUM {
        //     NRI.Wait(frame_fence, 1 + frame_index - BUFFERED_FRAME_MAX_NUM)
        //     NRI.ResetCommandAllocator(frames[buffered_framne_index].command_allocator^)
        // }


        frame_index += 1

    }

    // Destroy 
    nri.DestroyDevice(device)

}
