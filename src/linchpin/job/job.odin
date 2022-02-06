package job

import "thirdparty:fcontext"
import "thirdparty:lockless"

import "linchpin:error"
import "linchpin:platform"
import "linchpin:pool"

import "core:fmt"
import "core:mem"
import "core:runtime"
import "core:sync"
import "core:thread"

Job_Callback :: proc (range_start: int, range_end: int, thread_index: int, user_data: rawptr)
Job_Thread_Init_Callback :: proc (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)
Job_Thread_Shutdown_Callback :: proc (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)

Job_Handle :: ^u32

Job_Priority :: enum {
  High,
  Normal,
  Low,
  Count,
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

Selected_Job :: struct {
  job: ^Job,
  waiting_list_alive: bool,
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
  alloc: mem.Allocator,
  threads: []^thread.Thread,
  stack_size: int,
  job_pool: ^pool.Pool,
  counter_pool: ^pool.Pool,
  waiting_list: [Job_Priority.Count]^Job,
  waiting_list_last: [Job_Priority.Count]^Job,
  job_lock: lockless.Spinlock,
  counter_lock: lockless.Spinlock,
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

delete_job :: proc(ctx: ^Job_Context, job: ^Job) {
  lockless.lock_enter(&ctx.job_lock)
  defer lockless.lock_exit(&ctx.job_lock)

  pool.delete_from_pool(ctx.job_pool, job)
}

remove_job_from_list :: proc(pfirst: ^^Job, plast: ^^Job, node: ^Job) {
  if node.prev != nil {
    node.prev.next = node.next
  }
  if node.next != nil {
    node.next.prev = node.prev
  }
  if (pfirst^ == node) {
    pfirst^ = node.next
  }
  if (plast^ == node) {
    plast^ = node.prev
  }
  node.next = nil
  node.prev = node.next
}

select_job :: proc(ctx: ^Job_Context, tid: int) -> (res: Selected_Job) {
  res = Selected_Job{}


  lockless.lock_enter(&ctx.job_lock)
  priority := 0
  for ; priority < int(Job_Priority.Count); priority += 1 {
    node := ctx.waiting_list[priority]
    for node != nil {
      res.waiting_list_alive = true
      if node^.wait_counter == Job_Handle(uintptr(0)) {
        if node.owner_tid == 0 || node.owner_tid == tid {
          res.job = node
          remove_job_from_list(&ctx.waiting_list[priority], &ctx.waiting_list_last[priority], node)
          priority = int(Job_Priority.Count)
          break
        }
      }
      node = node.next
    }
  }
  lockless.lock_exit(&ctx.job_lock)
  return res
}

job_selector_fn :: proc "c" (transfer: fcontext.FContext_Transfer) {
  ctx := cast(^Job_Context)transfer.data
  
  context = runtime.default_context()
  context.allocator = ctx.alloc
  
  assert(tl_thread_data != nil)

  for !ctx.quit {
    sync.semaphore_wait_for(&ctx.sem)

    j := select_job(ctx, tl_thread_data.tid)

    if j.job != nil {
      if j.job.owner_tid > 0 {
        assert(tl_thread_data.current_job == nil)
        j.job.owner_tid = 0
      }

      tl_thread_data.selector_fiber = j.job.selector_fiber
      tl_thread_data.current_job = j.job
      j.job.fiber = fcontext.jump_fcontext(j.job.fiber, j.job).ctx

      if j.job.done {
        tl_thread_data.current_job = nil
        lockless.atomic_fetch_sub32(j.job.counter, 1)
        delete_job(ctx, j.job)
      }
    } else if j.waiting_list_alive {
      sync.semaphore_post(&ctx.sem, 1)
      lockless.relax_cpu()
    }
  }

  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

main_thread_job_selector :: proc "c" (transfer: fcontext.FContext_Transfer) {
  ctx := cast(^Job_Context)transfer.data
  
  context = runtime.default_context()
  context.allocator = ctx.alloc

  assert(tl_thread_data != nil)

  j := select_job(ctx, tl_thread_data.tid)

  if j.job != nil {
    if j.job.owner_tid > 0 {
      assert(tl_thread_data.current_job == nil)
      j.job.owner_tid = 0
    }

    tl_thread_data.selector_fiber = j.job.selector_fiber
    tl_thread_data.current_job = j.job
    j.job.fiber = fcontext.jump_fcontext(j.job.fiber, j.job).ctx

    if j.job.done {
      tl_thread_data.current_job = nil
      lockless.atomic_fetch_sub32(j.job.counter, 1)
      delete_job(ctx, j.job)
    }
  }

  tl_thread_data.selector_fiber = nil
  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

destroy_job_tdata :: proc(tdata: ^Job_Thread_Data) {
  fcontext.destroy_fcontext_stack(&tdata.selector_stack)
  free(tdata)
}

create_job_tdata :: proc(tid: int, index: int, main_thread: bool) -> (res: ^Job_Thread_Data, err: error.Error) {
  res = new(Job_Thread_Data) or_return

  res.thread_index = index
  res.tid = tid
  res.main_thread = main_thread

  res.selector_stack = fcontext.create_fcontext_stack(platform.MIN_STACK_SIZE)

  return res, nil
}

job_thread_fn :: proc(ctx: ^Job_Context, index: int) {
  thread_id := sync.current_thread_id()

  td, err := create_job_tdata(thread_id, index + 1, false)
  if err != nil {
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

create_job_context :: proc(desc: ^Job_Context_Desc, alloc := context.allocator) -> (res: ^Job_Context, err: error.Error) {
  res = new(Job_Context) or_return
  res.alloc = alloc

  res.stack_size = desc.fiber_stack_size > 0 ? desc.fiber_stack_size : DEFAULT_FIBER_STACK_SIZE
  res.thread_init_cb = desc.thread_init_cb
  res.thread_shutdown_cb = desc.thread_shutdown_cb
  res.thread_user_data = desc.thread_user_data
  max_fibers := desc.max_fibers > 0 ? desc.max_fibers : DEFAULT_MAX_FIBERS

  sync.semaphore_init(&res.sem)

  if tl_thread_data, err = create_job_tdata(sync.current_thread_id(), 0, true); err != nil {
    free(res)
    return {}, err
  }
  tl_thread_data.selector_fiber = fcontext.make_fcontext(tl_thread_data.selector_stack.sptr, tl_thread_data.selector_stack.ssize, main_thread_job_selector)

  res.job_pool = pool.create_pool(size_of(Job), max_fibers) or_return
  res.counter_pool = pool.create_pool(size_of(int), COUNTER_POOL_SIZE) or_return

  num_threads := desc.num_threads > 0 ? desc.num_threads : (platform.num_cores() - 1)
  if num_threads > 0 {
    res.threads = make([]^thread.Thread, num_threads)

    for i in 0 ..< len(res.threads) {
      res.threads[i] = thread.create_and_start_with_poly_data2(res, i, job_thread_fn)
    }
  }

  return res, nil
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

  pool.destroy_pool(ctx.job_pool)
  pool.destroy_pool(ctx.counter_pool)
  sync.semaphore_destroy(&ctx.sem)

  free(ctx)
}

thread_index :: proc(ctx: ^Job_Context) -> int {
  return tl_thread_data.thread_index
}