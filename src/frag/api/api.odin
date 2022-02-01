package api

import "linchpin:error"
import "linchpin:memio"

import "core:runtime"

API_Type :: enum {
	Core,
	Plugin,
	App,
	Gfx,
	VFS,
	Asset,
}

App_Event :: struct {
	frame_count: u64,
}

App_API :: struct {
	name: proc() -> string,
}

Asset_Obj :: struct #raw_union {
	id: uintptr,
	ptr: rawptr,
}

Asset_Handle :: struct {
	id: u32,
}

Asset_Load_Params :: struct {
	path: string,
	params: any,
}

Asset_Load_Data :: struct {
	obj: Asset_Obj,
}

Asset_Callbacks :: struct {
	on_prepare: proc(params: ^Asset_Load_Params, mem: ^memio.Mem_Block),
	on_load: proc(data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^memio.Mem_Block),
	on_finalize: proc(data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^memio.Mem_Block),
	on_reload: proc(handle: Asset_Handle, prev_obj: Asset_Obj),
	on_release: proc (obj: Asset_Obj),
}

Asset_API :: struct {
	register_asset_type: proc(name: string, callbacks: Asset_Callbacks),
}

Gfx_Stage :: struct {
	id: u32,
}

Plugin_Event :: enum i32 {
	Load,
	Step,
	Unload,
	Shutdown,
	Init,
}

Plugin_Crash :: enum i32 {
	None,
	Segfault,
	Illegal,
	Abort,
	Misalign,
	Bounds,
	Stack_Overflow,
	State_Invalidated,
	Bad_Image,
	Initial_Failure,
	Other,
	User = 0x100,
}

Plugin_Info :: struct {
	version: u32,
	deps: []string,
	name: string,
	desc: string,
}

Plugin :: struct {
	p: rawptr,
	api: ^Plugin_API,
	iteration: u32,
	crash_reason: Plugin_Crash,
}

Plugin_Main_Callback :: proc(ctx: ^Plugin, e: Plugin_Event)
Plugin_Decl_Cb :: proc(info: ^Plugin_Info)
Plugin_Event_Handler_Callback :: proc(ev: ^App_Event)

Plugin_API :: struct {
	load: proc(name: string) -> error.Error,
}

@(private)
asset_api : Asset_API

@(private)
plugin_api : Plugin_API