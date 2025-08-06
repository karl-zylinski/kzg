package kzg_base

import "core:strings"
import "core:os/os2"
import "core:log"
import "core:path/filepath"
import "core:dynlib"
import "core:reflect"
import "core:mem"
import "base:runtime"
import "core:fmt"
import "core:time"

Plugin :: struct {
	lib: dynlib.Library,
	lib_modified_time: time.Time,
	lib_path: string,
	version: int,
}

API_Storage :: struct {
	plugins: [dynamic]Plugin,
	api_lookup: map[typeid]rawptr,
}

@private
api_storage: ^API_Storage

plugin_system_init :: proc(storage: ^API_Storage) {
	assert(api_storage == nil, "Already initialized")
	api_storage = storage
}

plugin_system_load :: proc(p: ^Plugin) -> bool {
	COPIED_PLUGINS_DIR :: "plugins/runtime_copies"
	os2.make_directory(COPIED_PLUGINS_DIR)
	copy_path := fmt.tprintf("%v/%v_%v.dll", COPIED_PLUGINS_DIR, filepath.stem(p.lib_path), p.version)
	p.version += 1
	file_copy_err := os2.copy_file(copy_path, p.lib_path)

	if file_copy_err == nil {
		lib, lib_ok := dynlib.load_library(copy_path, false, context.temp_allocator)

		if lib_ok  {
			PLUGIN_LOADED_TYPE :: proc(api_storage: ^API_Storage)
			PLUGIN_LOADED_PROC_NAME :: "kzg_plugin_loaded"
			plugin_loaded := (PLUGIN_LOADED_TYPE)(dynlib.symbol_address(lib, PLUGIN_LOADED_PROC_NAME))

			if plugin_loaded != nil {
				plugin_loaded(api_storage)
				p.lib = lib
				return true
			}
		}
	}

	return false
}

plugin_system_load_all :: proc() {
	assert(api_storage != nil)
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
				p := Plugin {
					lib_path = pff.fullpath,
				}

				mod_time, mod_time_err := os2.modification_time_by_path(p.lib_path)

				if mod_time_err == nil && plugin_system_load(&p) {
					p.lib_path = strings.clone(pff.fullpath)
					p.lib_modified_time = mod_time
					append(&api_storage.plugins, p)
				}
			}
		}
	}
}

plugin_system_refresh :: proc() {
	assert(api_storage != nil)

	for &p in api_storage.plugins {
		modified_time, modified_time_error := os2.modification_time_by_path(p.lib_path)

		if modified_time_error != nil {
			continue
		}

		if time.diff(p.lib_modified_time, modified_time) > 0 {
			plugin_system_load(&p)
			p.lib_modified_time = modified_time
		}
	}
}

register_api :: plugin_system_register_api

plugin_system_register_api :: proc(type: typeid, api: rawptr) {
	assert(api_storage != nil)
	existing := api_storage.api_lookup[type]

	if existing != nil {
		sz := reflect.size_of_typeid(type)
		mem.copy(existing, api, sz)
		return
	}
	
	sz := reflect.size_of_typeid(type)
	api_struct, api_struct_err := mem.alloc(sz)
	mem.copy(api_struct, api, sz)
	api_storage.api_lookup[type] = api_struct
}

get_api :: plugin_system_get_api

plugin_system_get_api :: proc($T: typeid) -> ^T {
	assert(api_storage != nil)
	return (^T)(api_storage.api_lookup[T])
}