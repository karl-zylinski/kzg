package kzg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import rd3d "plugins:renderer_d3d12"
import "plugins:thingy"
import "kzg:base"
import win "core:sys/windows"
import sa "core:container/small_array"
import la "core:math/linalg"
import "core:dynlib"
import "plugins:ui"
import "core:slice"


Rect :: base.Rect
Color :: base.Color
Mat4 :: base.Mat4
Vec3 :: base.Vec3

run: bool
api_storage: base.API_Storage
rd3d_api: API_Instance(rd3d.API, rd3d.State)
rd3d_state: ^rd3d.State
pipeline: rd3d.Pipeline_Handle
swapchain: rd3d.Swapchain_Handle
custom_context: runtime.Context

API_Instance :: struct($API_Type: typeid, $State_Type: typeid) {
	using state: ^State_Type,
	using api: ^API_Type,
}

create_api_instance :: proc($Api_Type: typeid, $State_Type: typeid, allocator := context.allocator, loc := #caller_location) -> API_Instance(Api_Type, State_Type) {
	api := base.get_api(Api_Type)
	state := api.create(allocator, loc)

	return API_Instance(Api_Type, State_Type) {
		state = state,
		api = api,		
	}
}

main :: proc() {
	context.logger = log.create_console_logger()
	base.plugin_system_init(&api_storage)
	base.plugin_system_load_all()
	test_api := base.get_api(thingy.API)
	test_api.hi()
	ui_api := base.get_api(ui.API)

	when ODIN_DEBUG {
		default_allocator := context.allocator
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		defer {
			for _, value in tracking_allocator.allocation_map {
				fmt.printf("%v: Leaked %v bytes\n", value.location, value.size)
			}
		}
	}

	run = true
	custom_context = context
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "win: Failed fetching current instance")
	CLASS_NAME :: "KZG"
	hr: win.HRESULT

	cls := win.WNDCLASSW {
		lpfnWndProc = window_proc,
		lpszClassName = CLASS_NAME,
		hInstance = instance,
		hCursor = win.LoadCursorA(nil, win.IDC_ARROW)
	}

	class := win.RegisterClassW(&cls)
	assert(class != 0, "win: Failed creating window class")

	DEFAULT_WINDOW_WIDTH :: 1280
	DEFAULT_WINDOW_HEIGHT :: 720

	hwnd := win.CreateWindowW(CLASS_NAME,
		win.L("KZG"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		100, 100, DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT,
		nil, nil, instance, nil)

	assert(hwnd != nil, "win: Window creation failed")

	rd3d_api = create_api_instance(rd3d.API, rd3d.State)
	rd3d_state = rd3d_api.state

	shader_source := string(#load("shader.hlsl"))
	shader := rd3d_api->shader_create(shader_source)
	pipeline := rd3d_api->create_pipeline(shader)
	swapchain = rd3d_api->create_swapchain(transmute(u64)(hwnd), DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT)
	ui_state := ui_api.create(2048, 2048)

	ui_element_buffer := rd3d_api->buffer_create(2048, size_of(ui.UI_Element))
	ui_element_buffer_map := slice.reinterpret([]ui.UI_Element, rd3d_api->buffer_map(ui_element_buffer))
	ui_index_buffer := rd3d_api->buffer_create(2048, size_of(ui.UI_Element_Index))
	ui_index_buffer_map := slice.reinterpret([]ui.UI_Element_Index, rd3d_api->buffer_map(ui_index_buffer))

	Constant_Buffer :: struct #align(256) {
		view_matrix: Mat4,
	}

	cbuf := rd3d_api->buffer_create(1, size_of(Constant_Buffer))
	cbuf_map := (^Constant_Buffer)(raw_data(rd3d_api->buffer_map(cbuf)))
	
	msg: win.MSG

	for run {
		base.plugin_system_refresh()
		
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)			
		}

		ui_api.reset(ui_state)

		swap_size := rd3d_api->swapchain_size(swapchain)
		sw := f32(swap_size.x)
		sh := f32(swap_size.y)

		rect := Rect {
			0, 0,
			sw, sh,
		}

		view_matrix := la.matrix4_scale(Vec3{2.0/sw, -2.0/sh, 1}) * la.matrix4_translate(Vec3{-sw/2, -sh/2, 0})

		cbuf_map^ = {
			view_matrix = Mat4(view_matrix),
		}

		rd3d_api->set_buffer(pipeline, "constant_buffer", cbuf)
		rd3d_api->set_buffer(pipeline, "ui_elements", ui_element_buffer)

		ui_api.draw_rectangle(ui_state, rect, COLOR_PANEL_BACKGROUND)

		toolbar := cut_rect_top(&rect, 30, 0)

		ui_api.draw_rectangle(ui_state, toolbar, COLOR_TOOLBAR)

		rd3d_api->begin_frame(swapchain)
		cmdlist := rd3d_api->create_command_list(pipeline, swapchain)
		rd3d_api->begin_render_pass(cmdlist)

		copy_slice(ui_element_buffer_map, ui_api.get_elements(ui_state))
		indices := ui_api.get_element_indices(ui_state)
		copy_slice(ui_index_buffer_map, indices)

		rd3d_api->draw(cmdlist, ui_index_buffer, len(indices))
		rd3d_api->execute_command_list(cmdlist)
		rd3d_api->destroy_command_list(cmdlist)
		rd3d_api->present(swapchain)
	}

	log.info("Shutting down...")
	rd3d_api->flush(swapchain)
	ui_api.destroy(ui_state)
	rd3d_api->buffer_destroy(ui_element_buffer)
	rd3d_api->buffer_destroy(ui_index_buffer)
	rd3d_api->buffer_destroy(cbuf)
	rd3d_api->shader_destroy(shader)
	rd3d_api->destroy_swapchain(swapchain)
	rd3d_api->destroy_pipeline(pipeline)
	rd3d_api->destroy()
	log.info("Shutdown complete.")
}

window_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = custom_context
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		run = false
	case win.WM_SIZE:
		if rd3d_state != nil {
			width := int(win.LOWORD(lparam))
			height := int(win.HIWORD(lparam))
			rd3d_api->flush(swapchain)
			rd3d_api->destroy_swapchain(swapchain)
			swapchain = rd3d_api->create_swapchain(transmute(u64)hwnd, width, height)
		}
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}