package kzg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import ren "renderer_d3d12"
import win "core:sys/windows"
import sa "core:container/small_array"
import la "core:math/linalg"

Rect :: struct {
	x, y: f32,
	w, h: f32,
}

Mat4 :: #row_major matrix[4,4]f32
Vec3 :: [3]f32


// [4]u8 or [4]f32 ?
Color :: [4]f32

run: bool
rs: ren.State
pipeline: ren.Pipeline
swapchain: ren.Swapchain
custom_context: runtime.Context

main :: proc() {
	context.logger = log.create_console_logger()

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

	rs = ren.create()

	shader_source := string(#load("shader.hlsl"))
	shader := ren.shader_create(&rs, shader_source)
	pipeline = ren.create_pipeline(&rs, shader)
	swapchain = ren.create_swapchain(&rs, hwnd, DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT)
	ui := ui_create(&rs, 2048, 2048)

	Constant_Buffer :: struct #align(256) {
		view_matrix: Mat4,
	}

	cbuf := ren.buffer_create(&rs, 1, size_of(Constant_Buffer))
	cbuf_map := ren.buffer_map(&rs, cbuf)
	
	msg: win.MSG

	for run {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)			
		}

		ui_reset(&ui)

		sw := f32(swapchain.width)
		sh := f32(swapchain.height)

		rect := Rect {
			0, 0,
			sw, sh,
		}

		view_matrix := la.matrix4_scale(Vec3{2.0/sw, -2.0/sh, 1}) * la.matrix4_translate(Vec3{-sw/2, -sh/2, 0})

		cb := Constant_Buffer {
			view_matrix = Mat4(view_matrix),
		}

		mem.copy(cbuf_map, &cb, size_of(cb))

		ren.set_buffer(&pipeline, "ConstantBuffers", cbuf)
		ren.set_buffer(&pipeline, "ui_elements", ui.element_buffer)

		ui_draw_rectangle(&ui, rect, COLOR_PANEL_BACKGROUND)

		toolbar := cut_rect_top(&rect, 30, 0)

		ui_draw_rectangle(&ui, toolbar, COLOR_TOOLBAR)

		ren.begin_frame(&rs, &swapchain)
		cmdlist := ren.create_command_list(&pipeline, &swapchain)
		ren.begin_render_pass(&rs, &cmdlist)
		ui_commit(&ui)
		ren.draw(&rs, cmdlist, ui.index_buffer, sa.len(ui.indices))
		ren.execute_command_list(&rs, &cmdlist)
		ren.destroy_command_list(&cmdlist)
		ren.present(&rs, &swapchain)
	}

	log.info("Shutting down...")
	ren.flush(&rs, &swapchain)
	ui_destroy(&rs, &ui)
	ren.buffer_destroy(&rs, cbuf)
	ren.shader_destroy(&rs, shader)
	ren.destroy_swapchain(&swapchain)
	ren.destroy_pipeline(&pipeline)
	ren.destroy(&rs)
	log.info("Shutdown complete.")
}

window_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = custom_context
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		run = false
	case win.WM_SIZE:
		if ren.valid(rs) {
			width := int(win.LOWORD(lparam))
			height := int(win.HIWORD(lparam))
			ren.flush(&rs, &swapchain)
			ren.destroy_swapchain(&swapchain)
			swapchain = ren.create_swapchain(&rs, hwnd, width, height)
		}
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}