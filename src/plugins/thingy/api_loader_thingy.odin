// This file is regenerated on each compile. Don't edit it and hope for your changes to stay.
package thingy

import "kzg:base"
import hm "kzg:base/handle_map"

API :: struct {
	hi: proc(),
}

@export
kzg_plugin_loaded :: proc(api_storage: ^base.API_Storage) {
	base.api_storage = api_storage

	a0 := API {
		hi = hi,
	}

	base.register_api(API, &a0)
}

Plugin :: base.Plugin
API_Storage :: base.API_Storage
load_plugin :: base.load_plugin
load_all_plugins :: base.load_all_plugins
refresh_all_plugins :: base.refresh_all_plugins
register_api :: base.register_api
get_api :: base.get_api
Rect :: base.Rect
Mat4 :: base.Mat4
Vec3 :: base.Vec3
Vec2i :: base.Vec2i
Color :: base.Color
