package linchpin

import fcontext "../../vendor/deboost.context"

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:runtime"

Job_Callback :: proc "c" (range_start: int, range_end: int, thread_index: int, user_data: rawptr)
Job_Thread_Init_Callback :: proc "c" (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)
Job_Thread_Shutdown_Callback :: proc "c" (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)

Job_Handle :: distinct ^u32

Job_Priority :: enum {
  High,
  Normal,
  Low,
}

Job :: struct {
  job_index: int,
  done: bool,
  owner_tid: int,
  tags: int,
  stack_mem: fcontext.FContext_Stack,
  fiber: fcontext.FContext,
  selector_fiber: fcontext.FContext,
  counter: Job_Handle,
  wait_counter: Job_Handle,
  ctx: ^Job_Context,
  callback: Job_Callback,
  user_data: rawptr,
  range_start: int,
  range_end: int,
  priority: Job_Priority,
  next: ^Job,
  prev: ^Job,
}

Job_Thread_Data :: struct {
  current_job: ^Job,
  selector_stack: fcontext.FContext_Stack,
  selector_fiber: fcontext.FContext,
  thread_index: int,
  tid: int,
  main_thread: bool,
}

Job_Context_Desc :: struct {
  num_threads: int,
  max_fibers: int,
  fiber_stack_size: int,
  thread_init_cb: Job_Thread_Init_Callback,
  thread_shutdown_cb: Job_Thread_Shutdown_Callback,
  thread_user_data: rawptr,
}

Job_Context :: struct {
  threads: []^thread.Thread,
  stack_size: int,
  job_pool: ^Pool,
  counter_pool: ^Pool,
  waiting_list: [len(Job_Priority)]^Job,
  sem: sync.Semaphore,
  quit: bool,
  thread_init_cb: Job_Thread_Init_Callback,
  thread_shutdown_cb: Job_Thread_Shutdown_Callback,
  thread_user_data: rawptr,
}

COUNTER_POOL_SIZE :: 256
DEFAULT_MAX_FIBERS :: 64
DEFAULT_FIBER_STACK_SIZE :: 1048576    // 1MB

@(private, thread_local)
tl_thread_data: ^Job_Thread_Data

job_selector_fn :: proc "c" (transfer: fcontext.FContext_Transfer) {
  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

destroy_job_tdata :: proc(tdata: ^Job_Thread_Data) {
  fcontext.destroy_fcontext_stack(&tdata.selector_stack)
  free(tdata)
}

create_job_tdata :: proc(tid: int, index: int, main_thread: bool) -> (res: ^Job_Thread_Data, err: Error = .None) {
  res = new(Job_Thread_Data) or_return

  res.thread_index = index
  res.tid = tid
  res.main_thread = main_thread

  res.selector_stack = fcontext.create_fcontext_stack(MIN_STACK_SIZE)

  return
}

job_thread_fn :: proc(ctx: ^Job_Context, index: int) {
  thread_id := sync.current_thread_id()

  td, err := create_job_tdata(thread_id, index + 1, false)
  if err != .None {
    return
  }
  tl_thread_data = td

  if ctx.thread_init_cb != nil {
    ctx.thread_init_cb(ctx, index, thread_id, ctx.thread_user_data)
  }

  fiber := fcontext.make_fcontext(tl_thread_data.selector_stack.sptr, tl_thread_data.selector_stack.ssize, job_selector_fn)
  fcontext.jump_fcontext(fiber, ctx)

  tl_thread_data = nil
  destroy_job_tdata(td)
  if ctx.thread_shutdown_cb != nil {
    ctx.thread_shutdown_cb(ctx, index, thread_id, ctx.thread_user_data)
  }
}

main_thread_job_selector :: proc "c" (transfer: fcontext.FContext_Transfer) {
  tl_thread_data.selector_fiber = nil
  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

create_job_context :: proc(desc: ^Job_Context_Desc) -> (res: ^Job_Context, err: Error = .None) {
  res = new(Job_Context) or_return

  res.stack_size = desc.fiber_stack_size > 0 ? desc.fiber_stack_size : DEFAULT_FIBER_STACK_SIZE
  res.thread_init_cb = desc.thread_init_cb
  res.thread_shutdown_cb = desc.thread_shutdown_cb
  res.thread_user_data = desc.thread_user_data

  max_fibers := desc.max_fibers > 0 ? desc.max_fibers : DEFAULT_MAX_FIBERS

  if tl_thread_data, err = create_job_tdata(sync.current_thread_id(), 0, true); err != .None {
    free(res)
    return
  }
  tl_thread_data.selector_fiber = fcontext.make_fcontext(tl_thread_data.selector_stack.sptr, tl_thread_data.selector_stack.ssize, main_thread_job_selector)

  res.job_pool = create_pool(size_of(Job), max_fibers) or_return
  res.counter_pool = create_pool(size_of(int), COUNTER_POOL_SIZE) or_return

  num_threads := desc.num_threads > 0 ? desc.num_threads : (num_cores() - 1)
  if num_threads > 0 {
    res.threads = make([]^thread.Thread, num_threads)

    for i in 0 ..< len(res.threads) {
      res.threads[i] = thread.create_and_start_with_poly_data2(res, i, job_thread_fn)
    }
  }

  return
}

destroy_job_context :: proc(ctx: ^Job_Context) {
  assert(ctx != nil)
  
  ctx.quit = true
  sync.semaphore_post(&ctx.sem, len(ctx.threads) + 1)

  for t in ctx.threads {
    thread.destroy(t)
  }
  delete(ctx.threads)

  destroy_job_tdata(tl_thread_data)

  destroy_pool(ctx.job_pool)
  destroy_pool(ctx.counter_pool)
  sync.semaphore_destroy(&ctx.sem)

  free(ctx)
}