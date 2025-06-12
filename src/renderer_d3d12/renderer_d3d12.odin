package Renderer

import "core:log"
import "core:mem"
import d3d12 "vendor:directx/d3d12"
import "vendor:directx/dxc"
import dxgi "vendor:directx/dxgi"
import win "core:sys/windows"
import "core:slice"
import "core:time"
import "core:math"
import la "core:math/linalg"
import "core:strings"
import sa "core:container/small_array"
import hm "../handle_map"

NUM_RENDERTARGETS :: 2

Mat4 :: matrix[4,4]f32
Vec3 :: [3]f32

g_info_queue: ^d3d12.IInfoQueue

State :: struct {
	device: ^d3d12.IDevice5,
	dxgi_factory: ^dxgi.IFactory7,
	command_queue: ^d3d12.ICommandQueue,
	info_queue: ^d3d12.IInfoQueue,
	debug: ^d3d12.IDebug,

	dxc_library: ^dxc.ILibrary,
	dxc_compiler: ^dxc.ICompiler,

	buffers: hm.Handle_Map(Buffer, Buffer_Handle, 1024),
}

Buffer_Handle :: distinct hm.Handle

Buffer :: struct {
	handle: Buffer_Handle,
	buf: ^d3d12.IResource,
	element_size: int,
	num_elements: int,
}

Swapchain :: struct {
	swapchain: ^dxgi.ISwapChain3,
	rtv_descriptor_heap: ^d3d12.IDescriptorHeap,
	targets: [NUM_RENDERTARGETS]^d3d12.IResource,
	command_allocators: [NUM_RENDERTARGETS]^d3d12.ICommandAllocator,
	fences: [NUM_RENDERTARGETS]Fence,
	frame_index: u32,
	width: int,
	height: int,
}

Fence :: struct {
	fence: ^d3d12.IFence,
	value: u64,
	event: win.HANDLE,	
}

Pipeline :: struct {
	device: ^d3d12.IDevice,
	pipeline: ^d3d12.IPipelineState,
	root_signature: ^d3d12.IRootSignature,
	cbv_descriptor_heap: ^d3d12.IDescriptorHeap,

	constant_buffer_res: ^d3d12.IResource,
	constant_buffer_start: rawptr,
}

Command_List :: struct {
	swapchain: ^Swapchain,
	pipeline: ^Pipeline,
	command_allocator: ^d3d12.ICommandAllocator,
	list: ^d3d12.IGraphicsCommandList,
}

valid :: proc(s: State) -> bool {
	return s.device != nil
}

create :: proc() -> State {
	log.info("Creating D3D12 renderer.")
	s: State
	hr: win.HRESULT

	ensure_hr :: proc(res: win.HRESULT, message: string, loc := #caller_location) {
		log.ensuref(res >= 0, "%v. Error code: %0x\n", message, u32(res), loc = loc)
	}

	when ODIN_DEBUG {
		hr = d3d12.GetDebugInterface(d3d12.IDebug_UUID, (^rawptr)(&s.debug))
		ensure_hr(hr, "Failed creating debug interface")

		if hr >= 0 {
			s.debug->EnableDebugLayer()
		}
	}

	{
		flags: dxgi.CREATE_FACTORY

		when ODIN_DEBUG {
			flags += { .DEBUG }
		}

		hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory7_UUID, (^rawptr)(&s.dxgi_factory))
		ensure_hr(hr, "Failed creating DXGI factory.")
	}

	dxgi_adapter: ^dxgi.IAdapter4

	for i: u32 = 0; s.dxgi_factory->EnumAdapterByGpuPreference(i, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, (^rawptr)(&dxgi_adapter)) == 0; i += 1 {
		hr = d3d12.CreateDevice((^dxgi.IUnknown)(dxgi_adapter), ._12_0, d3d12.IDevice5_UUID, nil)
		if hr >= 0 {
			break
		} else {
			d: dxgi.ADAPTER_DESC
			dxgi_adapter->GetDesc(&d)
			log.info("Can't use adapter %v, skipping: %v", i, d)
		}
	}

	ensure(dxgi_adapter != nil, "Could not find usable adapter")

	hr = d3d12.CreateDevice((^dxgi.IUnknown)(dxgi_adapter), ._12_0, d3d12.IDevice5_UUID, (^rawptr)(&s.device))
	ensure_hr(hr, "Failed to creating D3D12 device")

	when ODIN_DEBUG {
		hr = s.device->QueryInterface(d3d12.IInfoQueue_UUID, (^rawptr)(&s.info_queue))

		// TODO: This is used by `check`. Is it thread safe to use it from any thread?
		g_info_queue = s.info_queue
	}

	// DXC
	{
		hr = dxc.CreateInstance(dxc.Library_CLSID, dxc.ILibrary_UUID, (^rawptr)(&s.dxc_library))
		check(hr, "Failed to create DXC library")
		hr = dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler_UUID, (^rawptr)(&s.dxc_compiler))
		check(hr, "Failed to create DXC compiler")
	}

	return s
}

check_messages :: proc(loc := #caller_location) {
	iq := g_info_queue
	if iq != nil {
		n := iq->GetNumStoredMessages()
		longest_msg: d3d12.SIZE_T

		for i in 0..=n {
			msglen: d3d12.SIZE_T
			iq->GetMessageA(i, nil, &msglen)

			if msglen > longest_msg {
				longest_msg = msglen
			}
		}

		if longest_msg > 0 {
			msg_raw_ptr, _ := (mem.alloc(int(longest_msg), allocator = context.temp_allocator))

			for i in 0..=n {
				msglen: d3d12.SIZE_T
				iq->GetMessageA(i, nil, &msglen)

				if msglen > 0 {
					msg := (^d3d12.MESSAGE)(msg_raw_ptr)
					iq->GetMessageA(i, msg, &msglen)
					log.error(msg.pDescription, location = loc)
				}
			}
		}
	}
}

check :: proc(res: d3d12.HRESULT, message: string, loc := #caller_location) {
	if res >= 0 {
		return
	}

	log.errorf("D3D12 error: %0x", u32(res), location = loc)
	check_messages(loc)
}

destroy :: proc(s: ^State) {
	log.info("Destroying D3D12 renderer.")
	s.command_queue->Release()
	s.device->Release()
	s.dxgi_factory->Release()
}

create_swapchain :: proc(s: ^State, hwnd: win.HWND, width: int, height: int) -> Swapchain {
	log.infof("Creating swapchain with size %v x %v", width, height)
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

		hr = s.dxgi_factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(s.command_queue), hwnd, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swap.swapchain))
		check(hr, "Failed creating dxgi swapchain")
	}

	swap.frame_index = swap.swapchain->GetCurrentBackBufferIndex()

	{
		desc := d3d12.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = NUM_RENDERTARGETS,
			Type = .RTV,
			Flags = {},
		}

		hr = s.device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&swap.rtv_descriptor_heap))
		check(hr, "Failed creating descriptor heap")
	}


	{
		rtv_descriptor_size: u32 = s.device->GetDescriptorHandleIncrementSize(.RTV)

		rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		swap.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

		for i :u32= 0; i < NUM_RENDERTARGETS; i += 1 {
			res := swap.swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&swap.targets[i]))
			check(res, "Failed getting render target")
			s.device->CreateRenderTargetView(swap.targets[i], nil, rtv_descriptor_handle)
			rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
		}
	}

	{
		for i in 0..<NUM_RENDERTARGETS {
			hr = s.device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&swap.command_allocators[i]))
			check(hr, "Failed creating command allocator")

			hr = s.device->CreateFence(0, {}, d3d12.IFence_UUID, (^rawptr)(&swap.fences[i].fence))
			check(hr, "Failed to create fence")
			manual_reset: win.BOOL = false
			initial_state: win.BOOL = false
			swap.fences[i].event = win.CreateEventW(nil, manual_reset, initial_state, nil)
			assert(swap.fences[i].event != nil, "Failed to create fence event")
		}
	}

	return swap
}

destroy_swapchain :: proc(swap: ^Swapchain) {
	for i in 0..<NUM_RENDERTARGETS {
		swap.fences[i].fence->Release()
		swap.command_allocators[i]->Release()
		swap.targets[i]->Release()
	}

	swap.rtv_descriptor_heap->Release()
	swap.swapchain->Release()
}


Constant_Buffer :: struct #align(256) {
	mvp: matrix[4, 4]f32,
}

create_pipeline :: proc(s: ^State, shader_source: string) -> Pipeline {
	hr: win.HRESULT
	pip := Pipeline {
		device = s.device,
	}
	
	{
		desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
			Version = ._1_0,
		}

		desc.Desc_1_0.Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT}

		descriptor_ranges := [?]d3d12.DESCRIPTOR_RANGE {
			{
				RangeType = .CBV,
				BaseShaderRegister = 0,
				NumDescriptors = 1,
				RegisterSpace = 0,
				OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
			},
			{
				RangeType = .SRV,
				BaseShaderRegister = 0,
				NumDescriptors = 1,
				RegisterSpace = 0,
				OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
			}
		}

		root_parameters := [?]d3d12.ROOT_PARAMETER {
			{
				ParameterType = .DESCRIPTOR_TABLE,
				ShaderVisibility = .ALL,
				DescriptorTable = {
					NumDescriptorRanges = 2,
					pDescriptorRanges = raw_data(&descriptor_ranges)
				}
			}
		}

		desc.Desc_1_0.pParameters = raw_data(&root_parameters)
		desc.Desc_1_0.NumParameters = 1
		serialized_desc: ^d3d12.IBlob
		ser_root_sig_hr := d3d12.SerializeVersionedRootSignature(&desc, &serialized_desc, nil)
		check(ser_root_sig_hr, "Failed to serialize root signature")
		root_sig_hr := s.device->CreateRootSignature(0, serialized_desc->GetBufferPointer(), serialized_desc->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&pip.root_signature))
		check(root_sig_hr, "Failed creating root signature")
		serialized_desc->Release()
	}

	{
		cbv_heap_desc := d3d12.DESCRIPTOR_HEAP_DESC {
			NumDescriptors = 2,
			Flags = { .SHADER_VISIBLE },
			Type = .CBV_SRV_UAV,
		}
		hr = s.device->CreateDescriptorHeap(&cbv_heap_desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&pip.cbv_descriptor_heap))
		check(hr, "Failed c reating constant buffer descriptor heap.")
	}

	{
		shader_size := u32(len(shader_source))

		vs_compiled: ^dxc.IBlob
		ps_compiled: ^dxc.IBlob

		source_blob: ^dxc.IBlobEncoding
		hr = s.dxc_library->CreateBlobWithEncodingOnHeapCopy(raw_data(shader_source), shader_size, dxc.CP_UTF8, &source_blob)
		check(hr, "Failed creating shader blob")


		errors: ^dxc.IBlobEncoding

		vs_res: ^dxc.IOperationResult

		enc: u32
		enc_known: dxc.BOOL
		res := source_blob->GetEncoding(&enc_known, &enc)
		check(res, "Failed getting encoding")

		buf := dxc.Buffer {
			Ptr = source_blob->GetBufferPointer(),
			Size = source_blob->GetBufferSize(),
			Encoding = enc_known ? enc : 0,
		}

		hr = s.dxc_compiler->Compile(&source_blob.idxcblob, win.L("shader.hlsl"), win.L("VSMain"), win.L("vs_6_2"), nil, 0, nil, 0, nil, &vs_res)
		check(hr, "Failed compiling vertex shader")
		vs_res->GetResult(&vs_compiled)
		check(hr, "Failed fetching compiled vertex shader")

		vs_res->GetErrorBuffer(&errors)
		errors_sz := errors != nil ? errors->GetBufferSize() : 0

		if errors_sz > 0 {
			errors_ptr := errors->GetBufferPointer()
			error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
			log.error(error_str)
		}

		ps_res: ^dxc.IOperationResult
		hr = s.dxc_compiler->Compile(&source_blob.idxcblob, win.L("shader.hlsl"), win.L("PSMain"), win.L("ps_6_2"), nil, 0, nil, 0, nil, &ps_res)
		check(hr, "Failed compiling pixel shader")
		ps_res->GetResult(&ps_compiled)
		check(hr, "Failed fetching compiled pixel shader")

		ps_res->GetErrorBuffer(&errors)
		errors_sz = errors != nil ? errors->GetBufferSize() : 0

		if errors_sz > 0 {
			errors_ptr := errors->GetBufferPointer()
			error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
			log.error(error_str)
		}

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
				pShaderBytecode = vs_compiled->GetBufferPointer(),
				BytecodeLength = vs_compiled->GetBufferSize(),
			},
			PS = {
				pShaderBytecode = ps_compiled->GetBufferPointer(),
				BytecodeLength = ps_compiled->GetBufferSize(),
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

		hr = s.device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pip.pipeline))
		check(hr, "Failed creating pipeline")

		vs_compiled->Release()
		ps_compiled->Release()
	}

	{
		desc := d3d12.COMMAND_QUEUE_DESC {
			Type = .DIRECT,
		}

		hr = s.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&s.command_queue))
		check(hr, "Failed creating D3D12 command queue")
	}

	{
		cb_size := size_of(Constant_Buffer)

		buffer_desc := d3d12.RESOURCE_DESC {
			Dimension = .BUFFER,
			Width = u64(cb_size),
			Height = 1,
			DepthOrArraySize = 1,
			MipLevels = 1,
			SampleDesc = { Count = 1, Quality = 0, },
			Layout = .ROW_MAJOR,
		}

		hr = s.device->CreateCommittedResource(
			&d3d12.HEAP_PROPERTIES { Type = .UPLOAD },
			{},
			&buffer_desc,
			d3d12.RESOURCE_STATE_GENERIC_READ,
			nil,
			d3d12.IResource_UUID,
			(^rawptr)(&pip.constant_buffer_res),
		)

		check(hr, "Failed creating constant buffer resource")

		cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
			BufferLocation = pip.constant_buffer_res->GetGPUVirtualAddress(),
			SizeInBytes = u32(cb_size),
		}

		handle: d3d12.CPU_DESCRIPTOR_HANDLE
		pip.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&handle)
		s.device->CreateConstantBufferView(&cbv_desc, handle)
		hr = pip.constant_buffer_res->Map(0, &d3d12.RANGE{}, (^rawptr)(&pip.constant_buffer_start))
		check(hr, "Failed mapping cb")
	}

	
	return pip
}

destroy_pipeline :: proc(pip: ^Pipeline) {
	pip.pipeline->Release()
	pip.root_signature->Release()
}


flush :: proc(s: ^State, swap: ^Swapchain) {
	for &f in swap.fences {
		s.command_queue->Signal(f.fence, f.value)
		wait_for_fence(s, &f)
	}
}

wait_for_fence :: proc(s: ^State, fence: ^Fence) {
	completed := fence.fence->GetCompletedValue()

	if completed < fence.value {
		hr := fence.fence->SetEventOnCompletion(fence.value, fence.event)
		check(hr, "Failed to set event on completion flag")
		win.WaitForSingleObject(fence.event, win.INFINITE)
	}
}

/*

		ui_elements_view_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
			ViewDimension = .BUFFER,
			Format = .UNKNOWN,
			Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 1, 2, 3),
			Buffer = {
				NumElements = 2048,
				StructureByteStride = size_of(UI_Element),
			}
		}

		handle: d3d12.CPU_DESCRIPTOR_HANDLE
		pip.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&handle)
		handle.ptr += uint(device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)) * 1
		device->CreateShaderResourceView(ui.ui_elements_res, &ui_elements_view_desc, handle)
		check_messages()








		
		*/

begin_frame :: proc(s: ^State, swap: ^Swapchain) {
	fence := &swap.fences[swap.frame_index]
	wait_for_fence(s, fence)
	hr := swap.command_allocators[swap.frame_index]->Reset()
	check(hr, "Failed resetting command allocator")
}

draw :: proc(s: ^State, cmd: Command_List, vertex_buffer: Buffer_Handle, index_buffer: Buffer_Handle, n: int) {
	vb := hm.get(&s.buffers, vertex_buffer)
	ib := hm.get(&s.buffers, index_buffer)

	if ib == nil || vb == nil {
		return
	}

	vertex_buffer_view := d3d12.VERTEX_BUFFER_VIEW {
		BufferLocation = vb.buf->GetGPUVirtualAddress(),
		StrideInBytes = u32(vb.element_size),
		SizeInBytes = u32(vb.element_size * vb.num_elements),
	}

	index_buffer_view := d3d12.INDEX_BUFFER_VIEW {
		BufferLocation = ib.buf->GetGPUVirtualAddress(),
		SizeInBytes = u32(ib.element_size * ib.num_elements),
		Format = .R32_UINT,
	}

	cmd.list->IASetPrimitiveTopology(.TRIANGLELIST)
	cmd.list->IASetVertexBuffers(0, 1, &vertex_buffer_view)
	cmd.list->IASetIndexBuffer(&index_buffer_view)
	cmd.list->DrawIndexedInstanced(u32(n), 1, 0, 0, 0)
}

create_command_list :: proc(pip: ^Pipeline, swap: ^Swapchain) -> Command_List {
	alloc := swap.command_allocators[swap.frame_index]
	cmd := Command_List {
		swapchain = swap,
		command_allocator = alloc,
		pipeline = pip,
	}
	hr: win.HRESULT
	hr = pip.device->CreateCommandList(0, .DIRECT, alloc, pip.pipeline, d3d12.ICommandList_UUID, (^rawptr)(&cmd.list))
	check(hr, "Failed to create command list")
	hr = cmd.list->Close()
	check(hr, "Failed to close command list")
	return cmd
}

t: f32

begin_render_pass :: proc(s: ^State, cmd: ^Command_List, elements: Buffer_Handle) {
	hr: win.HRESULT
	hr = cmd.list->Reset(cmd.command_allocator, cmd.pipeline.pipeline)
	check(hr, "Failed to reset command list")
	swap := cmd.swapchain
	pip := cmd.pipeline

	viewport := d3d12.VIEWPORT {
		Width = f32(swap.width),
		Height = f32(swap.height),
	}

	scissor_rect := d3d12.RECT {
		left = 0, right = i32(swap.width),
		top = 0, bottom = i32(swap.height),
	}

	t += 1

	sw := f32(swap.width)
	sh := f32(swap.height)

	if eb := hm.get(&s.buffers, elements); eb != nil {
		ui_elements_view_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
			ViewDimension = .BUFFER,
			Format = .UNKNOWN,
			Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 1, 2, 3),
			Buffer = {
				NumElements = u32(eb.num_elements),
				StructureByteStride = u32(eb.element_size),
			}
		}

		handle: d3d12.CPU_DESCRIPTOR_HANDLE
		pip.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&handle)
		handle.ptr += uint(s.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)) * 1
		s.device->CreateShaderResourceView(eb.buf, &ui_elements_view_desc, handle)
		check_messages()
	}

	mvp := la.matrix4_scale(Vec3{2.0/sw, -2.0/sh, 1}) * la.matrix4_translate(Vec3{-sw/2, -sh/2, 0})

	cb := Constant_Buffer {
		mvp = la.transpose(mvp),
	}

	mem.copy(pip.constant_buffer_start, &cb, size_of(cb))

	cmd.list->SetGraphicsRootSignature(pip.root_signature)
	heaps := [?]^d3d12.IDescriptorHeap {
		pip.cbv_descriptor_heap,
	}

	cmd.list->SetDescriptorHeaps(1, raw_data(&heaps))
	table_handle: d3d12.GPU_DESCRIPTOR_HANDLE
	cmd.pipeline.cbv_descriptor_heap->GetGPUDescriptorHandleForHeapStart(&table_handle)
	cmd.list->SetGraphicsRootDescriptorTable(0, table_handle)

	cmd.list->RSSetViewports(1, &viewport)
	cmd.list->RSSetScissorRects(1, &scissor_rect)

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

	cmd.list->ResourceBarrier(1, &to_render_target_barrier)


	rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
	swap.rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)

	if swap.frame_index > 0 {
		s := pip.device->GetDescriptorHandleIncrementSize(.RTV)
		rtv_handle.ptr += uint(swap.frame_index * s)
	}

	cmd.list->OMSetRenderTargets(1, &rtv_handle, false, nil)

	clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
	cmd.list->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)
}

execute_command_list :: proc(s: ^State, cmd: ^Command_List) {
	hr: win.HRESULT

	to_present_barrier := d3d12.RESOURCE_BARRIER {
		Type = .TRANSITION,
		Flags = {},
		Transition = {
			pResource = cmd.swapchain.targets[cmd.swapchain.frame_index],
			StateBefore = {.RENDER_TARGET},
			StateAfter = d3d12.RESOURCE_STATE_PRESENT,
			Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,	
		}
	}

	cmd.list->ResourceBarrier(1, &to_present_barrier)

	hr = cmd.list->Close()
	check(hr, "Failed to close command list")
	cmdlists := [?]^d3d12.IGraphicsCommandList { cmd.list }
	s.command_queue->ExecuteCommandLists(len(cmdlists), (^^d3d12.ICommandList)(&cmdlists[0]))
}

present :: proc(s: ^State, swap: ^Swapchain) {
	flags: dxgi.PRESENT
	params: dxgi.PRESENT_PARAMETERS
	hr := swap.swapchain->Present1(1, flags, &params)
	check(hr, "Present failed")
	fence := &swap.fences[swap.frame_index]
	fence.value += 1
	hr = s.command_queue->Signal(fence.fence, fence.value)
	check(hr, "Failed to signal fence")
	swap.frame_index = swap.swapchain->GetCurrentBackBufferIndex()
}

buffer_create :: proc(s: ^State, num_elements: int, element_size: int) -> Buffer_Handle {
	desc := d3d12.RESOURCE_DESC {
		Dimension = .BUFFER,
		Layout = .ROW_MAJOR,
		Flags = {},
		Width = u64(num_elements * element_size),
		Height = 1,
		DepthOrArraySize = 1,
		MipLevels = 1,
		SampleDesc = { Count = 1, Quality = 0 }
	}

	hr: d3d12.HRESULT
	res: ^d3d12.IResource

	hr = s.device->CreateCommittedResource(
		&d3d12.HEAP_PROPERTIES { Type = .UPLOAD },
		{},
		&desc,
		d3d12.RESOURCE_STATE_GENERIC_READ,
		nil,
		d3d12.IResource_UUID,
		(^rawptr)(&res))

	check(hr, "Failed creating UI elements buffer")

	b := Buffer {
		buf = res,
		element_size = element_size,
		num_elements = num_elements,
	}

	return hm.add(&s.buffers, b)
}

buffer_map :: proc(s: ^State, h: Buffer_Handle) -> rawptr {
	if b := hm.get(&s.buffers, h); b != nil {
		map_start: rawptr
		hr := b.buf->Map(0, &d3d12.RANGE{}, &map_start)
		check(hr, "Failed mapping buffer")
		return map_start
	}

	return nil
}

buffer_unmap :: proc(s: ^State, h: Buffer_Handle) {
	if b := hm.get(&s.buffers, h); b != nil {
		b.buf->Unmap(0, nil)
	}
}