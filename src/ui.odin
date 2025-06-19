package kzg

import ren "plugins:renderer_d3d12"
import "core:mem"
import "core:slice"
import "base:runtime"

UI_Element_Index :: bit_field u32 {
	idx:    int | 24,
	corner: int | 8,
}

UI :: struct {
	elements: [dynamic]UI_Element,
	indices: [dynamic]UI_Element_Index,
	dyn_allocator: runtime.Allocator,

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
	clear(&ui.elements)
	clear(&ui.indices)
}

ui_create :: proc(rs: ^ren.State, elements_max: int, indices_max: int) -> UI {
	element_buffer := rd3d.buffer_create(rs, elements_max, size_of(UI_Element))
	element_buffer_map := rd3d.buffer_map(rs, element_buffer)
	index_buffer := rd3d.buffer_create(rs, indices_max, size_of(u32))
	index_buffer_map := rd3d.buffer_map(rs, index_buffer)

	elements := make([dynamic]UI_Element, 0, elements_max)
	elements.allocator = runtime.panic_allocator()
	indices := make([dynamic]UI_Element_Index, 0, indices_max)
	indices.allocator = runtime.panic_allocator()

	return {
		elements = elements,
		indices = indices,
		dyn_allocator = context.allocator,
		element_buffer = element_buffer,
		element_buffer_map = element_buffer_map,
		index_buffer = index_buffer,
		index_buffer_map = index_buffer_map,
	}
}

ui_destroy :: proc(rs: ^ren.State, ui: ^UI) {
	rd3d.buffer_destroy(rs, ui.element_buffer)
	rd3d.buffer_destroy(rs, ui.index_buffer)
	ui.elements.allocator = ui.dyn_allocator
	delete(ui.elements)
	ui.indices.allocator = ui.dyn_allocator
	delete(ui.indices)
}

ui_draw_rectangle :: proc(ui: ^UI, rect: Rect, color: [4]f32) {
	idx := len(ui.elements)
	append(&ui.elements, UI_Element {
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

	encode_index :: proc(element_idx: int, corner: Rect_Corner) -> UI_Element_Index {
		return {
			idx = element_idx,
			corner = int(corner),
		}
	}

	append(&ui.indices,
		encode_index(idx, .Top_Left),
		encode_index(idx, .Top_Right),
		encode_index(idx, .Bottom_Right),
		encode_index(idx, .Top_Left),
		encode_index(idx, .Bottom_Right),
		encode_index(idx, .Bottom_Left),)
}

ui_commit :: proc(ui: ^UI) {
	elems := ui.elements[:]
	mem.copy(ui.element_buffer_map, raw_data(elems), slice.size(elems))

	indices := ui.indices[:]
	mem.copy(ui.index_buffer_map, raw_data(indices), slice.size(indices))
}
