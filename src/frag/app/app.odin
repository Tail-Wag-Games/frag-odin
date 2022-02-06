package app

import "thirdparty:sokol"

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

App_Context :: struct {
	conf: api.Config,
	alloc: mem.Allocator,
	logger: ^log.Logger,
	app_filepath: string,
	window_size: linalg.Vector2f32,
	app_module: dynlib.Library,
}

Command :: distinct string

run : Command : "run"

ctx : App_Context
ta : mem.Tracking_Allocator

default_name : string
default_title : string
default_plugin_path : string
default_plugins : [api.MAX_PLUGINS]string

lit :: proc(str: string) -> (int, string) {
	return len(str), str
} 

message_box :: proc(msg: string) {
  win32.message_box_a(nil, strings.clone_to_cstring(msg, context.temp_allocator), "frag", win32.MB_OK|win32.MB_ICONERROR)
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

	if plugin.load_abs(ctx.app_filepath, true, slice.filter(ctx.conf.plugins[:], proc(x: string) -> bool { return len(x) > 0 })) != nil {
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

config :: proc "c" () -> ^api.Config {
	return &ctx.conf
}

name :: proc "c" () -> string {
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

	args := os.args

	if len(args) < 2 {
		usage(args[0])
		os.exit(1)
	}

	sokol.stm_setup()

	app_filepath : string
	switch command := Command(args[1]); command {
		case run:
			if len(args) < 3 {
				usage(args[0])
				os.exit(1)
			}

			app_filepath = args[2]
		case:
			usage(args[0])
			os.exit(1)
	}

	if len(app_filepath) == 0 {
		message_box("Must provide path to frag plugin defining application entry point, as argument to 'run' command!")
		usage(args[0])
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

	fn := cast(proc(conf: ^api.Config)) ptr

	conf := api.Config{}
	
	fn(&conf)

	default_name = strings.clone(conf.app_name, context.temp_allocator)
	conf.app_name = default_name
	default_title = strings.clone(conf.app_title, context.temp_allocator)
	conf.app_title = default_title
	default_plugin_path = strings.clone(conf.plugin_path, context.temp_allocator)
	conf.plugin_path = default_plugin_path
	
	for i := 0; i < api.MAX_PLUGINS; i += 1 {
		if len(conf.plugins[i]) == 0 {
			break
		}

		default_plugins[i] = strings.clone(conf.plugins[i], context.temp_allocator)
		conf.plugins[i] = default_plugins[i]
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
		window_title = strings.clone_to_cstring(conf.app_title, context.temp_allocator),
	})
}

@(init, private)
init_app_api :: proc() {
  private.app_api = {
		logger = logger,
		width = sokol.sapp_width,
		height = sokol.sapp_height,
		config = config,
    name = name,
  }
}
