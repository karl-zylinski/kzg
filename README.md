# WIP Odin game engine

> [!WARNING]
> I've barely even gotten started on this, it's just some experiments right now.

What exists:
- Some Direct3D 12 code for drawing UI rects
- Plugin system with hot reload (go into plugins folder and do `odin run .` to hot reload while program is running)

Upcoming milestones:
- Direct3D 12 rendering for tools programming: Basics rects + text + UI controls
- Some kind of simple interactive editor that can save / load data
- A separate rendering thread or some kind of rendering happening as a job in a job system

## TODO

- hot reload
	- what if plugin API changes size? Then mem.copy in plugin_system.odin doesn't work.
		- preallocate maximum size for each API, or somehow hand out pointer to pointer... Perhaps the `get_api` can be fed a pointer it writes into instead of the other way around?
	- make debugging work (write PDB to unique path)
	- remove the runtime copies on start and shutdown

- introduce a separate rendering thread
	- we could do a job based system where command lists are created as jobs and then submitted
	- needs a renderer interface

- UI:
	- package?
