package kzg_ui

import rd3d "plugins:renderer_d3d12"
import "core:mem"
import "core:slice"
import "base:runtime"

@api
UI_Element_Index :: bit_field u32 {
	idx:    int | 24,
	corner: int | 8,
}

@api_opaque
UI :: struct {
	elements: [dynamic]UI_Element,
	indices: [dynamic]UI_Element_Index,
	allocator: runtime.Allocator,
}

@api
UI_Element :: struct {
	pos: [2]f32,
	size: [2]f32,
	color: [4]f32,
}

@api
reset :: proc(ui: ^UI) {
	clear(&ui.elements)
	clear(&ui.indices)
}

@api
create :: proc(elements_max: int, indices_max: int, allocator := context.allocator, loc := #caller_location) -> ^UI {
	elements := make([dynamic]UI_Element, 0, elements_max, allocator, loc)
	elements.allocator = runtime.panic_allocator()
	indices := make([dynamic]UI_Element_Index, 0, indices_max, allocator, loc)
	indices.allocator = runtime.panic_allocator()

	ui := new(UI, allocator, loc)

	ui^ = {
		elements = elements,
		indices = indices,
		allocator = allocator,
	}

	return ui
}

@api
destroy :: proc(ui: ^UI) {
	ui.elements.allocator = ui.allocator
	delete(ui.elements)
	ui.indices.allocator = ui.allocator
	delete(ui.indices)
	a := ui.allocator
	free(ui, a)
}

@api
get_elements :: proc(ui: ^UI) -> []UI_Element {
	return ui.elements[:]
}

@api
get_element_indices :: proc(ui: ^UI) -> []UI_Element_Index {
	return ui.indices[:]
}

@api
draw_rectangle :: proc(ui: ^UI, rect: Rect, color: Color) {
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
