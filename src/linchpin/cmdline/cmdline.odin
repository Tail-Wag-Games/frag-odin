package cmdline

import "thirdparty:getopt"

create_context :: proc(argc: i32, argv: [^]cstring, opts: ^getopt.Option) -> ^getopt.Context {
  ctx := new(getopt.Context)

  r := getopt.create_context(ctx, argc, argv, opts)
  if r < 0 {
    free(ctx)
  }

  return ctx
}

destroy_context :: proc(ctx: ^getopt.Context) {
  assert(ctx != nil)
  free(ctx)
}

next :: proc(ctx: ^getopt.Context, index: ^i32, arg: ^cstring) -> i32 {
  r := getopt.next(ctx)
  if r != -1 {
    if index != nil {
      index^ = ctx.current_index
    }
    if arg != nil {
      arg^ = ctx.current_opt_arg
    }
  }

  return r
}

create_help_string :: proc(ctx: ^getopt.Context, buffer: cstring, buffer_size: uint) -> cstring {
  return getopt.create_help_string(ctx, buffer, buffer_size)
}