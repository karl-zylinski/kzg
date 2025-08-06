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

