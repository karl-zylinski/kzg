package kzg_build_plugins

import os "core:os/os2"
import vmem "core:mem/virtual"
import "core:log"
import "core:fmt"

main :: proc() {
	arena: vmem.Arena
	context.allocator = vmem.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	context.logger = log.create_console_logger()
	
	file_infos, read_dir_error := os.read_all_directory_by_path(".", context.allocator)
	check(read_dir_error == nil, read_dir_error)

	for fi in file_infos {
		if fi.type != .Directory {
			continue
		}

		out_dir := fmt.tprintf("%v/bin", fi.name)
		os.make_directory(out_dir)

		ex_state, _, err_out, err := os.process_exec({
			command = {
				"odin",
				"build",
				fi.name,
				"-define:KZG_PLUGIN=true",
				"-custom-attribute=api_name",
				"-build-mode:dll",
				"-collection:kzg=..",
				"-debug",
				fmt.tprintf("-out:%v/%v.dll", out_dir, fi.name),
			},
		}, context.allocator)

		check(err == nil, err)
		log.ensure(ex_state.exit_code == 0, string(err_out))
	}
}

check :: proc(cond: bool, err: any) {
	log.ensuref(cond, "Error: %v", err)
}