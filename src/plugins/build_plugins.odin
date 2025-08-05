package kzg_build_plugins

import os "core:os/os2"
import os1 "core:os"
import vmem "core:mem/virtual"
import "core:log"
import "core:fmt"
import "core:odin/parser"
import "core:odin/ast"
import "core:strings"
import "core:slice"

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

		os.make_directory("../../plugins")
		out_dir := fmt.tprintf("../../plugins/%v", fi.name)
		os.make_directory(out_dir)

		plug_ast, plug_ast_ok := parser.parse_package_from_path(fi.name)

		log.ensuref(plug_ast_ok, "Could not generate AST for package %v", fi.name)

		a, a_err := os1.open(fmt.tprintf("%v/api.odin", out_dir), os1.O_WRONLY | os1.O_CREATE | os1.O_TRUNC, 0o644) 

		check(a_err == nil, a_err)

		base_api_file := fmt.tprintf("%v/api_types.odin", fi.name)
		api_file, api_file_ok := os1.read_entire_file(base_api_file)

		if api_file_ok {
			fmt.fprint(a, string(api_file))
		} else {
			fmt.fprintfln(a, "package %v", plug_ast.name)			
		}

		API_Entry :: struct {
			name: string,
			type: string,
		}
		
		API :: struct {
			entries: [dynamic]API_Entry,
		}

		opaque_types: [dynamic]string

		apis: map[string]API

		default_api_name := "API"//strings.to_ada_case(plug_ast.name)

		for _, &f in plug_ast.files {
			for &d in f.decls {
				#partial switch &dd in d.derived {
				case ^ast.Value_Decl:
					add_to_api: bool
					add_to_api_opaque: bool
					add_to_api_name: string

					for &a in dd.attributes {
						for &e in a.elems {
							name: string
							value: string

							#partial switch &ed in e.derived {
							case ^ast.Field_Value:
								if name_ident, name_ident_ok := ed.field.derived.(^ast.Ident); name_ident_ok {
									name = name_ident.name
								}

								if value_lit, value_lit_ok := ed.value.derived.(^ast.Basic_Lit); value_lit_ok {
									value = strings.trim(value_lit.tok.text, "\"")
								}
							case ^ast.Ident:
								name = ed.name
							}

							switch name {
							case "api":
								add_to_api = true
								add_to_api_name = value
							case "opaque":
								add_to_api = true
								add_to_api_opaque = true
							}
						}
					}

					if add_to_api {
						name: string

						for n in dd.names {
							#partial switch nd in n.derived {
							case ^ast.Ident:
								name = nd.name
							}
						}

						if name == "" {
							continue
						}

						if add_to_api_opaque {
							append(&opaque_types, name)
						} else {
							for v in dd.values {
								#partial switch vd in v.derived {
								case ^ast.Proc_Lit:
									type := f.src[vd.type.pos.offset:vd.type.end.offset]

									api_name := add_to_api_name

									if api_name == "" {
										api_name = default_api_name
									}

									api := &apis[api_name]

									if api == nil {
										apis[api_name] = API {}
										api = &apis[api_name]
									}

									append(&api.entries, API_Entry { name = name, type = type })
								}
							}
						}
					}
				}
			}
		}

		pf :: fmt.fprintf
		pfln :: fmt.fprintfln

		for t in opaque_types {
			pf(a, t)
			pfln(a, " :: struct {{}}")
		}

		loader_filename := fmt.tprintf("%v/api_loader.odin", fi.name)
		lo, loader_out_err := os1.open(loader_filename, os1.O_WRONLY | os1.O_CREATE | os1.O_TRUNC, 0o644)

		check(loader_out_err == nil, loader_out_err)

		pfln(lo, "package %v", plug_ast.name)

		pfln(lo, "")

		pfln(lo, "import hm \"kzg:base/handle_map\"")
		pfln(lo, "import \"kzg:base\"")
		
		pfln(a, "")

		if len(apis) > 0 {
			apis_sorted, _ := slice.map_entries(apis)

			slice.sort_by(apis_sorted, proc(i, j: slice.Map_Entry(string, API)) -> bool {
				return i.key < j.key
			})

			// api builder
			ab := strings.builder_make()

			for api in apis_sorted {
				strings.write_string(&ab, api.key)
				strings.write_string(&ab, " :: struct {{\n")

				for e in api.value.entries {
					strings.write_rune(&ab, '\t')
					strings.write_string(&ab, e.name)
					strings.write_string(&ab, ": ")
					strings.write_string(&ab, e.type)
					strings.write_string(&ab, ",\n")
				}

				strings.write_string(&ab, "}")
			}

			apis := strings.to_string(ab)
			pfln(a, apis)

			pfln(a, "")

			pfln(lo, "")

			pfln(lo, apis)

			pfln(lo, "")

			pfln(lo, "@export\nkzg_plugin_loaded :: proc(api_storage: ^base.API_Storage) {{")
			pfln(lo, "\tbase.api_storage = api_storage\n")
				
			for api, idx in apis_sorted {
				pfln(lo, "\ta%v := %v {{", idx, api.key)

				for e in api.value.entries {
					pfln(lo, "\t\t%v = %v,", e.name, e.name)
				}

				pfln(lo, "\t}}\n")

				pfln(lo, "\tbase.register_api(%v, &a%v)", api.key, idx)
			}

			pf(lo, "}}")
		}
		
		os1.close(a)
		os1.close(lo)
	}

	for fi in file_infos {
		if fi.type != .Directory {
			continue
		}

		ex_state, _, err_out, err := os.process_exec({
			command = {
				"odin",
				"build",
				fi.name,
				"-custom-attribute=opaque",
				"-custom-attribute=api",
				"-build-mode:dll",
				"-collection:kzg=..",
				"-collection:plugins=../../plugins",
				"-debug",
				fmt.tprintf("-out:../../plugins/%v/%v.dll", fi.name, fi.name),
			},
		}, context.allocator)

		check(err == nil, err)
		if ex_state.exit_code != 0 {
			fmt.eprint(string(err_out))
			panic("Plugin compilation failed")
		}
	}
}

check :: proc(cond: bool, err: any) {
	log.ensuref(cond, "Error: %v", err)
}