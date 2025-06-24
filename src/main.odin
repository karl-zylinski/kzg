package kzg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import ren "plugins:renderer_d3d12"
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
rd3d: ^ren.Renderer_D3d12
rs: ^ren.State
pipeline: ren.Pipeline_Handle
swapchain: ren.Swapchain_Handle
custom_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger()
	plugins_load_all()
	rd3d = get_api(ren.Renderer_D3d12)

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

	rs = rd3d.create()

	shader_source := string(#load("shader.hlsl"))
	shader := rd3d.shader_create(rs, shader_source)
	pipeline := rd3d.create_pipeline(rs, shader)
	swapchain = rd3d.create_swapchain(rs, transmute(u64)(hwnd), DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT)
	ui := ui_create(rs, 2048, 2048)

	Constant_Buffer :: struct #align(256) {
		view_matrix: Mat4,
	}

	cbuf := rd3d.buffer_create(rs, 1, size_of(Constant_Buffer))
	cbuf_map := rd3d.buffer_map(rs, cbuf)
	
	msg: win.MSG

	for run {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)			
		}

		ui_reset(&ui)

		swap_size := rd3d.swapchain_size(rs, swapchain)
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

		rd3d.set_buffer(rs, pipeline, "constant_buffer", cbuf)
		rd3d.set_buffer(rs, pipeline, "ui_elements", ui.element_buffer)

		ui_draw_rectangle(&ui, rect, COLOR_PANEL_BACKGROUND)

		toolbar := cut_rect_top(&rect, 30, 0)

		ui_draw_rectangle(&ui, toolbar, COLOR_TOOLBAR)

		rd3d.begin_frame(rs, swapchain)
		cmdlist := rd3d.create_command_list(rs, pipeline, swapchain)
		rd3d.begin_render_pass(rs, cmdlist)
		ui_commit(&ui)
		rd3d.draw(rs, cmdlist, ui.index_buffer, len(ui.indices))
		rd3d.execute_command_list(rs, cmdlist)
		rd3d.destroy_command_list(cmdlist)
		rd3d.present(rs, swapchain)
	}

	log.info("Shutting down...")
	rd3d.flush(rs, swapchain)
	ui_destroy(rs, &ui)
	rd3d.buffer_destroy(rs, cbuf)
	rd3d.shader_destroy(rs, shader)
	rd3d.destroy_swapchain(rs, swapchain)
	rd3d.destroy_pipeline(rs, pipeline)
	rd3d.destroy(rs)
	log.info("Shutdown complete.")
}

window_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = custom_context
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		run = false
	case win.WM_SIZE:
		if rs != nil {
			width := int(win.LOWORD(lparam))
			height := int(win.HIWORD(lparam))
			rd3d.flush(rs, swapchain)
			rd3d.destroy_swapchain(rs, swapchain)
			swapchain = rd3d.create_swapchain(rs, transmute(u64)hwnd, width, height)
		}
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}