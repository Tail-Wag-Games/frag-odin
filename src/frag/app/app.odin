package app

import "thirdparty:sokol"

import "linchpin:platform"

import "frag:api"
import "frag:config"
import "frag:core"
import "frag:private"


import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:os"
import "core:runtime"
import "core:slice"
import "core:strings"
import "core:sys/win32"

App_Context :: struct {
	conf: config.Config,
	app_module: dynlib.Library,
}

Command :: distinct string

run : Command : "run"

ctx := App_Context{}

default_name : string
default_title : string
default_plugin_path : string
default_plugins : [dynamic]string

lit :: proc(str: string) -> (int, string) {
	return len(str), str
} 

message_box :: proc(msg: string) {
  win32.message_box_a(nil, strings.clone_to_cstring(msg, context.temp_allocator), "frag", win32.MB_OK|win32.MB_ICONERROR)
}

init_callback :: proc "c" () {
	context = runtime.default_context()
	context.logger = log.create_console_logger()

	log.info("initializing core!")

	if err := core.init(&ctx.conf, ctx.app_module); err != nil {
		log.errorf("failed initializing core subsystem: %v", err)
		message_box("failed initializing core subsystem, see log for details")
		os.exit(1)
	}

	for plugin in ctx.conf.plugins {
		if err := private.plugin_api.load(plugin); err != nil {
			log.errorf("failed initializing plugin: %v", err)
			os.exit(1)
		}
	}
}

frame_callback :: proc "c" () {
	context = runtime.default_context()
}

cleanup_callback :: proc "c" () {
	context = runtime.default_context()

	core.shutdown()
}

event_callback :: proc "c" (event: ^sokol.Event) {
	if event.type == .KEY_DOWN && !event.key_repeat {
		#partial switch event.key_code {
		case .ESCAPE:
			sokol.request_quit()
		case .Q:
			if .CTRL in event.modifiers {
				sokol.request_quit()
			}
		}
	}
}

@(private)
name :: proc() -> string {
	return ctx.conf.app_name
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
	print_usage_line(1, "run       run a frag plugin that defines an application entry point.")
	print_usage_line(0, "")
	print_usage_line(0, "For further details on a command, use -help after the command name")
	print_usage_line(1, "e.g. frag run -help")
}

main :: proc() {
	args := os.args

	if len(args) < 2 {
		usage(args[0])
		os.exit(1)
	}

	game_filepath : string
	switch command := Command(args[1]); command {
		case run:
			if len(args) < 3 {
				usage(args[0])
				os.exit(1)
			}

			game_filepath = args[2]
		case:
			usage(args[0])
			os.exit(1)
	}

	if len(game_filepath) == 0 {
		message_box("Must provide path to frag plugin defining application entry point, as argument to 'run' command!")
		usage(args[0])
		os.exit(1)
	}

	if !os.is_file(game_filepath) {
		message_box(fmt.tprintf("Plugin at path: %s - does not exist!", game_filepath))
		os.exit(1)
	}

	lib, lib_ok := dynlib.load_library(game_filepath)
	if !lib_ok {
		message_box(fmt.tprintf("Plugin at path: %s - is not a valid shared library! Error: %s", game_filepath, platform.dlerr()))
		os.exit(1)
	}

	ptr, sym_ok := dynlib.symbol_address(lib, "frag_app")
	if !sym_ok {
		message_box(fmt.tprintf("Plugin at path: %s - does not export a symbol named 'frag_app'!", game_filepath, platform.dlerr()))
		os.exit(1)
	}

	fn := cast(proc(conf: ^config.Config)) ptr

	conf := config.Config{}
	fn(&conf)

	default_name = strings.clone(conf.app_name)
	conf.app_name = default_name
	default_title = strings.clone(conf.app_title)
	conf.app_title = default_title
	default_plugin_path = strings.clone(conf.plugin_path)
	conf.plugin_path = default_plugin_path
	
	for i := 0; i < len(conf.plugins); i += 1 {
		append(&default_plugins, strings.clone(conf.plugins[i]))
		conf.plugins[i] = default_plugins[i]
	}

	dynlib.unload_library(lib)

	sokol.run({
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
  private.app_api = api.App_API {
    name = name,
  }
}
