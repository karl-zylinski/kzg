package renderer_d3d12

import hm "kzg:base/handle_map"
import "kzg:base"

API :: struct {
	create: proc(allocator := context.allocator, loc := #caller_location) -> ^State,
	destroy: proc(s: ^State),
	create_swapchain: proc(s: ^State, hwnd: u64, width: int, height: int) -> Swapchain_Handle,
	destroy_swapchain: proc(s: ^State, sh: Swapchain_Handle),
	create_pipeline: proc(s: ^State, shader_handle: Shader_Handle) -> Pipeline_Handle,
	destroy_pipeline: proc(rs: ^State, ph: Pipeline_Handle),
	flush: proc(s: ^State, sh: Swapchain_Handle),
	begin_frame: proc(s: ^State, sh: Swapchain_Handle),
	draw: proc(s: ^State, cmd: ^Command_List, index_buffer: Buffer_Handle, n: int),
	create_command_list: proc(s: ^State, ph: Pipeline_Handle, sh: Swapchain_Handle) -> ^Command_List,
	destroy_command_list: proc(rs: ^State, cmd: ^Command_List),
	set_buffer: proc(rs: ^State, ph: Pipeline_Handle, name: string, h: Buffer_Handle),
	begin_render_pass: proc(s: ^State, cmd: ^Command_List),
	execute_command_list: proc(s: ^State, cmd: ^Command_List),
	present: proc(s: ^State, sh: Swapchain_Handle),
	shader_create: proc(s: ^State, shader_source: string) -> Shader_Handle,
	shader_destroy: proc(s: ^State, h: Shader_Handle),
	buffer_create: proc(s: ^State, num_elements: int, element_size: int) -> Buffer_Handle,
	buffer_destroy: proc(s: ^State, h: Buffer_Handle),
	buffer_map: proc(s: ^State, h: Buffer_Handle) -> rawptr,
	buffer_unmap: proc(s: ^State, h: Buffer_Handle),
	swapchain_size: proc(s: ^State, sh: Swapchain_Handle) -> base.Vec2i,
}

@export
kzg_plugin_loaded :: proc(register_api: proc(T: typeid, api: rawptr)) {
	a0 := API {
		create = create,
		destroy = destroy,
		create_swapchain = create_swapchain,
		destroy_swapchain = destroy_swapchain,
		create_pipeline = create_pipeline,
		destroy_pipeline = destroy_pipeline,
		flush = flush,
		begin_frame = begin_frame,
		draw = draw,
		create_command_list = create_command_list,
		destroy_command_list = destroy_command_list,
		set_buffer = set_buffer,
		begin_render_pass = begin_render_pass,
		execute_command_list = execute_command_list,
		present = present,
		shader_create = shader_create,
		shader_destroy = shader_destroy,
		buffer_create = buffer_create,
		buffer_destroy = buffer_destroy,
		buffer_map = buffer_map,
		buffer_unmap = buffer_unmap,
		swapchain_size = swapchain_size,
	}

	register_api(API, &a0)
}