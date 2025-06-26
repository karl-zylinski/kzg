package thingy

import hm "kzg:base/handle_map"
import "kzg:base"

API :: struct {
	hi: proc(),
}

@export
kzg_plugin_loaded :: proc(register_api: proc(T: typeid, api: rawptr)) {
	a0 := API {
		hi = hi,
	}

	register_api(API, &a0)
}