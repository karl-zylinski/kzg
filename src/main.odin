package kzg

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import ren "renderer_d3d12"
import win "core:sys/windows"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

win32_hr_assert :: proc(res: win.HRESULT, message: string) {
	fmt.assertf(res >= 0, "%v. Error code: %0x\n", message, u32(res))
}

run: bool
rs: ren.State
pipeline: ren.Pipeline
swapchain: ren.Swapchain
custom_context: runtime.Context

main :: proc() {
	run = true
	context.logger = log.create_console_logger()
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

	hwnd := win.CreateWindowW(class_name,
		win.L("KZG"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		100, 100, WINDOW_WIDTH, WINDOW_HEIGHT,
		nil, nil, instance, nil)

	assert(hwnd != nil, "win: Window creation failed")

	rs = ren.create()

	shader := string(#load("shader.hlsl"))

	pipeline = ren.create_pipeline(&rs, shader)
	swapchain = ren.create_swapchain(&rs, hwnd, WINDOW_WIDTH, WINDOW_HEIGHT)
	ui := ren.create_ui(&pipeline)
	
	msg: win.MSG

	for run {
		for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)			
		}

		ren.ui_reset(&ui)

		ren.draw_rectangle(&ui, {10, 10}, {200, 100}, {0.3, 0.5, 0.3, 1})
		ren.draw_rectangle(&ui, {10, 300}, {400, 200}, {1, 0.5, 0.3, 1})

		ren.begin_frame(&rs, &swapchain)
		cmdlist := ren.create_command_list(&pipeline, &swapchain)
		ren.begin_render_pass(&cmdlist)
		ren.draw_ui(&ui, &cmdlist)
		ren.execute_command_list(&rs, &cmdlist)
		ren.present(&rs, &swapchain)
	}

	ren.flush(&rs, &swapchain)
	log.info("Shutting down...")
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