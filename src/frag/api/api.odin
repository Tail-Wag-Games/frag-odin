package api

import "thirdparty:sokol"

import "linchpin:error"
import "linchpin:memio"

import "core:log"
import "core:mem"
import "core:runtime"

Config :: struct {
  app_name: string,
  app_title: string,
  plugin_path: string,
  cache_path: string,
  cwd: string,
  app_version: u32,
  app_flags: App_Flags,
	core_flags: Core_Flags,
	log_level: runtime.Logger_Level,

  plugins: [MAX_PLUGINS]string,
  
  window_width: int,
  window_height: int,
	multi_sample_count: int,
	swap_interval: int,
	texture_first_mip: int,
	texture_filter_min: sokol.sg_filter,
	texture_filter_mag: sokol.sg_filter,
	texture_aniso: int,

	event_cb: App_Event_Callback,

  num_job_threads: int,
	max_job_fibers: int,
	job_stack_size: int,

	num_initial_coro_fibers: int,
	coro_stack_size: int,

	imgui_docking: bool,
}

Api_Type :: enum {
	Core,
	Plugin,
	App,
	Gfx,
	VFS,
	Asset,
}

App_Flag :: enum {
	High_Dpi,
	Fullscreen,
	Alpha,
	Premultiplied_Alpha,
	Preserve_Drawing_Buffer,
	Html5_Canvas_Resize,
	Ios_Keyboard_Resizes_Canvas,
	User_Corsor,
	Force_Gles2,
	Crash_Dump,
	Resume_Iconified,
}

App_Flags :: bit_set[App_Flag]

App_Event :: struct {
	frame_count: u64,
}

App_Event_Callback :: proc "c" (e: ^App_Event)

App_Api :: struct {
	logger: proc "c" () -> ^log.Logger,
	width: proc "c" () -> i32,
	height: proc "c" () -> i32,
	config: proc "c" () -> ^Config,
	name: proc "c" () -> string,
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

Asset_Api :: struct {
	register_asset_type: proc(name: string, callbacks: Asset_Callbacks),
}

Core_Flag :: enum {
	Log_To_File,
	Log_To_Profiler,
	Profile_Gpu,
	Dump_Unused_Assets,
	Detect_Leaks,
	Hot_Reload_Plugins,
}

Core_Flags :: bit_set[Core_Flag]

Core_Api :: struct {
	alloc: proc "c" () -> mem.Allocator,
	fps: proc "c" () -> f32,
	job_thread_index: proc "c" () -> int,
	num_job_threads: proc "c" () -> int,
}

Shader_Info :: struct {
	
}

Shader :: struct {
	shd: sokol.sg_shader,
	info: Shader_Info,
}

Gfx_Stage_Handle :: struct {
	id: u32,
}

Gfx_Draw_Api :: struct {
	begin: proc "c" (stage_handle: Gfx_Stage_Handle) -> bool,
	end: proc "c" (),

	begin_default_pass: proc "c" (pass_action: ^sokol.sg_pass_action, width: i32, height: i32),
	begin_pass: proc "c" (pass: sokol.sg_pass, pass_action: ^sokol.sg_pass_action),
	apply_viewport: proc "c" (x: int, y: int, width: int, height: int, origin_top_left: bool),
	apply_scissor_rect: proc "c" (x: int, y: int, width: int, height: int, origin_top_left: bool),
	apply_pipeline: proc "c" (pip: sokol.sg_pipeline),
	apply_bindings: proc "c" (bind: ^sokol.sg_bindings),
	apply_uniforms: proc "c" (stage: sokol.sg_shader_stage, ub_index: int, data: rawptr, num_bytes: int),
	draw: proc "c" (base_element: int, num_elements: int, num_instances: int),
	dispatch: proc "c" (thread_group_x: int, thread_group_y: int, thread_group_z: int),
	end_pass: proc "c" (),
	update_buffer: proc "c" (buf: sokol.sg_buffer, data_ptr: rawptr, data_size: int),
	append_buffer: proc "c" (buf: sokol.sg_buffer, data_ptr: rawptr, data_size: int),
	update_image: proc "c" (img: sokol.sg_image, data: ^sokol.sg_image_data),
}

Gfx_Api :: struct {
	imm: Gfx_Draw_Api,
	staged: Gfx_Draw_Api,

	register_stage: proc "c" (name: string, parent_stage: Gfx_Stage_Handle) -> Gfx_Stage_Handle,
	make_shader_with_data: proc "c" (vs_data_size: u32, vs_data: [^]u32, vs_refl_size: u32, vs_refl_json: [^]u32, fs_data_size: u32, fs_data: [^]u32, fs_ref_size: u32, fs_ref_json: [^]u32) -> Shader,
}

Plugin_Event :: enum i32 {
	Load,
	Step,
	Unload,
	Close,
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
	api: ^Plugin_Api,
	iteration: u32,
	crash_reason: Plugin_Crash,
}

Plugin_Main_Callback :: proc(ctx: ^Plugin, e: Plugin_Event)
Plugin_Decl_Cb :: proc(info: ^Plugin_Info)
Plugin_Event_Handler_Callback :: proc(ev: ^App_Event)

Plugin_Api :: struct {
	load: proc "c" (name: string) -> error.Error,
	inject_api: proc "c" (name: string, api: rawptr),
	get_api: proc "c" (kind: Api_Type) -> rawptr,
	get_api_by_name: proc "c" (name: string) -> rawptr,
}

Vfs_Api :: struct {

}

PLUGIN_UPDATE_INTERVAL :: f32(1.0)
MAX_PLUGINS :: 64

MAX_APP_TOUCHPOINTS :: 8
MAX_APP_MOUSE_BUTTONS :: 3
MAX_APP_KEY_CODES :: 512

@(private)
core_api : Core_Api

@(private)
plugin_api: Plugin_Api

@(private)
app_api : App_Api

@(private)
gfx_api: Gfx_Api

@(private)
vfs_api: Gfx_Api

@(private)
asset_api : Asset_Api

to_id :: proc(idx: int) -> u32 {
	return u32(idx) + 1
}

to_index :: proc(id: u32) -> int {
	return int(id) - 1
}