package Renderer

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"
import win "core:sys/windows"
import "core:log"
import "core:mem"

NUM_RENDERTARGETS :: 2

Renderer :: struct {
	device: ^d3d12.IDevice,
	dxgi_factory: ^dxgi.IFactory4,
	command_queue: ^d3d12.ICommandQueue,
}

Swapchain :: struct {
	swapchain: ^dxgi.ISwapChain3,
	rtv_descriptor_heap: ^d3d12.IDescriptorHeap,
	targets: [NUM_RENDERTARGETS]^d3d12.IResource,
	frame_index: u32,
	width: int,
	height: int,
}

Pipeline :: struct {
	pipeline: ^d3d12.IPipelineState,
	command_allocator: ^d3d12.ICommandAllocator,
	cmdlist: ^d3d12.IGraphicsCommandList,
	root_signature: ^d3d12.IRootSignature,

	fence: ^d3d12.IFence,
	fence_value: u64,
	fence_event: win.HANDLE,
}

Mesh :: struct {
	vertex_buffer: ^d3d12.IResource,
	vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,
}

@private
ensure_hr :: proc(res: win.HRESULT, message: string) {
	log.ensuref(res >= 0, "%v. Error code: %0x\n", message, u32(res))
}

create :: proc() -> Renderer {
	ren: Renderer
	hr: win.HRESULT

	{
		flags: dxgi.CREATE_FACTORY

		when ODIN_DEBUG {
			flags += { .DEBUG }
		}

		hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, (^rawptr)(&ren.dxgi_factory))
		ensure_hr(hr, "Failed creating DXGI factory.")
	}

	dxgi_adapter: ^dxgi.IAdapter1

	for i: u32 = 0; ren.dxgi_factory->EnumAdapters1(i, &dxgi_adapter) == 0; i += 1 {
		desc: dxgi.ADAPTER_DESC1
		dxgi_adapter->GetDesc1(&desc)
		if .SOFTWARE in desc.Flags {
			continue
		}

		if d3d12.CreateDevice((^dxgi.IUnknown)(dxgi_adapter), ._12_0, dxgi.IDevice_UUID, nil) >= 0 {
			break
		} else {
			continue
		}
	}

	ensure(dxgi_adapter != nil, "Could not find hardware adapter")

	hr = d3d12.CreateDevice((^dxgi.IUnknown)(dxgi_adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&ren.device))
	ensure_hr(hr, "Failed to creating D3D12 device")

	return ren
}

create_swapchain :: proc(ren: ^Renderer, hwnd: win.HWND, width: int, height: int) -> Swapchain {
	ensure(hwnd != nil, "Invalid window handle")
	swap := Swapchain {
		width = width,
		height = height,
	}

	hr: win.HRESULT

	{
		desc := dxgi.SWAP_CHAIN_DESC1 {
			Width = u32(width),
			Height = u32(height),
			Format = .R8G8B8A8_UNORM,
			SampleDesc = {
				Count = 1,
				Quality = 0,
			},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = NUM_RENDERTARGETS,
			Scaling = .NONE,
			SwapEffect = .FLIP_DISCARD,
			AlphaMode = .UNSPECIFIED,
		}

		hr = ren.dxgi_factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(ren.command_queue), hwnd, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swap.swapchain))
		ensure_hr(hr, "Failed creating dxgi swapchain")
	}

	swap.frame_index = swap.swapchain->GetCurrentBackBufferIndex()

	{
		desc := d3d12.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = NUM_RENDERTARGETS,
			Type = .RTV,
			Flags = {},
		}

		hr = ren.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&swap.rtv_descriptor_heap))
		ensure_hr(hr, "Failed creating descriptor heap")
	}


	{
		rtv_descriptor_size: u32 = ren.device->GetDescriptorHandleIncrementSize(.RTV)

		rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		swap.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

		for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
			res := swap.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&swap.targets[i]))
			ensure_hr(res, "Failed getting render target")
			ren.device->CreateRenderTargetView(swap.targets[i], nil, rtv_descriptor_handle)
			rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
		}
	}

	return swap
}

create_pipeline :: proc(ren: ^Renderer, shader_source: string) -> Pipeline {
	hr: win.HRESULT
	pip: Pipeline
	
	{
		hr = ren.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&pip.command_allocator))
		ensure_hr(hr, "Failed creating command allocator")
	}

	{
		desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
			Version = ._1_0,
		}

		desc.Desc_1_0.Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
		serialized_desc: ^d3d12.IBlob
		ser_root_sig_hr := d3d12.SerializeVersionedRootSignature(&desc, &serialized_desc, nil)
		ensure_hr(ser_root_sig_hr, "Failed to serialize root signature")
		root_sig_hr := ren.device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&pip.root_signature))
		ensure_hr(root_sig_hr, "Failed creating root signature")
		serialized_desc->Release()
	}


	{
		shader_size: uint = len(shader_source)

		compile_flags: u32 = 0
		when ODIN_DEBUG {
			compile_flags |= u32(d3dc.D3DCOMPILE.DEBUG)
			compile_flags |= u32(d3dc.D3DCOMPILE.SKIP_OPTIMIZATION)
		}

		vs: ^d3d12.IBlob = nil
		ps: ^d3d12.IBlob = nil

		hr = d3dc.Compile(raw_data(shader_source), shader_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, nil)
		ensure_hr(hr, "Failed to compile vertex shader")

		hr = d3dc.Compile(raw_data(shader_source), shader_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, nil)
		ensure_hr(hr, "Failed to compile pixel shader")

		vertex_format: []d3d12.INPUT_ELEMENT_DESC = {
			{ 
				SemanticName = "POSITION", 
				Format = .R32G32B32_FLOAT, 
				InputSlotClass = .PER_VERTEX_DATA, 
			},
			{   
				SemanticName = "COLOR", 
				Format = .R32G32B32A32_FLOAT, 
				AlignedByteOffset = size_of(f32) * 3, 
				InputSlotClass = .PER_VERTEX_DATA, 
			},
		}

		default_blend_state := d3d12.RENDER_TARGET_BLEND_DESC {
			BlendEnable = false,
			LogicOpEnable = false,

			SrcBlend = .ONE,
			DestBlend = .ZERO,
			BlendOp = .ADD,

			SrcBlendAlpha = .ONE,
			DestBlendAlpha = .ZERO,
			BlendOpAlpha = .ADD,

			LogicOp = .NOOP,
			RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
		}

		pipeline_state_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC {
			pRootSignature = pip.root_signature,
			VS = {
				pShaderBytecode = vs->GetBufferPointer(),
				BytecodeLength = vs->GetBufferSize(),
			},
			PS = {
				pShaderBytecode = ps->GetBufferPointer(),
				BytecodeLength = ps->GetBufferSize(),
			},
			StreamOutput = {},
			BlendState = {
				AlphaToCoverageEnable = false,
				IndependentBlendEnable = false,
				RenderTarget = { 0 = default_blend_state, 1..<7 = {} },
			},
			SampleMask = 0xFFFFFFFF,
			RasterizerState = {
				FillMode = .SOLID,
				CullMode = .BACK,
				FrontCounterClockwise = false,
				DepthBias = 0,
				DepthBiasClamp = 0,
				SlopeScaledDepthBias = 0,
				DepthClipEnable = true,
				MultisampleEnable = false,
				AntialiasedLineEnable = false,
				ForcedSampleCount = 0,
				ConservativeRaster = .OFF,
			},
			DepthStencilState = {
				DepthEnable = false,
				StencilEnable = false,
			},
			InputLayout = {
				pInputElementDescs = &vertex_format[0],
				NumElements = u32(len(vertex_format)),
			},
			PrimitiveTopologyType = .TRIANGLE,
			NumRenderTargets = 1,
			RTVFormats = { 0 = .R8G8B8A8_UNORM, 1..<7 = .UNKNOWN },
			DSVFormat = .UNKNOWN,
			SampleDesc = {
				Count = 1,
				Quality = 0,
			},
		}
		
		hr = ren.device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pip.pipeline))
		ensure_hr(hr, "Pipeline creation failed")

		vs->Release()
		ps->Release()
	}

	hr = ren.device->CreateCommandList(0, .DIRECT, pip.command_allocator, pip.pipeline, d3d12.ICommandList_UUID, (^rawptr)(&pip.cmdlist))
	ensure_hr(hr, "Failed to create command list")
	hr = pip.cmdlist->Close()
	ensure_hr(hr, "Failed to close command list")

	{
		hr = ren.device->CreateFence(pip.fence_value, {}, d3d12.IFence_UUID, (^rawptr)(&pip.fence))
		ensure_hr(hr, "Failed to create fence")
		pip.fence_value += 1
		manual_reset: win.BOOL = false
		initial_state: win.BOOL = false
		pip.fence_event = win.CreateEventW(nil, manual_reset, initial_state, nil)
		assert(pip.fence_event != nil, "Failed to create fence event")
	}

	{
		desc := d3d12.COMMAND_QUEUE_DESC {
			Type = .DIRECT,
		}

		hr = ren.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&ren.command_queue))
		ensure_hr(hr, "Failed creating D3D12 command queue")
	}

	return pip
}

create_triangle_mesh :: proc(ren: ^Renderer) -> Mesh {
	m: Mesh
	hr: win.HRESULT

	{
		// The position and color data for the triangle's vertices go together per-vertex
		vertices := [?]f32 {
			// pos            color
			 0.0 , 0.5, 0.0,  1,0,0,0,
			 0.5, -0.5, 0.0,  0,1,0,0,
			-0.5, -0.5, 0.0,  0,0,1,0,
		}

		heap_props := d3d12.HEAP_PROPERTIES {
			Type = .UPLOAD,
		}

		vertex_buffer_size := len(vertices) * size_of(vertices[0])

		resource_desc := d3d12.RESOURCE_DESC {
			Dimension = .BUFFER,
			Alignment = 0,
			Width = u64(vertex_buffer_size),
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			Format = .UNKNOWN,
			SampleDesc = { Count = 1, Quality = 0 },
			Layout = .ROW_MAJOR,
			Flags = {},
		}

		hr = ren.device->CreateCommittedResource(&heap_props, {}, &resource_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&m.vertex_buffer))
		ensure_hr(hr, "Failed creating vertex buffer")

		gpu_data: rawptr
		read_range: d3d12.RANGE

		hr = m.vertex_buffer->Map(0, &read_range, &gpu_data)
		ensure_hr(hr, "Failed creating verex buffer resource")

		mem.copy(gpu_data, &vertices[0], vertex_buffer_size)
		m.vertex_buffer->Unmap(0, nil)

		m.vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
			BufferLocation = m.vertex_buffer->GetGPUVirtualAddress(),
			StrideInBytes = u32(vertex_buffer_size/3),
			SizeInBytes = u32(vertex_buffer_size),
		}
	}

	return m
}

render_mesh :: proc(ren: ^Renderer, pip: ^Pipeline, swap: ^Swapchain, m: ^Mesh) {
	hr: win.HRESULT
	hr = pip.command_allocator->Reset()
	ensure_hr(hr, "Failed resetting command allocator")

	hr = pip.cmdlist->Reset(pip.command_allocator, pip.pipeline)
	ensure_hr(hr, "Failed to reset command list")

	viewport := d3d12.VIEWPORT {
		Width = f32(swap.width),
		Height = f32(swap.height),
	}

	scissor_rect := d3d12.RECT {
		left = 0, right = i32(swap.width),
		top = 0, bottom = i32(swap.height),
	}

	pip.cmdlist->SetGraphicsRootSignature(pip.root_signature)
	pip.cmdlist->RSSetViewports(1, &viewport)
	pip.cmdlist->RSSetScissorRects(1, &scissor_rect)

	to_render_target_barrier := d3d12.RESOURCE_BARRIER {
		Type = .TRANSITION,
		Flags = {},
	}

	to_render_target_barrier.Transition = {
		pResource = swap.targets[swap.frame_index],
		StateBefore = d3d12.RESOURCE_STATE_PRESENT,
		StateAfter = {.RENDER_TARGET},
		Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
	}

	pip.cmdlist->ResourceBarrier(1, &to_render_target_barrier)

	rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
	swap.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

	if swap.frame_index > 0 {
		s := ren.device->GetDescriptorHandleIncrementSize(.RTV)
		rtv_handle.ptr += uint(swap.frame_index * s)
	}

	pip.cmdlist->OMSetRenderTargets(1, &rtv_handle, false, nil)

	// clear backbuffer
	clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
	pip.cmdlist->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)

	// draw call
	pip.cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
	pip.cmdlist->IASetVertexBuffers(0, 1, &m.vertex_buffer_view)
	pip.cmdlist->DrawInstanced(3, 1, 0, 0)
	
	to_present_barrier := to_render_target_barrier
	to_present_barrier.Transition.StateBefore = {.RENDER_TARGET}
	to_present_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT

	pip.cmdlist->ResourceBarrier(1, &to_present_barrier)

	hr = pip.cmdlist->Close()
	ensure_hr(hr, "Failed to close command list")

	// execute
	cmdlists := [?]^d3d12.IGraphicsCommandList { pip.cmdlist }
	ren.command_queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))

	// present
	{
		flags: dxgi.PRESENT
		params: dxgi.PRESENT_PARAMETERS
		hr = swap.swapchain->Present1(1, flags, &params)
		ensure_hr(hr, "Present failed")
	}

	// wait for frame to finish
	{
		current_fence_value := pip.fence_value

		hr = ren.command_queue->Signal(pip.fence, current_fence_value)
		ensure_hr(hr, "Failed to signal fence")

		pip.fence_value += 1
		completed := pip.fence->GetCompletedValue()

		if completed < current_fence_value {
			hr = pip.fence->SetEventOnCompletion(current_fence_value, pip.fence_event)
			ensure_hr(hr, "Failed to set event on completion flag")
			win.WaitForSingleObject(pip.fence_event, win.INFINITE)
		}

		swap.frame_index = swap.swapchain->GetCurrentBackBufferIndex()
	}		
}