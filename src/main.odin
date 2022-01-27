package main

import "../vendor/sokol"

import "frag"
import "frag/core"

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:runtime"
import "core:strings"
import "core:sys/win32"

AppContext :: struct {
	conf: frag.Config,
}

Command :: distinct string

run : Command : "run"

ctx := AppContext{}

dlerr :: proc() -> string {
  when ODIN_OS == "windows" {
    return fmt.tprintf("%d", win32.get_last_error())
  }
}

message_box :: proc(msg: string) {
  win32.message_box_a(nil, strings.clone_to_cstring(msg, context.temp_allocator), "frag", win32.MB_OK|win32.MB_ICONERROR)
}

init_callback :: proc "c" () {
	context = runtime.default_context()

	core.init(&ctx.conf)
}

frame_callback :: proc "c" () {
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

lit :: proc(str: string) -> (int, string) {
	return len(str), str
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
		message_box(fmt.tprintf("Plugin at path: %s - is not a valid shared library! Error: %s", game_filepath, dlerr()))
		os.exit(1)
	}

	ptr, sym_ok := dynlib.symbol_address(lib, "frag_app")
	if !sym_ok {
		message_box(fmt.tprintf("Plugin at path: %s - does not export a symbol named 'frag_app'!", game_filepath, dlerr()))
		os.exit(1)
	}

	fn := cast(proc(conf: ^frag.Config)) ptr

	conf := frag.Config{}
	fn(&conf)
	
	err := sokol.run({
		init_cb      = init_callback,
		frame_cb     = frame_callback,
		cleanup_cb   = proc "c" () { },
		event_cb     = event_callback,
		width        = auto_cast conf.window_width,
		height       = auto_cast conf.window_height,
		window_title = strings.clone_to_cstring(conf.app_title, context.temp_allocator),
	})
	os.exit(int(err))
}
