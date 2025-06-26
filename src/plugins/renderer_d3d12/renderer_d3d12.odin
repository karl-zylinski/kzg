package renderer_d3d12

import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:time"
import sa "core:container/small_array"
import vmem "core:mem/virtual"
import win "core:sys/windows"

import "vendor:directx/dxc"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

import hm "kzg:base/handle_map"
import "kzg:base"

NUM_RENDERTARGETS :: 2

Vec3 :: base.Vec3

g_info_queue: ^d3d12.IInfoQueue

@opaque
State :: struct {
	device: ^d3d12.IDevice5,
	dxgi_factory: ^dxgi.IFactory7,
	command_queue: ^d3d12.ICommandQueue,
	info_queue: ^d3d12.IInfoQueue,
	debug: ^d3d12.IDebug,
	
	dxc_library: ^dxc.ILibrary,
	dxc_compiler: ^dxc.ICompiler3,

	buffers: hm.Handle_Map(Buffer, Buffer_Handle, 1024),
	shaders: hm.Handle_Map(Shader, Shader_Handle, 1024),
	swapchains: hm.Handle_Map(Swapchain, Swapchain_Handle, 16),
	pipelines: hm.Handle_Map(Pipeline, Pipeline_Handle, 128),
}

Buffer :: struct {
	buf: ^d3d12.IResource,
	element_size: int,
	num_elements: int,
}

Shader_Resource_Binding_Type :: enum {
	CBV,
	SRV,
}

Shader_Resource :: struct {
	binding_type: Shader_Resource_Binding_Type,
	space: u32,
	register: u32,
}

Shader :: struct {
	vs_bytecode: d3d12.SHADER_BYTECODE,
	ps_bytecode: d3d12.SHADER_BYTECODE,

	// value is index into resources
	resource_lookup: map[string]int,

	resources: []Shader_Resource,
	resources_arena: vmem.Arena
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
	renderer: ^State,
	pipeline: ^d3d12.IPipelineState,
	root_signature: ^d3d12.IRootSignature,
	cbv_descriptor_heap: ^d3d12.IDescriptorHeap,
	shader: Shader_Handle,
}

@opaque
Command_List :: struct {
	swapchain: ^Swapchain,
	pipeline: ^Pipeline,
	command_allocator: ^d3d12.ICommandAllocator,
	list: ^d3d12.IGraphicsCommandList,
}

@api
create :: proc(allocator := context.allocator, loc := #caller_location) -> ^State {
	log.info("Creating D3D12 renderer.")
	s := new(State, allocator, loc)
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
		if hr == win.S_FALSE {
			// The above just tests if the device creation would work. It returns S_FALSE if it would (???)
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
		hr = dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, (^rawptr)(&s.dxc_compiler))
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

		iq->ClearStoredMessages()
	}
}

check :: proc(res: d3d12.HRESULT, message: string, loc := #caller_location) {
	if res >= 0 {
		return
	}

	log.errorf("D3D12 error: %0x", u32(res), location = loc)
	check_messages(loc)
}

@api
destroy :: proc(s: ^State) {
	log.info("Destroying D3D12 renderer.")
	
	s.dxc_compiler->Release()
	s.dxc_library->Release()
	s.command_queue->Release()
	s.device->Release()
	s.dxgi_factory->Release()

	when ODIN_DEBUG {
		dxgi_debug: ^dxgi.IDebug1

		if win.SUCCEEDED(dxgi.DXGIGetDebugInterface1(0, dxgi.IDebug1_UUID, (^rawptr)(&dxgi_debug))) {
			dxgi_debug->ReportLiveObjects(dxgi.DEBUG_ALL, dxgi.DEBUG_RLO_FLAGS.DETAIL | dxgi.DEBUG_RLO_FLAGS.IGNORE_INTERNAL)
			dxgi_debug->Release()
		}

		check_messages()
		s.debug->Release()
	}

	s.info_queue->Release()
	free(s)
}

@api
create_swapchain :: proc(s: ^State, hwnd: u64, width: int, height: int) -> Swapchain_Handle {
	log.infof("Creating swapchain with size %v x %v", width, height)
	ensure(hwnd != 0, "Invalid window handle")
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

		hr = s.dxgi_factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(s.command_queue), transmute(win.HWND)(hwnd), &desc, nil, nil, (^^dxgi.ISwapChain1)(&swap.swapchain))
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

	return hm.add(&s.swapchains, swap)
}

@api
destroy_swapchain :: proc(s: ^State, sh: Swapchain_Handle) {
	swap := hm.get(&s.swapchains, sh)

	if swap == nil {
		return
	}

	for i in 0..<NUM_RENDERTARGETS {
		swap.fences[i].fence->Release()
		swap.command_allocators[i]->Release()
		swap.targets[i]->Release()
	}

	swap.rtv_descriptor_heap->Release()
	swap.swapchain->Release()
}

@api
create_pipeline :: proc(s: ^State, shader_handle: Shader_Handle) -> Pipeline_Handle {
	hr: win.HRESULT
	pip := Pipeline {
		renderer = s,
		shader = shader_handle,
	}

	shader := hm.get(&s.shaders, shader_handle)
	assert(s != nil)
	
	{
		desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
			Version = ._1_0,
		}

	
		descriptor_ranges := make([dynamic]d3d12.DESCRIPTOR_RANGE, context.temp_allocator)

		for r in shader.resources {
			type: d3d12.DESCRIPTOR_RANGE_TYPE

			switch r.binding_type {
			case .CBV: type = .CBV
			case .SRV: type = .SRV
			}

			append(&descriptor_ranges, d3d12.DESCRIPTOR_RANGE {
				RangeType = type,
				BaseShaderRegister = r.register,
				NumDescriptors = 1,
				RegisterSpace = r.space,
				OffsetInDescriptorsFromTableStart = d3d12.DESCRIPTOR_RANGE_OFFSET_APPEND,
			})
		}

		root_parameters := [?]d3d12.ROOT_PARAMETER {
			{
				ParameterType = .DESCRIPTOR_TABLE,
				ShaderVisibility = .ALL,
				DescriptorTable = {
					NumDescriptorRanges = u32(len(descriptor_ranges)),
					pDescriptorRanges = raw_data(descriptor_ranges)
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
			VS = shader.vs_bytecode,
			PS = shader.ps_bytecode,
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
	}

	{
		desc := d3d12.COMMAND_QUEUE_DESC {
			Type = .DIRECT,
		}

		hr = s.device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&s.command_queue))
		check(hr, "Failed creating D3D12 command queue")
	}
	
	return hm.add(&s.pipelines, pip)
}

@api
destroy_pipeline :: proc(rs: ^State, ph: Pipeline_Handle) {
	pip := hm.get(&rs.pipelines, ph)

	if pip == nil {
		return
	}

	pip.pipeline->Release()
	pip.cbv_descriptor_heap->Release()
	pip.root_signature->Release()
}

@api
flush :: proc(s: ^State, sh: Swapchain_Handle) {
	swap := hm.get(&s.swapchains, sh)

	if swap == nil {
		return
	}

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

@api
begin_frame :: proc(s: ^State, sh: Swapchain_Handle) {
	swap := hm.get(&s.swapchains, sh)

	if swap == nil {
		return
	}

	fence := &swap.fences[swap.frame_index]
	wait_for_fence(s, fence)
	hr := swap.command_allocators[swap.frame_index]->Reset()
	check(hr, "Failed resetting command allocator")
}

@api
draw :: proc(s: ^State, cmd: ^Command_List, index_buffer: Buffer_Handle, n: int) {
	ib := hm.get(&s.buffers, index_buffer)

	if ib == nil {
		return
	}

	index_buffer_view := d3d12.INDEX_BUFFER_VIEW {
		BufferLocation = ib.buf->GetGPUVirtualAddress(),
		SizeInBytes = u32(ib.element_size * ib.num_elements),
		Format = .R32_UINT,
	}

	cmd.list->IASetPrimitiveTopology(.TRIANGLELIST)
	cmd.list->IASetIndexBuffer(&index_buffer_view)
	cmd.list->DrawIndexedInstanced(u32(n), 1, 0, 0, 0)
}

@api
create_command_list :: proc(s: ^State, ph: Pipeline_Handle, sh: Swapchain_Handle) -> ^Command_List {
	pip := hm.get(&s.pipelines, ph)

	swap := hm.get(&s.swapchains, sh)

	if pip == nil || swap == nil {
		return nil
	}

	alloc := swap.command_allocators[swap.frame_index]
	cmd := new(Command_List)
	cmd^ = {
		swapchain = swap,
		command_allocator = alloc,
		pipeline = pip,
	}
	hr: win.HRESULT
	hr = pip.renderer.device->CreateCommandList(0, .DIRECT, alloc, pip.pipeline, d3d12.ICommandList_UUID, (^rawptr)(&cmd.list))
	check(hr, "Failed to create command list")
	hr = cmd.list->Close()
	check(hr, "Failed to close command list")
	return cmd
}

@api
destroy_command_list :: proc(rs: ^State, cmd: ^Command_List) {
	cmd.list->Release()
	free(cmd)
}

@api
set_buffer :: proc(rs: ^State, ph: Pipeline_Handle, name: string, h: Buffer_Handle) {
	p := hm.get(&rs.pipelines, ph)

	if p == nil {
		return
	}

	shader := hm.get(&p.renderer.shaders, p.shader)
	buf := hm.get(&p.renderer.buffers, h)

	if shader == nil || buf == nil {
		return
	}

	sz := buf.element_size * buf.num_elements

	if idx, idx_ok := shader.resource_lookup[name]; idx_ok {
		d3d_handle: d3d12.CPU_DESCRIPTOR_HANDLE
		p.cbv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&d3d_handle)
		d3d_handle.ptr += uint(p.renderer.device->GetDescriptorHandleIncrementSize(.CBV_SRV_UAV)) * uint(idx)

		res := &shader.resources[idx]

		switch res.binding_type {
		case .CBV:
			cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
				BufferLocation = buf.buf->GetGPUVirtualAddress(),
				SizeInBytes = u32(sz),
			}

			p.renderer.device->CreateConstantBufferView(&cbv_desc, d3d_handle)
		case .SRV:
			srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
				ViewDimension = .BUFFER,
				Format = .UNKNOWN,
				Shader4ComponentMapping = d3d12.ENCODE_SHADER_4_COMPONENT_MAPPING(0, 1, 2, 3),
				Buffer = {
					NumElements = u32(buf.num_elements),
					StructureByteStride = u32(buf.element_size),
				}
			}
			p.renderer.device->CreateShaderResourceView(buf.buf, &srv_desc, d3d_handle)
		}
	}
}

@api
begin_render_pass :: proc(s: ^State, cmd: ^Command_List) {
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

	sw := f32(swap.width)
	sh := f32(swap.height)

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
		s := pip.renderer.device->GetDescriptorHandleIncrementSize(.RTV)
		rtv_handle.ptr += uint(swap.frame_index * s)
	}

	cmd.list->OMSetRenderTargets(1, &rtv_handle, false, nil)

	clearcolor := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
	cmd.list->ClearRenderTargetView(rtv_handle, &clearcolor, 0, nil)
}

@api
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

@api
present :: proc(s: ^State, sh: Swapchain_Handle) {
	swap := hm.get(&s.swapchains, sh)

	if swap == nil {
		return
	}

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

@api
shader_create :: proc(s: ^State, shader_source: string) -> Shader_Handle {
	shader_size := u32(len(shader_source))

	vs_compiled: ^dxc.IBlob
	ps_compiled: ^dxc.IBlob

	source_blob: ^dxc.IBlobEncoding
	hr: d3d12.HRESULT
	hr = s.dxc_library->CreateBlobWithEncodingOnHeapCopy(raw_data(shader_source), shader_size, dxc.CP_UTF8, &source_blob)
	check(hr, "Failed creating shader blob")

	errors: ^dxc.IBlobEncoding

	enc: u32
	enc_known: dxc.BOOL
	res := source_blob->GetEncoding(&enc_known, &enc)
	check(res, "Failed getting encoding")

	buf := dxc.Buffer {
		Ptr = source_blob->GetBufferPointer(),
		Size = source_blob->GetBufferSize(),
		Encoding = enc_known ? enc : 0,
	}

	dxc_vs_args := make([dynamic]dxc.wstring, context.temp_allocator)

	when ODIN_DEBUG {
		append(&dxc_vs_args, win.L(dxc.ARG_DEBUG))
		append(&dxc_vs_args, win.L("-EVSMain"))
		append(&dxc_vs_args, win.L("-Tvs_6_2"))
	}

	vs_res: ^dxc.IResult
	hr = s.dxc_compiler->Compile(
		&buf,
		raw_data(dxc_vs_args), u32(len(dxc_vs_args)),
		nil,
		dxc.IResult_UUID, (^rawptr)(&vs_res))
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

	dxc_ps_args := make([dynamic]dxc.wstring, context.temp_allocator)

	when ODIN_DEBUG {
		append(&dxc_ps_args, win.L(dxc.ARG_DEBUG))
		append(&dxc_ps_args, win.L("-EPSMain"))
		append(&dxc_ps_args, win.L("-Tps_6_2"))
	}

	ps_res: ^dxc.IResult
	hr = s.dxc_compiler->Compile(
		&buf,
		raw_data(dxc_ps_args), u32(len(dxc_ps_args)),
		nil,
		dxc.IResult_UUID, &ps_res)
	check(hr, "Failed compiling pixel shader")
	ps_res->GetResult(&ps_compiled)
	check(hr, "Failed fetching compiled pixel shader")

	source_blob->Release()

	ps_res->GetErrorBuffer(&errors)
	errors_sz = errors != nil ? errors->GetBufferSize() : 0

	if errors_sz > 0 {
		errors_ptr := errors->GetBufferPointer()
		error_str := strings.string_from_ptr((^u8)(errors_ptr), int(errors_sz))
		log.error(error_str)
	}

	shader := Shader {
		vs_bytecode = d3d12.SHADER_BYTECODE {
			pShaderBytecode = vs_compiled->GetBufferPointer(),
			BytecodeLength = vs_compiled->GetBufferSize(),
		},
		ps_bytecode = d3d12.SHADER_BYTECODE {
			pShaderBytecode = ps_compiled->GetBufferPointer(),
			BytecodeLength = ps_compiled->GetBufferSize(),
		}
	}

	vs_reflect_blob: ^dxc.IBlob
	hr = vs_res->GetOutput(.REFLECTION, dxc.IBlob_UUID, (^rawptr)(&vs_reflect_blob), nil)
	check(hr, "Failed fetching shader reflection data")

	vs_reflect_buf := dxc.Buffer {
		Ptr = vs_reflect_blob->GetBufferPointer(),
		Size = vs_reflect_blob->GetBufferSize(),
		Encoding = 0,
	}

	utils: ^dxc.IUtils
	hr = dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, (^rawptr)(&utils))
	check(hr, "Failed fetching DXC utils")

	shader_reflection: ^d3d12.IShaderReflection
	hr = utils->CreateReflection(&vs_reflect_buf, d3d12.IShaderReflection_UUID, (^rawptr)(&shader_reflection))
	check(hr, "Failed creating shader reflection")

	shader_desc: d3d12.SHADER_DESC

	shader_reflection->GetDesc(&shader_desc)

	num_resources := shader_desc.BoundResources
	
	arena_err := vmem.arena_init_growing(&shader.resources_arena)
	assert(arena_err == nil)
	resources_alloc := vmem.arena_allocator(&shader.resources_arena)

	resources := make([]Shader_Resource, num_resources, resources_alloc)
	shader.resource_lookup = make(map[string]int, resources_alloc)

	input_desc: d3d12.SHADER_INPUT_BIND_DESC

	for i in 0..<num_resources {
		hr = shader_reflection->GetResourceBindingDesc(u32(i), &input_desc)

		if hr != 0 {
			break
		}

		binding_type: Shader_Resource_Binding_Type

		#partial switch input_desc.Type {
		case .CBUFFER: binding_type = .CBV
		case .STRUCTURED: binding_type = .SRV
		case: panic("Implement me!!")
		}

		resources[i] = Shader_Resource {
			binding_type = binding_type,
			space = input_desc.Space,
			register = input_desc.BindPoint,
		}

		shader.resource_lookup[strings.clone(string(input_desc.Name), resources_alloc)] = int(i)
	}

	shader.resources = resources

	return hm.add(&s.shaders, shader)
}

@api
shader_destroy :: proc(s: ^State, h: Shader_Handle) {
	shader := hm.get(&s.shaders, h)

	if shader == nil {
		return
	}

	vmem.arena_destroy(&shader.resources_arena)
}

@api
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

@api
buffer_destroy :: proc(s: ^State, h: Buffer_Handle) {
	if b := hm.get(&s.buffers, h); b != nil {
		b.buf->Release()
	}
}

@api
buffer_map :: proc(s: ^State, h: Buffer_Handle) -> rawptr {
	if b := hm.get(&s.buffers, h); b != nil {
		map_start: rawptr
		hr := b.buf->Map(0, &d3d12.RANGE{}, &map_start)
		check(hr, "Failed mapping buffer")
		return map_start
	}

	return nil
}

@api
buffer_unmap :: proc(s: ^State, h: Buffer_Handle) {
	if b := hm.get(&s.buffers, h); b != nil {
		b.buf->Unmap(0, nil)
	}
}

@api
swapchain_size :: proc(s: ^State, sh: Swapchain_Handle) -> base.Vec2i {
	swap := hm.get(&s.swapchains, sh)

	if swap == nil {
		return {}
	}
	
	return {swap.width, swap.height}
}
