package kzg_base

import "core:os/os2"
import "core:log"
import "core:path/filepath"
import "core:dynlib"
import "core:reflect"
import "core:mem"

plugins_load_all :: proc() {
	plugin_folders, plugin_folders_err := os2.read_all_directory_by_path("plugins", context.temp_allocator)

	if plugin_folders_err != nil {
		return
	}

	for pf in plugin_folders {
		pf_files := os2.read_all_directory_by_path(pf.fullpath, context.temp_allocator) or_continue

		for pff in pf_files {
			if pff.type == .Regular &&
			filepath.ext(pff.name) == ".dll" &&
			filepath.stem(pff.name) == pf.name {
				lib, lib_ok := dynlib.load_library(pff.fullpath, false, context.temp_allocator)

				plugin_loaded_proc :: proc(register: proc(type: typeid, api: rawptr))

				if lib_ok {
					plugin_loaded := (plugin_loaded_proc)(dynlib.symbol_address(lib, "kzg_plugin_loaded"))

					if plugin_loaded != nil {
						plugin_loaded(register_api)
					}
				}
			}
		}
	}
}

register_api :: proc(type: typeid, api: rawptr) {
	sz := reflect.size_of_typeid(type)
	api_struct, api_struct_err := mem.alloc(sz)
	mem.copy(api_struct, api, sz)
	plugin_apis[type] = api_struct
}

Plugin_API :: struct {
	api_struct: rawptr,
}

plugin_apis: map[typeid]rawptr

get_api :: proc($T: typeid) -> ^T {
	return (^T)(plugin_apis[T])
}