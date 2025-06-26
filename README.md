# WIP Odin game engine

> [!WARNING]
> I've barely even gotten started on this, it's just some experiments right now.

What exists:
- Some Direct3D 12 code for drawing UI rects
- A start of some kind of plugin system

Upcoming milestones:
- Plugin system with hot reload
- Direct3D 12 rendering for tools programming: Basics rects + text + UI controls
- Some kind of simple interactive editor that can save / load data

## TODO

- plugin system
	- base.get_api doesn't work in thingy.odin -- this is because the global in there gets compiled into the plugin. Instead the kzg_plugin_loaded needs to be fed a struct that represents the plugin API API. On it you can register your plugin and fetch plugins. Fetching a plugin that is not yet registered will make it but give you a nil pointer that will later be filled out.
	- Move types from `api_types.odin` to normal files and make them use some @api attribute. Make the whole type print into the API file
	- Rename `api_types.odin` to `api_imports.odin`... I think?
	- Try reloading a plugin when the DLL changes on disk.
		- Maybe we can reload the DLL that uses it too if the API struct changes (since the API struct becomes part of the import)

- introduce a separate rendering thread
	- we could do a job based system where command lists are created as jobs and then submitted
	- needs a renderer interface

- UI:
	- package?
