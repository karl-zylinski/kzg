package renderer_d3d12

import hm "kzg:base/handle_map"

Renderer_D3D12_State :: State

Shader_Handle :: distinct hm.Handle

Renderer_D3D12 :: struct {
	create: proc(allocator := context.allocator, loc := #caller_location) -> ^Renderer_D3D12_State,
	shader_create: proc(self: ^Renderer_D3D12_State, source: string) -> Shader_Handle
}
