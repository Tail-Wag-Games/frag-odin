package job

import "../../linchpin"

import ".."

import "core:fmt"
import "core:runtime"
import "core:thread"

Job_Context_Desc :: struct {
  num_threads: int,
}

Job_Context :: struct {
  threads: [dynamic]^thread.Thread,
}

create_job_context :: proc(desc: ^Job_Context_Desc) -> (res: ^Job_Context, err: frag.Error) {
  ctx := new(Job_Context)

  if ctx == nil {
    return {}, .Out_Of_Memory 
  }

  // runtime.reserve(&ctx.threads, desc.num_threads > 0 ? desc.num_threads : (linchpin.num_cores() - 1))
  runtime.resize(&ctx.threads, desc.num_threads > 0 ? desc.num_threads : (linchpin.num_cores() - 1))

  return ctx, .None
}

destroy_job_context :: proc(ctx: ^Job_Context) {
  free(ctx)
}