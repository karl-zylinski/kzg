// This file is regenerated on each compile. Don't edit it and hope for your changes to stay.
package thingy

import "kzg:base"

API :: struct {
	hi: proc(),
}

@export
kzg_plugin_loaded :: proc(api_storage: ^base.API_Storage) {
	plugin_system_init(api_storage)

	a0 := API {
		hi = hi,
	}

	register_api(API, &a0)
}

Plugin :: base.Plugin
API_Storage :: base.API_Storage
plugin_system_init :: base.plugin_system_init
plugin_system_load :: base.plugin_system_load
plugin_system_load_all :: base.plugin_system_load_all
plugin_system_refresh :: base.plugin_system_refresh
register_api :: base.register_api
plugin_system_register_api :: base.plugin_system_register_api
get_api :: base.get_api
plugin_system_get_api :: base.plugin_system_get_api
Rect :: base.Rect
Mat4 :: base.Mat4
Vec3 :: base.Vec3
Vec2i :: base.Vec2i
Color :: base.Color
Handle :: base.Handle
Handle_Map :: base.Handle_Map
hm_clear :: base.hm_clear
hm_add :: base.hm_add
hm_get :: base.hm_get
hm_remove :: base.hm_remove
hm_valid :: base.hm_valid
hm_num_used :: base.hm_num_used
hm_cap :: base.hm_cap
Handle_Map_Iterator :: base.Handle_Map_Iterator
hm_make_iter :: base.hm_make_iter
hm_iter :: base.hm_iter
