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

renderer: ren.Renderer
pipeline: ren.Pipeline
swapchain: ren.Swapchain
test_mesh: ren.Mesh
custom_context: runtime.Context

main :: proc() {
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

	renderer = ren.create()

	shader :=
`struct PSInput {
	float4 position : SV_POSITION;
	float4 color : COLOR;
};
PSInput VSMain(float4 position : POSITION0, float4 color : COLOR0) {
	PSInput result;
	result.position = position;
	result.color = color;
	return result;
}
float4 PSMain(PSInput input) : SV_TARGET {
	return input.color;
};`

	pipeline = ren.create_pipeline(&renderer, shader)
	swapchain = ren.create_swapchain(&renderer, hwnd, WINDOW_WIDTH, WINDOW_HEIGHT)
	test_mesh = ren.create_triangle_mesh(&renderer)
	
	msg: win.MSG

	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}

	log.info("Shutting down...")
	ren.destroy_mesh(test_mesh)
	ren.destroy_swapchain(&swapchain)
	ren.destroy_pipeline(&pipeline)
	ren.destroy(&renderer)
	log.info("Shutdown complete.")
}

window_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = custom_context
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
	case win.WM_PAINT:
		ren.begin_frame(&renderer, &swapchain)
		cmdlist := ren.create_command_list(&pipeline, &swapchain)
		ren.begin_render_pass(&cmdlist)
		ren.render_mesh(&cmdlist, &test_mesh)
		ren.execute_command_list(&renderer, &cmdlist)
		ren.present(&renderer, &swapchain)
	case win.WM_SIZE:
		if ren.valid(renderer) {
			width := int(win.LOWORD(lparam))
			height := int(win.HIWORD(lparam))
			ren.destroy_swapchain(&swapchain)
			swapchain = ren.create_swapchain(&renderer, hwnd, width, height)
		}
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}