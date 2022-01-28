package frag

import "mfio"

import "core:runtime"

Error :: union {
	runtime.Allocator_Error,
};

Asset_Obj :: union {
	uintptr,
	rawptr,
}

Asset_Handle :: distinct u32

Asset_Load_Params :: struct {
	path: string,
	params: any,
}

Asset_Load_Data :: struct {
	obj: Asset_Obj,
}

Asset_Callbacks :: struct {
	on_prepare: proc "c" (params: ^Asset_Load_Params, mem: ^mfio.Mem_Block),
	on_load: proc "c" (data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^mfio.Mem_Block),
	on_finalize: proc "c" (data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^mfio.Mem_Block),
	on_reload: proc "c" (handle: Asset_Handle, prev_obj: Asset_Obj),
	on_release: proc "c" (obj: Asset_Obj),
}

Asset_API :: struct {
	register_asset_type: proc "c" (name: string, callbacks: Asset_Callbacks),
}