package kzg

import sa "core:container/small_array"
import ren "renderer_d3d12"
import "core:mem"
import "core:slice"

UI :: struct {
	elements: sa.Small_Array(2048, UI_Element),
	indices: sa.Small_Array(2048, u32),

	element_buffer: ren.Buffer_Handle,
	element_buffer_map: rawptr,

	index_buffer: ren.Buffer_Handle,
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
	element_buffer := ren.buffer_create(rs, elements_max, size_of(UI_Element))
	element_buffer_map := ren.buffer_map(rs, element_buffer)
	index_buffer := ren.buffer_create(rs, indices_max, size_of(u32))
	index_buffer_map := ren.buffer_map(rs, index_buffer)

	return {
		element_buffer = element_buffer,
		element_buffer_map = element_buffer_map,
		index_buffer = index_buffer,
		index_buffer_map = index_buffer_map,
	}
}

ui_destroy :: proc(rs: ^ren.State, ui: ^UI) {
	ren.buffer_destroy(rs, ui.element_buffer)
	ren.buffer_destroy(rs, ui.index_buffer)
}

ui_draw_rectangle :: proc(ui: ^UI, rect: Rect, color: [4]f32) {
	idx := sa.len(ui.elements)
	sa.append_elem(&ui.elements, UI_Element {
		pos = {rect.x, rect.y},
		size = {rect.w, rect.h},
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
	mem.copy(ui.element_buffer_map, raw_data(elems), slice.size(elems))

	indices := sa.slice(&ui.indices)
	mem.copy(ui.index_buffer_map, raw_data(indices), slice.size(indices))
}
