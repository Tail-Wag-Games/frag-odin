package app

import "thirdparty:getopt"
import "thirdparty:sokol"

import "linchpin:cmdline"
import "linchpin:platform"

import "frag:api"

import "frag:core"
import "frag:plugin"
import "frag:private"


import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:runtime"
import "core:slice"
import "core:strings"
import "core:sys/win32"

Command_Line_Item :: struct {
	name: cstring,
	allocated_value: bool,
	using vp: struct #raw_union {
		value: [8]u8,
		value_ptr: ^u8,
	},
}

App_Context :: struct {
	conf: api.Config,
	alloc: mem.Allocator,
	logger: ^log.Logger,
	app_filepath: string,
	window_size: linalg.Vector2f32,
	cmd_line_args: [dynamic]getopt.Option,
	cmd_line_items: [dynamic]Command_Line_Item,
	app_module: dynlib.Library,
}

Command :: distinct string

run : Command : "run"

ctx : App_Context
ta : mem.Tracking_Allocator

default_name: [64]u8
default_title: [64]u8
default_plugin_path: [128]u8
default_plugins : [api.MAX_PLUGINS][32]u8

lit :: proc(str: string) -> (int, string) {
	return len(str), str
} 

message_box :: proc(msg: string) {
  win32.message_box_a(nil, strings.clone_to_cstring(msg, context.temp_allocator), "frag", win32.MB_OK|win32.MB_ICONERROR)
}

parse_command_line :: proc () {
	for arg in ctx.cmd_line_args {
		
	}
}

register_command_line_arg :: proc "c" (name: cstring, short_name: u8, opt_type: getopt.Option_Type, desc: cstring, value_desc: cstring) {
	context = runtime.default_context()
	context.logger = ctx.logger^
	context.allocator = ctx.alloc

	for i in 0 ..< len(ctx.cmd_line_items) {
		opt := &ctx.cmd_line_args[i]
		if opt.name == name {
			assert(false, fmt.tprintf("command-line argument with name: %s - already registered", name))
			return
		}
	}

	append(&ctx.cmd_line_args, getopt.Option {
		name = name,
		short_name = i32(short_name),
		option_type = opt_type,
		value = 1,
		desc = desc,
		value_desc = value_desc,
	})
}

init_callback :: proc "c" () {
	context = runtime.default_context()
	context.logger = ctx.logger^
	context.allocator = ctx.alloc

	if err := core.init(&ctx.conf, ctx.app_module); err != nil {
		log.errorf("failed initializing core subsystem: %v", err)
		message_box("failed initializing core subsystem, see log for details")
		os.exit(1)
	}

	for p in ctx.conf.plugins {
		if len(p) == 0 {
			break
		}

		if plugin.load(p) != nil {
			os.exit(1)
		}
	}

	if plugin.load_abs(ctx.app_filepath, 
		true, 
		slice.mapper(
			slice.filter(ctx.conf.plugins[:], proc(x: cstring) -> bool { return len(x) > 0 }), 
			proc(s: cstring) -> string { return strings.clone_from_cstring(s, context.temp_allocator) }),
		) != nil {
		log.errorf("failed loading application's shared library at: %s", ctx.app_filepath)
		message_box("failed loading application's shared library, see log for details")
		os.exit(1)
	}

	if plugin.init_plugins() != nil {
		log.error("failed initializing plugins")
		message_box("failed initializing plugins, see log for details")
		os.exit(1)
	}
}

frame_callback :: proc "c" () {
	context = runtime.default_context()
	context.logger = ctx.logger^
	context.allocator = ctx.alloc

	core.frame()
}

cleanup_callback :: proc "c" () {
	context = runtime.default_context()
	context.logger = ctx.logger^
	context.allocator = ctx.alloc

	log.debug("shutting down core subsystem")
	core.shutdown()
	log.debug("core subsystem shut down")
}

event_callback :: proc "c" (event: ^sokol.sapp_event) {
	if event.type == .SAPP_EVENTTYPE_KEY_DOWN && !event.key_repeat {
		#partial switch event.key_code {
		case .SAPP_KEYCODE_ESCAPE:
			sokol.sapp_request_quit()
		case .SAPP_KEYCODE_Q:
			if u32(sokol.sapp_modifier.SAPP_MODIFIER_CTRL) == event.modifiers {
				sokol.sapp_request_quit()
			}
		}
	}
}

window_size :: proc "c" (size: ^linalg.Vector2f32) {
	context = runtime.default_context()
	context.logger = ctx.logger^
	context.allocator = ctx.alloc
	
	assert(size != nil)
	size^ = ctx.window_size
}

config :: proc "c" () -> ^api.Config {
	return &ctx.conf
}

name :: proc "c" () -> cstring {
	return ctx.conf.app_name
}

logger :: proc "c" () -> ^log.Logger {
	return ctx.logger
}

print_usage_line :: proc(indent: int, fmt_string: string, args: ..any) {
	i := indent
	for i > 0 {
		fmt.print("\t")
		i -= 1
	}

	fmt.printf(fmt_string, ..args)
	fmt.print("\n")
}

usage :: proc(program_name: string) {
	print_usage_line(0, "%*s is a game engine", lit(program_name))
	print_usage_line(0, "Usage:")
	print_usage_line(1, "%*s command [arguments]", lit(program_name))
	print_usage_line(0, "Commands:")
	print_usage_line(1, "run       load an application entry point from a shared library and run it.")
	print_usage_line(0, "")
	print_usage_line(0, "For further details on a command, use -help after the command name")
	print_usage_line(1, "e.g. frag run -help")
}

main :: proc() {
	mem.tracking_allocator_init(&ta, context.allocator)
	ctx.alloc = mem.tracking_allocator(&ta)
	context.allocator = ctx.alloc

	defer {
			if len(ta.allocation_map) > 0 {
					fmt.eprintf("*** Memory Leaks Detected ***\n")
					for _, entry in ta.allocation_map {
							fmt.eprintf(" %v\n", entry.location)
					}
			} else {
				fmt.println("No Memory Leaks Detected!")
			}
			
			if len(ta.bad_free_array) > 0 {
					fmt.eprintf("*** Bad Frees Detected ***\n")
					for entry in ta.bad_free_array {
							fmt.eprintf(" %v\n", entry.location)
					}
			} else {
				fmt.println("No Bad Frees Detected!")
			}
	}

	logger := log.create_console_logger()
	defer log.destroy_console_logger(&logger)
	
	ctx.logger = &logger

	sokol.stm_setup()

	opts := []getopt.Option {
		{"run", 'r', .Required, nil, 'r', "game or application module to run", "filepath"},
		getopt.OPTIONS_END,
	}

	args := slice.mapper(
		os.args, 
		proc(s: string) -> cstring { return strings.clone_to_cstring(s, context.temp_allocator) })

	// args_copy := cstring(raw_data(args))
	cmdline_ctx := cmdline.create_context(i32(len(args)), &args[0], &opts[0])

	arg : cstring
	app_filepath : string
	cwd: string
	opt := cmdline.next(cmdline_ctx, nil, &arg)
	for opt != -1 {
		switch opt {
			case i32('+'): {
				message_box(fmt.tprintf("missing flag for argument: %s", strings.clone_from_cstring(arg, context.temp_allocator)))
			}
			case i32('!'): {
				message_box(fmt.tprintf("invalid argument usage: %s", strings.clone_from_cstring(arg, context.temp_allocator)))
				os.exit(1)
			}
			case i32('r'): {
				app_filepath = strings.clone_from_cstring(arg, context.temp_allocator)
			}
			case i32('c'): {
				cwd = strings.clone_from_cstring(arg, context.temp_allocator)
			}
			case: {
				break
			}
		}
		opt = cmdline.next(cmdline_ctx, nil, &arg)
	}

	// app_filepath : string
	// switch command := Command(args[1]); command {
	// 	case run:
	// 		if len(args) < 3 {
	// 			usage(args[0])
	// 			os.exit(1)
	// 		}

	// 		app_filepath = args[2]
	// 	case:
	// 		usage(args[0])
	// 		os.exit(1)
	// }

	if len(app_filepath) == 0 {
		message_box("Must provide path to frag plugin defining application entry point, as argument to 'run' command!")
		usage(string(args[0]))
		os.exit(1)
	}

	if !os.is_file(app_filepath) {
		message_box(fmt.tprintf("Plugin at path: %s - does not exist!", app_filepath))
		os.exit(1)
	}

	lib, lib_ok := dynlib.load_library(app_filepath)
	if !lib_ok {
		message_box(fmt.tprintf("Plugin at path: %s - is not a valid shared library! Error: %s", app_filepath, platform.dlerr()))
		os.exit(1)
	}

	ptr, sym_ok := dynlib.symbol_address(lib, "frag_app")
	if !sym_ok {
		message_box(fmt.tprintf("Plugin at path: %s - does not export a symbol named 'frag_app'!", app_filepath, platform.dlerr()))
		os.exit(1)
	}

	fn := cast(proc(conf: ^api.Config, cb: api.Register_Command_Line_Arg_Cb)) ptr

	conf := api.Config{}
	
	fn(&conf, register_command_line_arg)
	
	mem.copy(&default_name[0], transmute(rawptr)conf.app_name, len(conf.app_name))
	conf.app_name = transmute(cstring)raw_data(&default_name)

	mem.copy(&default_title[0], transmute(rawptr)conf.app_title, len(conf.app_title))
	conf.app_title = transmute(cstring)raw_data(&default_title)

	mem.copy(&default_plugin_path[0], transmute(rawptr)conf.plugin_path, len(conf.plugin_path))
	conf.plugin_path = transmute(cstring)raw_data(&default_plugin_path)
	
	for i := 0; i < api.MAX_PLUGINS; i += 1 {
		if len(conf.plugins[i]) == 0 {
			break
		}

		mem.copy(&default_plugins[i][0], transmute(rawptr)conf.plugins[i], len(conf.plugins[i]))
		conf.plugins[i] = transmute(cstring)&default_plugins[i][0]
	}

	dynlib.unload_library(lib)

	ctx.conf = conf
	ctx.app_filepath = app_filepath
	ctx.window_size = {f32(conf.window_width), f32(conf.window_height)}

	sokol.sapp_run(&sokol.sapp_desc{
		init_cb      = init_callback,
		frame_cb     = frame_callback,
		cleanup_cb   = cleanup_callback,
		event_cb     = event_callback,
		width        = auto_cast conf.window_width,
		height       = auto_cast conf.window_height,
		window_title = conf.app_title,
	})
}

@(init, private)
init_app_api :: proc() {
  private.app_api = {
		width = sokol.sapp_width,
		height = sokol.sapp_height,
		window_size = window_size,
		dpi_scale = sokol.sapp_dpi_scale,
		config = config,
    name = name,
		logger = logger,
  }
}
