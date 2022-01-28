package job

import "../../linchpin"

import ".."

import "core:fmt"
import "core:runtime"
import "core:sync"
import "core:thread"

Job_Context_Desc :: struct {
  num_threads: int,
  max_fibers: int,
  fiber_stack_size: int,
}

Job_Context :: struct {
  threads: []^thread.Thread,
  stack_size: int,
  thread_tls: linchpin.TLS,
  sem: sync.Semaphore,
}

COUNTER_POOL_SIZE :: 256
DEFAULT_MAX_FIBERS :: 64
DEFAULT_FIBER_STACK_SIZE :: 1048576    // 1MB


create_job_context :: proc(desc: ^Job_Context_Desc) -> (res: ^Job_Context, err: frag.Error) {
  ctx := new(Job_Context)

  if ctx == nil {
    return {}, .Out_Of_Memory 
  }

  ctx.threads = make([]^thread.Thread, desc.num_threads > 0 ? desc.num_threads : (linchpin.num_cores() - 1))
  ctx.thread_tls = linchpin.tls_create()
  ctx.stack_size = desc.fiber_stack_size > 0 ? desc.fiber_stack_size : DEFAULT_FIBER_STACK_SIZE

  sync.semaphore_init(&ctx.sem)

  return ctx, .None
}

destroy_job_context :: proc(ctx: ^Job_Context) {
  delete(ctx.threads)
  
  free(ctx)
}