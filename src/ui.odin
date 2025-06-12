package kzg

import sa "core:container/small_array"
import ren "renderer_d3d12"
import "core:mem"
import "core:slice"

UI :: struct {
	elements: sa.Small_Array(2048, UI_Element),
	indices: sa.Small_Array(2048, u32),

	elements_buffer: ren.Buffer_Handle,
	elements_map: rawptr,

	vertex_buffer: ren.Buffer_Handle,
	//vertex_buffer_view: d3d12.VERTEX_BUFFER_VIEW,

	index_buffer: ren.Buffer_Handle,
	//index_buffer_view: d3d12.INDEX_BUFFER_VIEW,
	index_buffer_map: rawptr,
}

UI_Element :: struct {
	pos: [2]f32,
	size: [2]f32,
	color: [4]f32,
}

ui_reset :: proc(ui: ^UI) {
	sa.clear(&ui.elements)
	sa.clear(&ui.indices)
}

ui_create :: proc(rs: ^ren.State, elements_max: int, indices_max: int) -> UI {
	ui: UI

	{
		ui.elements_buffer = ren.buffer_create(rs, elements_max, size_of(UI_Element))
		ui.elements_map = ren.buffer_map(rs, ui.elements_buffer)
	}

	{
		vertices := [?]f32 {
			// pos            color
			0.0, 0, 0.0,  1,0,0,0,
			200, 0, 0.0,  0,1,0,0,
			200, 200, 0.0,  0,0,1,0,
			0, 200, 0.0,  0, 0,1,0,
		}

		ui.vertex_buffer = ren.buffer_create(rs, len(vertices), size_of(f32))

		gpu_data := ren.buffer_map(rs, ui.vertex_buffer)
		mem.copy(gpu_data, &vertices[0], slice.size(vertices[:]))
		ren.buffer_unmap(rs, ui.vertex_buffer)
	}

	{
		ui.index_buffer = ren.buffer_create(rs, indices_max, size_of(u32))
		ui.index_buffer_map = ren.buffer_map(rs, ui.index_buffer)
	}

	return ui
}


ui_draw_rectangle :: proc(ui: ^UI, pos: [2]f32, size: [2]f32, color: [4]f32) {
	idx := sa.len(ui.elements)
	sa.append_elem(&ui.elements, UI_Element {
		pos = pos,
		size = size,
		color = color
	})

	Rect_Corner :: enum {
		Top_Left,
		Top_Right,
		Bottom_Right,
		Bottom_Left,
	}

	encode_index :: proc(element_idx: int, corner: Rect_Corner) -> u32 {
		res: u32
		res = u32(corner) << 24
		res |= u32(element_idx)
		return res
	}

	sa.append_elems(&ui.indices,
		encode_index(idx, .Top_Left),
		encode_index(idx, .Top_Right),
		encode_index(idx, .Bottom_Right),
		encode_index(idx, .Top_Left),
		encode_index(idx, .Bottom_Right),
		encode_index(idx, .Bottom_Left),)
}

ui_commit :: proc(ui: ^UI) {
	elems := sa.slice(&ui.elements)
	mem.copy(ui.elements_map, raw_data(elems), slice.size(elems))

	indices := sa.slice(&ui.indices)
	mem.copy(ui.index_buffer_map, raw_data(indices), slice.size(indices))
}
