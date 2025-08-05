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

pln :: fmt.fprintln
pf :: fmt.fprintf
pfln :: fmt.fprintfln

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

		a, a_err := os1.open(fmt.tprintf("%v/api_%v.odin", out_dir, fi.name), os1.O_WRONLY | os1.O_CREATE | os1.O_TRUNC, 0o644) 

		check(a_err == nil, a_err)

		pfln(a, "package %v\n", plug_ast.name)
		pfln(a, "import \"kzg:base\"")
		pfln(a, "import hm \"kzg:base/handle_map\"")

		pfln(a, "")

		API_Entry :: struct {
			name: string,
			type: string,
		}
		
		API :: struct {
			entries: [dynamic]API_Entry,
		}

		types: [dynamic]string
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
							case "api_opaque":
								add_to_api = true
								add_to_api_opaque = true
							}
						}
					}

					if add_to_api {
						if add_to_api_opaque {
							for n in dd.names {
								name := f.src[n.pos.offset:n.end.offset]
								append(&types, fmt.tprintf("%v :: struct{{}}", name))
							}
						} else {
							// The API name is only used for procedures. It's the struct in which the procedure
							// pointers end up.
							api_name := add_to_api_name

							if api_name == "" {
								api_name = default_api_name
							}

							api := &apis[api_name]

							if api == nil {
								apis[api_name] = API {}
								api = &apis[api_name]
							}

							processed := false

							for v, vi in dd.values {
								#partial switch vd in v.derived {
								case ^ast.Proc_Lit:
									name := f.src[dd.names[vi].pos.offset:dd.names[vi].end.offset]
									type := f.src[vd.type.pos.offset:vd.type.end.offset]
									append(&api.entries, API_Entry { name = name, type = type })
									processed = true
								}
							}

							if !processed {
								type := f.src[dd.pos.offset:dd.end.offset]
								append(&types, type)
							}
						}
					}
				}
			}
		}

		for t in types {
			pln(a, t)
		}

		loader_filename := fmt.tprintf("%v/api_loader_%v.odin", fi.name, fi.name)
		lo, loader_out_err := os1.open(loader_filename, os1.O_WRONLY | os1.O_CREATE | os1.O_TRUNC, 0o644)

		check(loader_out_err == nil, loader_out_err)

		pfln(lo, "package %v\n", plug_ast.name)
		pfln(lo, "import \"kzg:base\"")
		pfln(lo, "import hm \"kzg:base/handle_map\"")

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

			pfln(lo, "}}")
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
				"-custom-attribute=api_opaque",
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