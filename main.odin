package main

import "core:fmt"
import "core:sys/windows"
import "core:os"
import sdl "vendor:sdl3"

// Nvidia NRI
import nri "libs/NRI-odin"

// Imgui
DISABLE_DOCKING :: #config(DISABLE_DOCKING, false) // Allows moving imgui window out of the main window
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

ConstantBufferLayout :: struct {
    color: [3]f32,
    scale: f32,
}

Mip :: rawptr

AlphaMode :: enum {
    OPAQUE,
    PREMULTIPLIED,
    TRANSPARENT,
    OFF, // alpha is 0 everywhere
}

Texture :: struct {
    name     : cstring,
    mips     : ^Mip,
    AlphaMode: AlphaMode,
    format   : nri.Format,
    width    : u16,
    height   : u16,
    depth    : u16,
    mipNum   : u16,
    layerNum : u16,
}

Vertex :: struct{
    position: [2]f32,
    // color:    [3]f32,
    uv:       [2]f32,
}

triangle_vertices :: [3]Vertex{
    {{0.0,   0.5}, {0.0, 0.0}},
    {{0.5,  -0.5}, {1.0, 1.0}},
    {{-0.5, -0.5}, {0.0, 1.0}},
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
        enableGraphicsAPIValidation      = true, // Note: Enabled causes lag for window interactions
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


    streamer_desc := nri.StreamerDesc{
        dynamicBufferMemoryLocation  = .HOST_UPLOAD,
        dynamicBufferDesc            = {
            size            = 0,
            // size            = 4 * 1024 * 1024, // 4 MB for dynamic VB/IB
            structureStride = 0,
            usage           = {.VERTEX_BUFFER, .INDEX_BUFFER},
        },
        constantBufferMemoryLocation = .HOST_UPLOAD,
        // constantBufferSize           = u64,
        // constantBufferSize           = 1 * 1024 * 1024,
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
        queuedFrameNum= queued_frame_num,
        scaling       = .STRETCH,
        // gravityX      = Gravity,
        // gravityY      = Gravity,
    }
    swapchain : ^nri.SwapChain
    NRI_ABORT_ON_FAILURE(NRI.CreateSwapChain(device, &nri_swapchain_desc, &swapchain))

    swapchain_format : nri.Format
    { // Create swapchain textures
        swapchain_texture_num: u32
        nri_swapchain_textures := NRI.GetSwapChainTextures(swapchain, &swapchain_texture_num)
        swapchain_format = NRI.GetTextureDesc(nri_swapchain_textures[0]).format
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
    
    // frames : [BUFFERED_FRAME_MAX_NUM]Frame 
    frames : [queued_frame_num]Frame 
    for &frame in frames[:] {
        NRI_ABORT_ON_FAILURE(NRI.CreateCommandAllocator(command_queue, &frame.command_allocator))
        NRI_ABORT_ON_FAILURE(NRI.CreateCommandBuffer(frame.command_allocator, &frame.command_buffer))
    }


	// im_interface : nri.ImguiInterface
	// nri_imgui : ^nri.Imgui
    // { // Init Imgui 
	// 	im.CHECKVERSION()
	// 	im.CreateContext()
	// 	io := im.GetIO()

    //     // io.BackendFlags += {.HasMouseCursors}
    //     io.BackendFlags += {.RendererHasVtxOffset}
    //     io.BackendFlags += {.RendererHasTextures}
    //     io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad}

    //     im.StyleColorsDark()

    //     // im.FontAtlas_AddFontDefault(io.Fonts)

	// 	imgui_impl_sdl3.InitForOther(window)

	//     NRI_ABORT_ON_FAILURE(nri.GetInterface(device, "NriImguiInterface", size_of(im_interface), &im_interface))

	//     imgui_desc := nri.ImguiDesc{
	//         descriptorPoolSize = 1024
	//     }
	//     NRI_ABORT_ON_FAILURE(im_interface.CreateImgui(device, &imgui_desc, &nri_imgui))
	// }

    pipeline_layout : ^nri.PipelineLayout
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
        root_sampler := nri.RootSamplerDesc{0, sampler_desc, {.FRAGMENT_SHADER}}
        // STAGEBITS_ALL :: nri.StageBits{} // Missing in the nri-odin bindings
        // STAGEBITS_ALL :: nri.StageBits{} // Missing in the nri-odin bindings
        set_constant_buffer := nri.DescriptorRangeDesc{0, 1, .CONSTANT_BUFFER, nri.STAGEBITS_ALL, {}}
        set_texture := nri.DescriptorRangeDesc{0, 1, .TEXTURE, {.FRAGMENT_SHADER}, {}}

        descriptor_set_descs := [?]nri.DescriptorSetDesc{
            {0, &set_constant_buffer, 1, {}},
            {1, &set_texture, 1, {}},
        }

        pipeline_layout_desc := nri.PipelineLayoutDesc{
            rootRegisterSpace= 2, // see shader, must be unique
            rootConstants    = &root_constant,
            rootConstantNum  = 1,
            // rootDescriptors  = [^]RootDescriptorDesc,
            // rootDescriptorNum= u32,
            rootSamplers     = &root_sampler,
            rootSamplerNum   = 1,
            descriptorSets   = raw_data(&descriptor_set_descs),
            descriptorSetNum = len(descriptor_set_descs),
            shaderStages     = {.VERTEX_SHADER, .FRAGMENT_SHADER},
            // flags            = PipelineLayoutBits,
        }

        NRI_ABORT_ON_FAILURE(NRI.CreatePipelineLayout(device, &pipeline_layout_desc, &pipeline_layout))
    }

    pipeline : ^nri.Pipeline
    // shader_code_storage
    { // Pipeline
        vertex_stream_desc := [1]nri.VertexStreamDesc{
            {
                bindingSlot= 0,
                stepRate   = .PER_VERTEX,
            }
        }
        vertex_attribute_descs : [2]nri.VertexAttributeDesc = {
            {
                d3d        = {"POSITION", 0},
                vk         = { location = 0 },
                offset     = u32(offset_of(Vertex, position)),
                format     = .RG32_SFLOAT,
                streamIndex= 0,
            },
            {
                d3d        = {"TEXCOORD", 0},
                vk         = { location = 1 },
                offset     = u32(offset_of(Vertex, uv)),
                format     = .RG32_SFLOAT,
                streamIndex= 0,
            },
        }

        vertex_input_desc := nri.VertexInputDesc{
            attributes  = &vertex_attribute_descs[0],
            attributeNum= u8(len(vertex_attribute_descs)),
            streams     = &vertex_stream_desc[0],
            streamNum   = 1,
        }

        input_assembly_desc := nri.InputAssemblyDesc{
	        topology           = .TRIANGLE_LIST,
            // tessControlPointNum= u8,
            // primitiveRestart   = PrimitiveRestart,
        }

        rasterization_desc := nri.RasterizationDesc{
            // depthBias            = DepthBiasDesc,
            fillMode             = .SOLID,
            cullMode             = .NONE,
            // frontCounterClockwise= bool,
            // depthClamp           = bool,
            // lineSmoothing        = bool,            // requires "features.lineSmoothing"
            // conservativeRaster   = bool,            // requires "tiers.conservativeRaster != 0"
            // shadingRate          = bool,            // requires "tiers.shadingRate != 0", expects "CmdSetShadingRate" and optionally "AttachmentsDesc::shadingRate"
        }

        color_attachment_desc := nri.ColorAttachmentDesc{
            format        = swapchain_format,
            colorBlend    = {
                srcFactor= .SRC_ALPHA,
                dstFactor= .ONE_MINUS_SRC_ALPHA,
                op       = .ADD,
            },
            // alphaBlend    = BlendDesc,
            colorWriteMask= .RGBA,
            blendEnabled  = true,
        }

        output_merger_desc := nri.OutputMergerDesc{
            colors            = &color_attachment_desc,
            colorNum          = 1,
            // depth             = DepthAttachmentDesc,
            // stencil           = StencilAttachmentDesc,
            // depthStencilFormat= Format,
            // logicOp           = LogicOp,                  // requires "features.logicOp"
            // viewMask          = u32,                      // if non-0, requires "viewMaxNum > 1"
	        // multiview         = Multiview,                // if "viewMask != 0", requires "features.(xxx)Multiview"
        }

        shader_code_storage := make([dynamic][]u8, 2)
        shader_stages := []nri.ShaderDesc{
            //............todo 
            load_shader(graphics_api, "Triangle.vs", &shader_code_storage),
            load_shader(graphics_api, "Triangle.fs", &shader_code_storage),
        }

        graphics_pipeline_desc := nri.GraphicsPipelineDesc{
            pipelineLayout= pipeline_layout,
            vertexInput   = &vertex_input_desc,
            inputAssembly = input_assembly_desc,
            rasterization = rasterization_desc,
            // multisample   = ^MultisampleDesc,
            outputMerger  = output_merger_desc,
            shaders       = raw_data(shader_stages),
            shaderNum     = u32(len(shader_stages)),
            // robustness    = Robustness,
        }

        fmt.printfln("Creating graphics pipeline...")
        NRI_ABORT_ON_FAILURE(NRI.CreateGraphicsPipeline(device, &graphics_pipeline_desc, &pipeline))
        fmt.printfln("Graphics pipeline created.")
    }

    descriptor_pool : ^nri.DescriptorPool
    { // Descriptor pool
        descriptor_pool_desc := nri.DescriptorPoolDesc{
            descriptorSetMaxNum = queued_frame_num + 1,
            constantBufferMaxNum = queued_frame_num,
            textureMaxNum = 1,
        }

        NRI_ABORT_ON_FAILURE(NRI.CreateDescriptorPool(device, &descriptor_pool_desc, &descriptor_pool))
    }

    // Load texture
    texture_data : Texture
    tex_load_succ := load_texture("assets/textures/round_cat.png", &texture_data, false)
    
    texture : ^nri.Texture
    { // Read-only texture
        texture_desc := nri.TextureDesc{
            type               = .TEXTURE_2D,
            usage              = {.SHADER_RESOURCE},
            format             = .RGBA8_UNORM,
            width              = u16(texture_data.width),
            height             = u16(texture_data.height),
            depth              = 1,
            mipNum             = 1,
            layerNum           = 1,
            sampleNum          = 1,
            // sharingMode        = SharingMode,
            // optimizedClearValue= ClearValue,         // D3D12: not needed on desktop, since any HW can track many clear values
        }
        NRI_ABORT_ON_FAILURE(NRI.CreateTexture(device, &texture_desc, &texture))
    }




    frame_index : u64 = 0
    game_loop: for {

		{ // Latency sleep
			queued_frame_index := frame_index % queued_frame_num
			wait_value := frame_index >= queued_frame_num ? 1 + frame_index - queued_frame_num : 0
            // signal_value := frame_index + 1
            // wait_value : u64 = 0
            // if frame_index >= queued_frame_num {
            //     wait_value = frame_index + 1 - queued_frame_num
            // }

			NRI.Wait(frame_fence, u64(wait_value))

			NRI.ResetCommandAllocator(frames[queued_frame_index].command_allocator)
		}

        { // Handle keyboard and mouse input
			e: sdl.Event
			for sdl.PollEvent(&e) {
				// imgui_impl_sdl3.ProcessEvent(&e)
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
        
        // buffered_frame_index := frame_index % queued_frame_num
        // frame := frames[buffered_frame_index]
        queued_frame_index := frame_index % queued_frame_num
        queued_frame := queued_frames[queued_frame_index]

        // Acquire swapchain texture
        recycled_semaphore_index := frame_index % len(swapchain_textures)
        swapchain_acquire_semaphore := swapchain_textures[recycled_semaphore_index].acquire_semaphore

        current_swapchain_texture_index : u32 = 0
        NRI.AcquireNextTexture(swapchain, swapchain_acquire_semaphore, &current_swapchain_texture_index)

        swapchain_texture := swapchain_textures[current_swapchain_texture_index]

        // Update constants
        // common_constants := NRI.MapBuffer(consta)

        command_buffer := queued_frame.command_buffer
        NRI.BeginCommandBuffer(command_buffer, descriptor_pool)
        {
            texture_barriers := nri.TextureBarrierDesc{
                texture    = swapchain_texture.texture,
                // before     = AccessLayoutStage,
                after      = {
                    access = {.COLOR_ATTACHMENT},
                    layout = .COLOR_ATTACHMENT,
                    // stages = {.COLOR_ATTACHMENT},
                },
                // mipOffset  = Dim_t,
                // mipNum     = 1,               // can be "REMAINING"
                // layerOffset= Dim_t,
                // layerNum   = 1,               // can be "REMAINING"
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

            color_attachment_desc := nri.AttachmentDesc{
                // depthStencil= ^Descriptor,
                // shadingRate = ^Descriptor,      // requires "tiers.shadingRate >= 2"
                colors      = &swapchain_texture.color_attachment,
                colorNum    = 1,
                // viewMask    = u32,              // if non-0, requires "viewMaxNum > 1"
            }

            rendering_desc := nri.RenderingDesc

            // imgui_copy : nri.CopyImguiDataDesc
            // imgui_draw_data : ^im.DrawData
            // { // Imgui prepare frame
            //     imgui_impl_sdl3.NewFrame()
            //     im.NewFrame()
            //     {
            //         im.ShowDemoWindow()

            //         // im.Begin("Debug window")
            //         //     im.Text("frame: %i", frame_index)
            //         //     // im.Text("FPS: %.1f", fps)
            //         // im.End()

            //     }
            //     im.EndFrame()
            //     im.Render()
    
            //     imgui_draw_data = im.GetDrawData()
            //     textures := im.GetPlatformIO().Textures
            //     imgui_copy = nri.CopyImguiDataDesc{
            //         drawLists   = cast(^^nri.ImDrawList)imgui_draw_data.CmdLists.Data,
            //         drawListNum = u32(imgui_draw_data.CmdLists.Size),
            //         textures    = cast(^^nri.ImTextureData)textures.Data,
            //         // textures    = nil,
            //         textureNum  = u32(textures.Size),
            //         // textureNum  = 0,
            //     }
            //     // im_interface.CmdCopyImguiData(command_buffer, streamer, nri_imgui, &imgui_copy)
            // }


            NRI.CmdBeginRendering(command_buffer, &color_attachment_desc)
            {
                { // Clear screen
					NRI.CmdBeginAnnotation(command_buffer, "Clear screen", 0); defer(NRI.CmdEndAnnotation(command_buffer))

	                clear_desc := nri.ClearDesc{
	                    value = {
	                        color = {
	                            f = {1.0, 0.0, 0.0, 1.0}
	                        }
	                    },
	                    planes = {.COLOR},
	                    colorAttachmentIndex= 0,
	                }
	                rect1 := nri.Rect{0, 0, nri.Dim_t(window_width), nri.Dim_t(window_height)}
	                NRI.CmdClearAttachments(command_buffer, &clear_desc, 1, &rect1, 1)
				}

				// { // Imgui present
				// 	NRI.CmdBeginAnnotation(command_buffer, "Imgui present", 0); defer(NRI.CmdEndAnnotation(command_buffer))

				// 	draw_imgui_desc := nri.DrawImguiDesc{
				// 	    drawLists       = imgui_copy.drawLists,
				// 	    drawListNum     = imgui_copy.drawListNum,
				// 	    displaySize     = {u16(imgui_draw_data.DisplaySize.x), u16(imgui_draw_data.DisplaySize.y)},
				// 	    hdrScale        = 1.0,
				// 	    attachmentFormat= swapchain_texture.attachment_format,
				// 	    linearColor     = true,
				// 	}
				// 	// im_interface.CmdDrawImgui(command_buffer, nri_imgui, &draw_imgui_desc)
                    
                // }
            
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
                stages= {.COLOR_ATTACHMENT},
            }

            rendering_finished_fence := nri.FenceSubmitDesc{
                fence = swapchain_texture.release_semaphore
            }

            queue_submit_desc := nri.QueueSubmitDesc{
                waitFences      = &texture_acquired_fence,
                waitFenceNum    = 1,
                commandBuffers  = &queued_frame.command_buffer,
                commandBufferNum= 1,
                signalFences    = &rendering_finished_fence,
                signalFenceNum  = 1,
                // swapChain       = swapchain, // required if "NRILowLatency" is enabled in the swap chain
            }
            NRI.QueueSubmit(command_queue, &queue_submit_desc)
        }

        NRI.EndStreamerFrame(streamer)

        // Present
        NRI.QueuePresent(swapchain, swapchain_texture.release_semaphore)

        // { // Signaling after "Present" improves D3D11 performance a bit
        //     signal_fence := nri.FenceSubmitDesc{
        //         fence = frame_fence,
        //         value = 1 + frame_index
        //     }

        //     queue_submit_desc := nri.QueueSubmitDesc{
        //         signalFences = &signal_fence,
        //         signalFenceNum = 1
        //     }

        //     NRI.QueueSubmit(command_queue, &queue_submit_desc)
        // }

        frame_index += 1

    }

    // Destroy 
    nri.DestroyDevice(device)

}
