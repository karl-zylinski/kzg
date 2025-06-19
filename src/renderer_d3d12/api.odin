package renderer_d3d12

import hm "kzg:base/handle_map"
import "kzg:base"

Renderer_D3D12_State :: struct{}

Shader_Handle :: distinct hm.Handle
Buffer_Handle :: distinct hm.Handle
Swapchain_Handle :: distinct hm.Handle
Pipeline_Handle :: distinct hm.Handle

Command_List_Opq :: struct {}

Renderer_D3D12 :: struct {
	create: proc(allocator := context.allocator, loc := #caller_location) -> ^Renderer_D3D12_State,
	shader_create: proc(self: ^Renderer_D3D12_State, source: string) -> Shader_Handle,
	create_pipeline: proc(self: ^Renderer_D3D12_State, shader_handle: Shader_Handle) -> Pipeline_Handle,
	create_swapchain: proc(s: ^Renderer_D3D12_State, hwnd: u64, width: int, height: int) -> Swapchain_Handle,
	buffer_create: proc(s: ^Renderer_D3D12_State, num_elements: int, element_size: int) -> Buffer_Handle,
	buffer_map: proc(s: ^Renderer_D3D12_State, h: Buffer_Handle) -> rawptr,
	set_buffer: proc(rs: ^Renderer_D3D12_State, ph: Pipeline_Handle, name: string, h: Buffer_Handle),
	begin_frame: proc(s: ^Renderer_D3D12_State, swap: Swapchain_Handle),
	create_command_list: proc(s: ^Renderer_D3D12_State, ph: Pipeline_Handle, swap: Swapchain_Handle) -> ^Command_List_Opq,
	begin_render_pass: proc(s: ^Renderer_D3D12_State, cmd: ^Command_List_Opq),
	draw: proc(s: ^Renderer_D3D12_State, cmd: ^Command_List_Opq, index_buffer: Buffer_Handle, n: int),
	execute_command_list: proc(s: ^Renderer_D3D12_State, cmd: ^Command_List_Opq),
	destroy_command_list: proc(cmd: ^Command_List_Opq),
	present: proc(s: ^Renderer_D3D12_State, swap: Swapchain_Handle),
	flush: proc(s: ^Renderer_D3D12_State, swap: Swapchain_Handle),
	buffer_destroy: proc(s: ^Renderer_D3D12_State, h: Buffer_Handle),
	shader_destroy: proc(s: ^Renderer_D3D12_State, h: Shader_Handle),
	destroy_swapchain: proc(s: ^Renderer_D3D12_State, swap: Swapchain_Handle),
	destroy_pipeline: proc(rs: ^Renderer_D3D12_State, ph: Pipeline_Handle),
	destroy: proc(s: ^Renderer_D3D12_State),

	swapchain_size: proc(s: ^Renderer_D3D12_State, swap: Swapchain_Handle) -> base.Vec2i,
}

@export
load_plugin :: proc() -> typeid {
	return Renderer_D3D12
}