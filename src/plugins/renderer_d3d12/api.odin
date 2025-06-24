package renderer_d3d12

import hm "kzg:base/handle_map"
import "kzg:base"

KZG_PLUGIN :: #config(KZG_PLUGIN, false)

when !KZG_PLUGIN {
	State :: struct {}	
	Command_List :: struct {}
}

Shader_Handle :: distinct hm.Handle
Buffer_Handle :: distinct hm.Handle
Swapchain_Handle :: distinct hm.Handle
Pipeline_Handle :: distinct hm.Handle

Renderer_D3D12 :: struct {
	create: proc(allocator := context.allocator, loc := #caller_location) -> ^State,
	shader_create: proc(self: ^State, source: string) -> Shader_Handle,
	create_pipeline: proc(self: ^State, shader_handle: Shader_Handle) -> Pipeline_Handle,
	create_swapchain: proc(s: ^State, hwnd: u64, width: int, height: int) -> Swapchain_Handle,
	buffer_create: proc(s: ^State, num_elements: int, element_size: int) -> Buffer_Handle,
	buffer_map: proc(s: ^State, h: Buffer_Handle) -> rawptr,
	set_buffer: proc(rs: ^State, ph: Pipeline_Handle, name: string, h: Buffer_Handle),
	begin_frame: proc(s: ^State, swap: Swapchain_Handle),
	create_command_list: proc(s: ^State, ph: Pipeline_Handle, swap: Swapchain_Handle) -> ^Command_List,
	begin_render_pass: proc(s: ^State, cmd: ^Command_List),
	draw: proc(s: ^State, cmd: ^Command_List, index_buffer: Buffer_Handle, n: int),
	execute_command_list: proc(s: ^State, cmd: ^Command_List),
	destroy_command_list: proc(cmd: ^Command_List),
	present: proc(s: ^State, swap: Swapchain_Handle),
	flush: proc(s: ^State, swap: Swapchain_Handle),
	buffer_destroy: proc(s: ^State, h: Buffer_Handle),
	shader_destroy: proc(s: ^State, h: Shader_Handle),
	destroy_swapchain: proc(s: ^State, swap: Swapchain_Handle),
	destroy_pipeline: proc(rs: ^State, ph: Pipeline_Handle),
	destroy: proc(s: ^State),

	swapchain_size: proc(s: ^State, swap: Swapchain_Handle) -> base.Vec2i,
}
