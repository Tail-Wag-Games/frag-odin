package api

import "thirdparty:getopt"
import "thirdparty:sokol"

import "linchpin:error"
import "linchpin:job"
import "linchpin:math/geom"
import "linchpin:memio"

import "core:log"
import glm "core:math/linalg"
import "core:mem"
import "core:runtime"

PLUGIN_UPDATE_INTERVAL :: f32(1.0)
MAX_PATH :: 256
MAX_PLUGINS :: 64


MAX_APP_TOUCHPOINTS :: 8
MAX_APP_MOUSE_BUTTONS :: 3
MAX_APP_KEY_CODES :: 512

ASSET_POOL_SIZE :: 256

Config :: struct {
  app_name: cstring,
  app_title: cstring,
  plugin_path: cstring,
  cache_path: cstring,
  cwd: cstring,
  app_version: u32,
  app_flags: App_Flags,
	core_flags: Core_Flags,
	log_level: runtime.Logger_Level,

  plugins: [MAX_PLUGINS]cstring,
  
  window_width: i32,
  window_height: i32,
	multi_sample_count: i32,
	swap_interval: i32,
	texture_first_mip: i32,
	texture_filter_min: sokol.sg_filter,
	texture_filter_mag: sokol.sg_filter,
	texture_aniso: i32,

	event_cb: App_Event_Callback,

  num_job_threads: i32,
	max_job_fibers: i32,
	job_stack_size: i32,

	num_initial_coro_fibers: i32,
	coro_stack_size: i32,

	imgui_docking: 
	bool,
}

Api_Type :: enum i32 {
	Core,
	Plugin,
	App,
	Gfx,
	Vfs,
	Asset,
	Camera,
}

// Key codes line up with GLFW
Key_Code :: enum i32 {
	Invalid = 0,
	Space = 32,
	Apostrophe = 39, /* ' */
	Comma = 44,      /* , */
	Minus = 45,      /* - */
	Period = 46,     /* . */
	Slash = 47,      /* / */
	Zero = 48,
	One = 49,
	Two = 50,
	Three = 51,
	Four = 52,
	Five = 53,
	Six = 54,
	Seven = 55,
	Eight = 56,
	Nine = 57,
	Semicolon = 59, /* ; */
	Equal = 61,     /* = */
	A = 65,
	B = 66,
	C = 67,
	D = 68,
	E = 69,
	F = 70,
	G = 71,
	H = 72,
	I = 73,
	J = 74,
	K = 75,
	L = 76,
	M = 77,
	N = 78,
	O = 79,
	P = 80,
	Q = 81,
	R = 82,
	S = 83,
	T = 84,
	U = 85,
	V = 86,
	W = 87,
	X = 88,
	Y = 89,
	Z = 90,
	Left_Bracket = 91,  /* [ */
	Backslash = 92,     /* \ */
	Right_Bracket = 93, /* ] */
	Grave_Accent = 96,  /* ` */
	World_1 = 161,      /* Non-Us #1 */
	World_2 = 162,      /* Non-Us #2 */
	Escape = 256,
	Enter = 257,
	Tab = 258,
	Backspace = 259,
	Insert = 260,
	Delete = 261,
	Right = 262,
	Left = 263,
	Down = 264,
	Up = 265,
	Page_Up = 266,
	Page_Down = 267,
	Home = 268,
	End = 269,
	Caps_Lock = 280,
	Scroll_Lock = 281,
	Num_Lock = 282,
	Print_Screen = 283,
	Pause = 284,
	F1 = 290,
	F2 = 291,
	F3 = 292,
	F4 = 293,
	F5 = 294,
	F6 = 295,
	F7 = 296,
	F8 = 297,
	F9 = 298,
	F10 = 299,
	F11 = 300,
	F12 = 301,
	F13 = 302,
	F14 = 303,
	F15 = 304,
	F16 = 305,
	F17 = 306,
	F18 = 307,
	F19 = 308,
	F20 = 309,
	F21 = 310,
	F22 = 311,
	F23 = 312,
	F24 = 313,
	F25 = 314,
	Kp_0 = 320,
	Kp_1 = 321,
	Kp_2 = 322,
	Kp_3 = 323,
	Kp_4 = 324,
	Kp_5 = 325,
	Kp_6 = 326,
	Kp_7 = 327,
	Kp_8 = 328,
	Kp_9 = 329,
	Kp_Decimal = 330,
	Kp_Divide = 331,
	Kp_Multiply = 332,
	Kp_Subtract = 333,
	Kp_Add = 334,
	Kp_Enter = 335,
	Kp_Equal = 336,
	Left_Shift = 340,
	Left_Control = 341,
	Left_Alt = 342,
	Left_Super = 343,
	Right_Shift = 344,
	Right_Control = 345,
	Right_Alt = 346,
	Right_Super = 347,
	Menu = 348,
}

App_Flag :: enum i32 {
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

App_Event_Type :: enum u32 {
	Invalid,
	Key_Down,
	Key_Up,
	Char,
	Mouse_Down,
	Mouse_Up,
	Mouse_Scroll,
	Mouse_Move,
	Mouse_Enter,
	Mouse_Leave,
	Touch_Began,
	Touch_Moved,
	Touch_Ended,
	Touch_Cancelled,
	Resized,
	Iconified,
	Restored,
	Focused,
	Unfocused,
	Suspended,
	Resumed,
	Update_Cursor,
	Quit_Requested,
	Clipboard_Pasted,
	Files_Dropped,
	Num,
	Update_Apis,
}

Modifier_Key :: enum i32 {
	Shift = (1 << 0),
	Ctrl = (1 << 1),
	Alt = (1 << 2),
	Super = (1 << 3),
}

Modifier_Keys :: bit_set[Modifier_Key]

Mouse_Button :: enum i32 {
	Invalid = -1,
	Left = 0,
	Right = 1,
	Middle = 2,
}

Touch_Point :: struct {
	identifier : uintptr,
	pos_x: f32,
	pos_y: f32,
	changed: bool,
}

App_Event :: struct {
	frame_count: u64,
	event_type: App_Event_Type,
	key_code: Key_Code,
	char_code: u32,
	key_repeat: bool,
	modifiers: u32,
	mouse_button: Mouse_Button,
	mouse_x: f32,
	mouse_y: f32,
	mouse_dx: f32,
	mouse_dy: f32,
	scroll_x: f32,
	scroll_y: f32,
	num_touches: i32,
	touches: [MAX_APP_TOUCHPOINTS]Touch_Point,
	window_width: i32,
	window_height: i32,
	framebuffer_width: i32,
	framebuffer_Height: i32,
	native_event: rawptr,
}

App_Event_Callback :: proc "c" (e: ^App_Event)
Register_Command_Line_Arg_Cb :: proc "c" (name: cstring, short_name: u8, opt_type: getopt.Option_Type, desc: cstring, value_desc: cstring)

App_Api :: struct {
	width: proc "c" () -> i32,
	height: proc "c" () -> i32,
	window_size: proc "c" (size: ^glm.Vector2f32),
	dpi_scale: proc "c" () -> f32,
	command_line_arg_exists: proc "c" (name: cstring) -> bool,
	command_line_arg_value: proc "c" (name: cstring) -> cstring,
	config: proc "c" () -> ^Config,
	key_pressed: proc "c" (key: Key_Code) -> bool,
	mouse_capture: proc "c" (),
	mouse_release: proc "c" (),
	name: proc "c" () -> cstring,
	logger: proc "c" () -> ^log.Logger,
}

Asset_Load_Flag :: distinct u32

ASSET_LOAD_FLAG_NONE :: Asset_Load_Flag(0x0)
ASSET_LOAD_FLAG_ABSOLUTE_PATH :: Asset_Load_Flag(0x1)
ASSET_LOAD_FLAG_WAIT_ON_LOAD :: Asset_Load_Flag(0x2)
ASSET_LOAD_FLAG_RELOAD :: Asset_Load_Flag(0x4)

Asset_Load_Flags :: Asset_Load_Flag

Asset_State :: enum i32 {
	Zombie,
	Ok,
	Failed,
	Loading,
}

Asset_Object :: struct #raw_union {
	id: uintptr,
	ptr: rawptr,
}

Asset_Handle :: struct {
	id: u32,
}

Asset_Meta_Key_Val :: struct {
	key: [32]u8,
	val: [32]u8,
}

Asset_Load_Params :: struct {
	path: cstring,
	params: rawptr,
	tags: u32,
	flags: Asset_Load_Flags,
	num_meta: u32,
	metas: [^]Asset_Meta_Key_Val,
}

Asset_Load_Data :: struct {
	obj: Asset_Object,
	user1: rawptr,
	user2: rawptr,
}

Asset_Callbacks :: struct {
	on_prepare: proc "c" (params: ^Asset_Load_Params, mem: ^memio.Mem_Block) -> Asset_Load_Data,
	on_load: proc "c" (data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^memio.Mem_Block) -> bool,
	on_finalize: proc "c" (data: ^Asset_Load_Data, params: ^Asset_Load_Params, mem: ^memio.Mem_Block),
	on_reload: proc "c" (handle: Asset_Handle, prev_obj: Asset_Object),
	on_release: proc "c" (obj: Asset_Object),
}

Asset_Api :: struct {
	register_asset_type : proc "c" (name: cstring, callbacks: Asset_Callbacks, params_type_name: cstring, params_size: i32),

	load : proc "c" (name: cstring, path: cstring, params: rawptr, flags: Asset_Load_Flags, tags: u32) -> Asset_Handle,
}

Core_Flag :: enum i32 {
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

	delta_tick: proc "c" () -> u64,
	delta_time: proc "c" () -> f32,
	fps: proc "c" () -> f32,
	frame_duration: proc "c" () -> f64,
	frame_time: proc "c" () -> f64,
	frame_index: proc "c" () -> i64,
	
	dispatch_job : proc "c" (count: i32, callback: proc "c" (start, end, thread_idx: i32, user: rawptr), user: rawptr, priority: job.Job_Priority = .Normal, tags: u32 = u32(0)) -> job.Job_Handle,
	test_and_del_job : proc "c" (j: job.Job_Handle) -> bool,

	job_thread_index: proc "c" () -> i32,
	num_job_threads: proc "c" () -> i32,
}

Camera :: struct {
	forward: glm.Vector3f32,
	right: glm.Vector3f32,
	up: glm.Vector3f32,
	pos: glm.Vector3f32,

	quat: glm.Quaternionf32,
	ffar: f32,
	fnear: f32,
	fov: f32,
	viewport: geom.Rectangle,
}

Fps_Camera :: struct {
	cam: Camera,
	pitch: f32,
	yaw: f32,
}

Camera_View_Plane :: enum i32 {
	Left,
	Right,
	Top,
	Bottom,
	Near,
	Far,
}

Camera_Api :: struct {
	init_camera: proc "c" (cam: ^Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32),
	look_at: proc "c" (cam: ^Camera, pos: glm.Vector3f32, target: glm.Vector3f32, up: glm.Vector3f32),
	perspective_mat : proc "c" (cam: Camera) -> glm.Matrix4x4f32,
	view_mat : proc "c" (cam: Camera) -> glm.Matrix4x4f32,
	calc_frustum_points_using_range : proc "c" (cam: ^Camera, fnear: f32, ffar: f32) -> [8]glm.Vector3f32,
	init_fps_camera: proc "c" (fps: ^Fps_Camera, fov_deg: f32, viewport: geom.Rectangle, fnear: f32, ffar: f32),
	fps_look_at: proc "c" (fps: ^Fps_Camera, pos: glm.Vector3f32, target: glm.Vector3f32, up: glm.Vector3f32),
	fps_pitch: proc "c" (fps: ^Fps_Camera, pitch: f32),
	fps_yaw: proc "c" (fps: ^Fps_Camera, yaw: f32),
	fps_forward: proc "c" (fps: ^Fps_Camera, forward: f32),
	fps_strafe: proc "c" (fps: ^Fps_Camera, strafe: f32),
}

Shader_Lang :: enum i32 {
	GLES,
	HLSL,
	MSL,
	GLSL,
}

Shader_Stage :: enum i32 {
	VS,
	FS,
	CS,
}

Shader_Code_Type :: enum i32 {
	Source,
	Bytecode,
}

Shader_Input_Reflection_Data :: struct {
	name: string,
	semantic: string,
	semantic_index: int,
	format: sokol.sg_vertex_format, // for flattened UBOs, array_size must be provided to rendering api w/ type of `FLOAT4`
}

Shader_Uniform_Buffer_Reflection_Data :: struct {
	name: string,
	size_in_bytes: int,
	binding: int,
	array_size: int,
}

Shader_Buffer_Reflection_Data :: struct {
	name: string,
	size_in_bytes: int,
	binding: int,
	array_stride: int,
}

Shader_Texture_Reflection_Data :: struct {
	name: string,
	binding: int,
	image_type: sokol.sg_image_type,
}

Shader_Reflection_Data :: struct {
	lang: Shader_Lang,
	stage: Shader_Stage,
	profile_version: int,
	source_file: string,
	inputs: []Shader_Input_Reflection_Data,
	textures: []Shader_Texture_Reflection_Data,
	storage_images: []Shader_Texture_Reflection_Data,
	storage_buffers: []Shader_Buffer_Reflection_Data,
	uniform_buffers: []Shader_Uniform_Buffer_Reflection_Data,
	code_type: Shader_Code_Type,
	flatten_ubos: bool,
}

Shader_Info :: struct {
	inputs: [sokol.SG_MAX_VERTEX_ATTRIBUTES]Shader_Input_Reflection_Data,
	num_inputs: int,
	name_handle: u32,
}

Texture_Load_Params :: struct {
	first_mip: i32,
	min_filter: sokol.sg_filter,
	mag_filter: sokol.sg_filter,
	wrap_u: sokol.sg_wrap,
	wrap_v: sokol.sg_wrap,
	wrap_w: sokol.sg_wrap,
	fmt: sokol.sg_pixel_format,
	aniso: i32,
	srgb: bool,
}

Texture_Info :: struct {
	name_handle: u32,
	image_type: sokol.sg_image_type,
	format: sokol.sg_pixel_format,
	size_in_bytes: i32,
	width: i32,
	height: i32,
	using dl: struct #raw_union {
		depth: i32,
		layers: i32,
	},
	mips: i32,
	bpp: i32,
}

Texture :: struct {
	img: sokol.sg_image,
	info: Texture_Info,
}

Vertex_Attribute :: struct {
	semantic: string,
	semantic_index: int,
	offset: int,
	format: sokol.sg_vertex_format,
	buffer_index: int,
}

Vertex_Layout :: struct {
	attributes: [sokol.SG_MAX_VERTEX_ATTRIBUTES]Vertex_Attribute,
}

Shader :: struct {
	shd: sokol.sg_shader,
	info: Shader_Info,
}

Stage_Handle :: struct {
	id: u32,
}

Draw_Api :: struct {
	begin: proc "c" (stage_handle: Stage_Handle) -> bool,
	end: proc "c" (),

	begin_default_pass: proc "c" (pass_action: ^sokol.sg_pass_action, width: i32, height: i32),
	begin_pass: proc "c" (pass: sokol.sg_pass, pass_action: ^sokol.sg_pass_action),
	apply_viewport: proc "c" (x: i32, y: i32, width: i32, height: i32, origin_top_left: bool),
	apply_scissor_rect: proc "c" (x: i32, y: i32, width: i32, height: i32, origin_top_left: bool),
	apply_pipeline: proc "c" (pip: sokol.sg_pipeline),
	apply_bindings: proc "c" (bind: ^sokol.sg_bindings),
	apply_uniforms: proc "c" (stage: sokol.sg_shader_stage, ub_index: i32, data: rawptr, num_bytes: i32),
	draw: proc "c" (base_element: i32, num_elements: i32, num_instances: i32),
	end_pass: proc "c" (),
	update_buffer: proc "c" (buf: sokol.sg_buffer, data : rawptr, size: i32),
	append_buffer: proc "c" (buf: sokol.sg_buffer, data : rawptr, size: i32) -> i32,
	update_image: proc "c" (img: sokol.sg_image, data: ^sokol.sg_image_data),
}

Gfx_Api :: struct {
	imm: Draw_Api,
	staged: Draw_Api,

	make_buffer: proc "c" (desc: ^sokol.sg_buffer_desc) -> sokol.sg_buffer,
	make_pass : proc "c" (desc: ^sokol.sg_pass_desc) -> sokol.sg_pass,
	make_pipeline: proc "c" (desc: ^sokol.sg_pipeline_desc) -> sokol.sg_pipeline,
	make_image : proc "c" (desc: ^sokol.sg_image_desc) -> sokol.sg_image,
	destroy_buffer: proc "c" (buf: sokol.sg_buffer),
	destroy_shader: proc "c" (shd: sokol.sg_shader),
	destroy_pipeline: proc "c" (pip: sokol.sg_pipeline),
	destroy_pass : proc "c" (pass: sokol.sg_pass),
	destroy_image: proc "c" (img: sokol.sg_image),
	init_image : proc "c" (img: sokol.sg_image, desc: ^sokol.sg_image_desc),
	make_shader_with_data: proc "c" (vs_data_size: u32, vs_data: [^]u32, vs_refl_size: u32, vs_refl_json: [^]u32, fs_data_size: u32, fs_data: [^]u32, fs_ref_size: u32, fs_ref_json: [^]u32) -> Shader,
	register_stage: proc "c" (name: string, parent_stage: Stage_Handle) -> Stage_Handle,
	bind_shader_to_pipeline: proc "c" (shd: ^Shader, desc: ^sokol.sg_pipeline_desc, layout: ^Vertex_Layout) -> ^sokol.sg_pipeline_desc,
	alloc_image: proc "c" () -> sokol.sg_image,
	alloc_shader : proc "c" () -> sokol.sg_shader,

	texture_white: proc "c" () -> sokol.sg_image,
	texture_black: proc "c" () -> sokol.sg_image,
	texture_checker: proc "c" () -> sokol.sg_image,
}

Plugin_Event :: enum i32 {
	Load,
	Step,
	Unload,
	Close,
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
	api: ^Plugin_Api,
	iteration: u32,
	crash_reason: Plugin_Crash,
}

Plugin_Main_Callback :: proc(ctx: ^Plugin, e: Plugin_Event)
Plugin_Decl_Cb :: proc(info: ^Plugin_Info)
Plugin_Event_Handler_Callback :: proc(ev: ^App_Event)

Plugin_Api :: struct {
	load: proc "c" (name: cstring) -> error.Error,
	inject_api: proc "c" (name: cstring, api: rawptr),
	get_api: proc "c" (kind: Api_Type) -> rawptr,
	get_api_by_name: proc "c" (name: cstring) -> rawptr,
}

VFS_FLAG_NONE :: Vfs_Flags(0x01)
VFS_FLAG_ABSOLUTE_PATH :: Vfs_Flags(0x02)
VFS_FLAG_TEXT_FILE :: Vfs_Flags(0x04)
VFS_FLAG_APPEND :: Vfs_Flags(0x08)

Vfs_Flags :: distinct u32

Async_Read_Callback :: proc "c" (path: cstring, mem: ^memio.Mem_Block, user_data: rawptr)
Async_Write_Callback :: proc "c" (path: cstring, bytes_written: i32, mem: ^memio.Mem_Block, user_data: rawptr)

Vfs_Api :: struct {
	mount: proc "c" (path: cstring, alias: cstring, watch: bool) -> error.Error,
	register_modify_cb: proc "c" (modify_cb: proc "c" (path: cstring)),
	read_async : proc "c" (path: cstring, flags: Vfs_Flags, read_fn: Async_Read_Callback, user: rawptr),
	read : proc "c" (path: cstring, flags: Vfs_Flags) -> ^memio.Mem_Block,
}

to_id :: proc(idx: int) -> u32 {
	return u32(idx) + 1
}

to_index :: proc(id: u32) -> int {
	return int(id) - 1
}