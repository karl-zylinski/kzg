package kzg

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

				proc_type :: proc(register: proc(type: typeid, api: rawptr)) -> typeid
				proc_register_apis: proc_type

				if lib_ok {
					proc_register_apis = (proc_type)(dynlib.symbol_address(lib, "kzg_register_apis", context.temp_allocator))
				}

				if proc_register_apis != nil {
					proc_register_apis(register_api)
					//plugin_api_type := proc_load_plugin()
					//load_plugin(lib, plugin_api_type)
				}
			}
		}
	}
}

/*load_plugin :: proc(lib: dynlib.Library, t: typeid) {
	api_struct, api_struct_err := mem.alloc(reflect.size_of_typeid(t))
	log.assertf(api_struct_err == nil, "Error loading plugin: %v", api_struct_err)

	for field in reflect.struct_fields_zipped(t) {
		if !(reflect.is_procedure(field.type) || reflect.is_pointer(field.type)) {
			continue
		}

		sym_ptr := dynlib.symbol_address(lib, field.name) or_continue
		field_ptr := rawptr(uintptr(api_struct) + field.offset)
		(^rawptr)(field_ptr)^ = sym_ptr
	}

	api := Plugin_API {
		api_struct = api_struct,
	}

	plugin_apis[t] = api
}*/

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