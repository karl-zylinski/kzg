package kzg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import rd3d "plugins:renderer_d3d12"
import th "plugins:thingy"
import "kzg:base"
import win "core:sys/windows"
import sa "core:container/small_array"
import la "core:math/linalg"
import "core:dynlib"

Rect :: base.Rect
Color :: base.Color
Mat4 :: base.Mat4
Vec3 :: base.Vec3

run: bool
rd3d_api: ^rd3d.API
rd3d_state: ^rd3d.State
pipeline: rd3d.Pipeline_Handle
swapchain: rd3d.Swapchain_Handle
custom_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger()
	base.plugins_load_all()
	rd3d_api = base.get_api(rd3d.API)
	t := base.get_api(th.API)

	t.hi()

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
	class_name := win.L("KZG")
	hr: win.HRESULT

	cls := win.WNDCLASSW {
		lpfnWndProc = window_proc,
		lpszClassName = class_name,
		hInstance = instance,
		hCursor = win.LoadCursorA(nil, win.IDC_ARROW)
	}

	class := win.RegisterClassW(&cls)
	assert(class != 0, "win: Failed creating window class")

	DEFAULT_WINDOW_WIDTH :: 1280
	DEFAULT_WINDOW_HEIGHT :: 720

	hwnd := win.CreateWindowW(class_name,
		win.L("KZG"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		100, 100, DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT,
		nil, nil, instance, nil)

	assert(hwnd != nil, "win: Window creation failed")

	rd3d_state = rd3d_api.create()

	shader_source := string(#load("shader.hlsl"))
	shader := rd3d_api.shader_create(rd3d_state, shader_source)
	pipeline := rd3d_api.create_pipeline(rd3d_state, shader)
	swapchain = rd3d_api.create_swapchain(rd3d_state, transmute(u64)(hwnd), DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT)
	ui := ui_create(rd3d_state, 2048, 2048)

	Constant_Buffer :: struct #align(256) {
		view_matrix: Mat4,
	}

	cbuf := rd3d_api.buffer_create(rd3d_state, 1, size_of(Constant_Buffer))
	cbuf_map := rd3d_api.buffer_map(rd3d_state, cbuf)
	
	msg: win.MSG

	for run {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)			
		}

		ui_reset(&ui)

		swap_size := rd3d_api.swapchain_size(rd3d_state, swapchain)
		sw := f32(swap_size.x)
		sh := f32(swap_size.y)

		rect := Rect {
			0, 0,
			sw, sh,
		}

		view_matrix := la.matrix4_scale(Vec3{2.0/sw, -2.0/sh, 1}) * la.matrix4_translate(Vec3{-sw/2, -sh/2, 0})

		cb := Constant_Buffer {
			view_matrix = Mat4(view_matrix),
		}

		mem.copy(cbuf_map, &cb, size_of(cb))

		rd3d_api.set_buffer(rd3d_state, pipeline, "constant_buffer", cbuf)
		rd3d_api.set_buffer(rd3d_state, pipeline, "ui_elements", ui.element_buffer)

		ui_draw_rectangle(&ui, rect, COLOR_PANEL_BACKGROUND)

		toolbar := cut_rect_top(&rect, 30, 0)

		ui_draw_rectangle(&ui, toolbar, COLOR_TOOLBAR)

		rd3d_api.begin_frame(rd3d_state, swapchain)
		cmdlist := rd3d_api.create_command_list(rd3d_state, pipeline, swapchain)
		rd3d_api.begin_render_pass(rd3d_state, cmdlist)
		ui_commit(&ui)
		rd3d_api.draw(rd3d_state, cmdlist, ui.index_buffer, len(ui.indices))
		rd3d_api.execute_command_list(rd3d_state, cmdlist)
		rd3d_api.destroy_command_list(cmdlist)
		rd3d_api.present(rd3d_state, swapchain)
	}

	log.info("Shutting down...")
	rd3d_api.flush(rd3d_state, swapchain)
	ui_destroy(rd3d_state, &ui)
	rd3d_api.buffer_destroy(rd3d_state, cbuf)
	rd3d_api.shader_destroy(rd3d_state, shader)
	rd3d_api.destroy_swapchain(rd3d_state, swapchain)
	rd3d_api.destroy_pipeline(rd3d_state, pipeline)
	rd3d_api.destroy(rd3d_state)
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
			rd3d_api.flush(rd3d_state, swapchain)
			rd3d_api.destroy_swapchain(rd3d_state, swapchain)
			swapchain = rd3d_api.create_swapchain(rd3d_state, transmute(u64)hwnd, width, height)
		}
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}