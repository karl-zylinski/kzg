package kzg

import "core:fmt"
import "base:runtime"
import win "core:sys/windows"
import "core:mem"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import d3dc "vendor:directx/d3d_compiler"

NUM_RENDERTARGETS :: 2
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

d3d12_device: ^d3d12.IDevice
command_allocator: ^d3d12.ICommandAllocator
cmdlist: ^d3d12.IGraphicsCommandList
pipeline: ^d3d12.IPipelineState
root_signature: ^d3d12.IRootSignature 
targets: [NUM_RENDERTARGETS]^d3d12.IResource
rtv_descriptor_heap: ^d3d12.IDescriptorHeap
vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW
d3d12_queue: ^d3d12.ICommandQueue
swapchain: ^dxgi.ISwapChain3
frame_index: u32
fence: ^d3d12.IFence
fence_value: u64
fence_event: win.HANDLE

win32_hr_assert :: proc(res: win.HRESULT, message: string) {
	fmt.assertf(res >= 0, "%v. Error code: %0x\n", message, u32(res))
}

main :: proc() {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "win: Failed fetching current instance")
	class_name := win.L("KZG")
	hr: win.HRESULT

	cls := win.WNDCLASSW {
		lpfnWndProc = window_proc,
		lpszClassName = class_name,
		hInstance = instance,
		hCursor = win.LoadCursorA(nil, win.IDC_ARROW)
	}

	class := win.RegisterClassW(&cls)
	assert(class != 0, "win: Failed creating window class")

	hwnd := win.CreateWindowW(class_name,
		win.L("KZG"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		100, 100, WINDOW_WIDTH, WINDOW_HEIGHT,
		nil, nil, instance, nil)

	assert(hwnd != nil, "win: Window creation failed")

	dxgi_factory: ^dxgi.IFactory4

	{
		flags: dxgi.CREATE_FACTORY

		when ODIN_DEBUG {
			flags += { .DEBUG }
		}

		dxgi_factory_res := dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, (^rawptr)(&dxgi_factory))
		win32_hr_assert(dxgi_factory_res, "Failed creating DXGI factory.")
	}

	dxgi_adapter: ^dxgi.IAdapter1

	for i: u32 = 0; dxgi_factory->EnumAdapters1(i, &dxgi_adapter) == 0; i += 1 {
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

	assert(dxgi_adapter != nil, "Could not find hardware adapter")

	d3d12_device_res := d3d12.CreateDevice((^dxgi.IUnknown)(dxgi_adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&d3d12_device))
	win32_hr_assert(d3d12_device_res, "Failed to creating D3D12 device")

	{
		desc := d3d12.COMMAND_QUEUE_DESC {
			Type = .DIRECT,
		}

		d3d12_queue_res := d3d12_device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&d3d12_queue))
		win32_hr_assert(d3d12_device_res, "Failed creating D3D12 command queue")
	}
	
	{
		desc := dxgi.SWAP_CHAIN_DESC1 {
			Width = WINDOW_WIDTH,
			Height = WINDOW_HEIGHT,
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

		swapchain_hr := dxgi_factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(d3d12_queue), hwnd, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swapchain))
		win32_hr_assert(swapchain_hr, "Failed creating dxgi swapchain")
	}

	frame_index = swapchain->GetCurrentBackBufferIndex()

	{
		desc := d3d12.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = NUM_RENDERTARGETS,
			Type = .RTV,
			Flags = {},
		}

		desc_heap_res := d3d12_device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&rtv_descriptor_heap))
		win32_hr_assert(desc_heap_res, "Failed creating descriptor heap")
	}

	{
		rtv_descriptor_size: u32 = d3d12_device->GetDescriptorHandleIncrementSize(.RTV)

		rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

		for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
			res := swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&targets[i]))
			win32_hr_assert(res, "Failed getting render target")
			d3d12_device->CreateRenderTargetView(targets[i], nil, rtv_descriptor_handle)
			rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
		}
	}

	{
		res := d3d12_device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&command_allocator))
		win32_hr_assert(res, "Failed creating command allocator")
	}

	{
		desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
			Version = ._1_0,
		}

		desc.Desc_1_0.Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}
		serialized_desc: ^d3d12.IBlob
		ser_root_sig_hr := d3d12.SerializeVersionedRootSignature(&desc, &serialized_desc, nil)
		win32_hr_assert(ser_root_sig_hr, "Failed to serialize root signature")
		root_sig_hr := d3d12_device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&root_signature))
		win32_hr_assert(root_sig_hr, "Failed creating root signature")
		serialized_desc->Release()
	}

	{
		// Compile vertex and pixel shaders
		data :cstring=
			`struct PSInput {
			   float4 position : SV_POSITION;
			   float4 color : COLOR;
			};
			PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
			   PSInput result;
			   result.position = position;
			   result.color = color;
			   return result;
			}
			float4 PSMain(PSInput input) : SV_TARGET {
			   return input.color;
			};`

		data_size: uint = len(data)

		compile_flags: u32 = 0
		when ODIN_DEBUG {
			compile_flags |= u32(d3dc.D3DCOMPILE.DEBUG)
			compile_flags |= u32(d3dc.D3DCOMPILE.SKIP_OPTIMIZATION)
		}

		vs: ^d3d12.IBlob = nil
		ps: ^d3d12.IBlob = nil

		vs_res := d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, nil)
		win32_hr_assert(vs_res, "Failed to compile vertex shader")

		ps_res := d3dc.Compile(rawptr(data), data_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, nil)
		win32_hr_assert(ps_res, "Failed to compile pixel shader")

		// This layout matches the vertices data defined further down
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
			pRootSignature = root_signature,
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
		
		pipeline_res := d3d12_device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pipeline))
		win32_hr_assert(pipeline_res, "Pipeline creation failed")

		vs->Release()
		ps->Release()
	}

	hr = d3d12_device->CreateCommandList(0, .DIRECT, command_allocator, pipeline, d3d12.ICommandList_UUID, (^rawptr)(&cmdlist))
	win32_hr_assert(hr, "Failed to create command list")
	hr = cmdlist->Close()
	win32_hr_assert(hr, "Failed to close command list")

	vertex_buffer: ^d3d12.IResource

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

		hr = d3d12_device->CreateCommittedResource(&heap_props, {}, &resource_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&vertex_buffer))
		win32_hr_assert(hr, "Failed creating vertex buffer")

		gpu_data: rawptr
		read_range: d3d12.RANGE

		hr = vertex_buffer->Map(0, &read_range, &gpu_data)
		win32_hr_assert(hr, "Failed creating verex buffer resource")

		mem.copy(gpu_data, &vertices[0], vertex_buffer_size)
		vertex_buffer->Unmap(0, nil)

		vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
			BufferLocation = vertex_buffer->GetGPUVirtualAddress(),
			StrideInBytes = u32(vertex_buffer_size/3),
			SizeInBytes = u32(vertex_buffer_size),
		}
	}

	// This fence is used to wait for frames to finish

	{
		hr = d3d12_device->CreateFence(fence_value, {}, d3d12.IFence_UUID, (^rawptr)(&fence))
		win32_hr_assert(hr, "Failed to create fence")
		fence_value += 1
		manual_reset: win.BOOL = false
		initial_state: win.BOOL = false
		fence_event = win.CreateEventW(nil, manual_reset, initial_state, nil)
		assert(fence_event != nil, "Failed to create fence event")
	}

	msg: win.MSG

	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}

window_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
	case win.WM_PAINT:
		hr: win.HRESULT
		hr = command_allocator->Reset()
		win32_hr_assert(hr, "Failed resetting command allocator")

		hr = cmdlist->Reset(command_allocator, pipeline)
		win32_hr_assert(hr, "Failed to reset command list")

		viewport := d3d12.VIEWPORT {
			Width = WINDOW_WIDTH,
			Height = WINDOW_HEIGHT,
		}

		scissor_rect := d3d12.RECT {
			left = 0, right = WINDOW_WIDTH,
			top = 0, bottom = WINDOW_HEIGHT,
		}

		// This state is reset everytime the cmd list is reset, so we need to rebind it
		cmdlist->SetGraphicsRootSignature(root_signature)
		cmdlist->RSSetViewports(1, &viewport)
		cmdlist->RSSetScissorRects(1, &scissor_rect)

		to_render_target_barrier := d3d12.RESOURCE_BARRIER {
			Type = .TRANSITION,
			Flags = {},
		}

		to_render_target_barrier.Transition = {
			pResource = targets[frame_index],
			StateBefore = d3d12.RESOURCE_STATE_PRESENT,
			StateAfter = {.RENDER_TARGET},
			Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
		}

		cmdlist->ResourceBarrier(1, &to_render_target_barrier)

		rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

		if (frame_index > 0) {
			s := d3d12_device->GetDescriptorHandleIncrementSize(.RTV)
			rtv_handle.ptr += uint(frame_index * s)
		}

		cmdlist->OMSetRenderTargets(1, &rtv_handle, false, nil)

		// clear backbuffer
		clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
		cmdlist->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)

		// draw call
		cmdlist->IASetPrimitiveTopology(.TRIANGLELIST)
		cmdlist->IASetVertexBuffers(0, 1, &vertex_buffer_view)
		cmdlist->DrawInstanced(3, 1, 0, 0)
		
		to_present_barrier := to_render_target_barrier
		to_present_barrier.Transition.StateBefore = {.RENDER_TARGET}
		to_present_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT

		cmdlist->ResourceBarrier(1, &to_present_barrier)

		hr = cmdlist->Close()
		win32_hr_assert(hr, "Failed to close command list")

		// execute
		cmdlists := [?]^d3d12.IGraphicsCommandList { cmdlist }
		d3d12_queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))

		// present
		{
			flags: dxgi.PRESENT
			params: dxgi.PRESENT_PARAMETERS
			hr = swapchain->Present1(1, flags, &params)
			win32_hr_assert(hr, "Present failed")
		}

		// wait for frame to finish
		{
			current_fence_value := fence_value

			hr = d3d12_queue->Signal(fence, current_fence_value)
			win32_hr_assert(hr, "Failed to signal fence")

			fence_value += 1
			completed := fence->GetCompletedValue()

			if completed < current_fence_value {
				hr = fence->SetEventOnCompletion(current_fence_value, fence_event)
				win32_hr_assert(hr, "Failed to set event on completion flag")
				win.WaitForSingleObject(fence_event, win.INFINITE)
			}

			frame_index = swapchain->GetCurrentBackBufferIndex()
		}		
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}