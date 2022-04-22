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

Job_Callback :: proc "c" (range_start: i32, range_end: i32, thread_index: i32, user_data: rawptr)
Job_Thread_Init_Callback :: proc (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)
Job_Thread_Shutdown_Callback :: proc (ctx: ^Job_Context, thread_index: int, thread_id: int, user_data: rawptr)

Job_Handle :: ^u32

Job_Priority :: enum i32 {
  High,
  Normal,
  Low,
  Count,
}

Job :: struct {
  job_index: int,
  done: bool,
  owner_tid: int,
  tags: u32,
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

Pending_Job :: struct {
  counter: Job_Handle,
  range_size: int,
  range_remainder: int,
  callback: Job_Callback,
  user: rawptr,
  priority: Job_Priority,
  tags: u32,
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
  tags: u32,
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
  tags: []u32,
  job_lock: lockless.Spinlock,
  counter_lock: lockless.Spinlock,
  dummy_counter: lockless.atomic_u32,
  sem: sync.Sema,
  quit: bool,
  thread_init_cb: Job_Thread_Init_Callback,
  thread_shutdown_cb: Job_Thread_Shutdown_Callback,
  thread_user_data: rawptr,
  pending: [dynamic]Pending_Job,
}

COUNTER_POOL_SIZE :: 256
DEFAULT_MAX_FIBERS :: 64
DEFAULT_FIBER_STACK_SIZE :: 1048576    // 1MB

@(private, thread_local)
tl_thread_data: ^Job_Thread_Data

fiber_fn :: proc "c" (transfer: fcontext.FContext_Transfer) {
  job := cast(^Job)transfer.data
  ctx := job.ctx

  context = runtime.default_context()
  context.allocator = ctx.alloc

  assert(tl_thread_data.current_job == job)

  job.selector_fiber = transfer.ctx
  tl_thread_data.selector_fiber = transfer.ctx
  tl_thread_data.current_job = job

  job.callback(i32(job.range_start), i32(job.range_end), i32(tl_thread_data.thread_index), job.user_data)
  job.done = true

  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

new_job :: proc(ctx: ^Job_Context, index: int, callback: Job_Callback, user: rawptr, range_start: int, range_end: int, counter: Job_Handle, tags: u32, priority: Job_Priority) -> ^Job {
  j := cast(^Job)pool.fetch_from(ctx.job_pool)

  if j != nil {
    j.job_index = index
    j.owner_tid = 0
    j.tags = tags
    j.done = false
    if j.stack_mem.sptr == nil {
      j.stack_mem = fcontext.create_fcontext_stack(uint(ctx.stack_size))
    }
    j.fiber = fcontext.make_fcontext(j.stack_mem.sptr, j.stack_mem.ssize, fiber_fn)
    j.counter = counter
    j.wait_counter = transmute(Job_Handle)&ctx.dummy_counter
    j.ctx = ctx
    j.callback = callback
    j.user_data = user
    j.range_start = range_start
    j.range_end = range_end
    j.priority = priority
    j.prev = nil
    j.next = j.prev
  }
  fmt.println(j)
  return j
}

add_job_to_list :: proc(pfirst: ^^Job, plast: ^^Job, node: ^Job) {
  if plast^ != nil {
    plast^.next = node
    node.prev = plast^
  }
  plast^ = node
  if pfirst^ == nil {
    pfirst^ = node
  }
}

process_pending :: proc(ctx: ^Job_Context) {
  for pending, i in &ctx.pending {
    fmt.println(i32(lockless.atomic_load32_explicit(transmute(^u32)pending.counter, .Acquire)))
    if !pool.is_full_n(ctx.job_pool, i32(lockless.atomic_load32_explicit(transmute(^u32)pending.counter, .Acquire))) {
      range_start := 0
      range_end := pending.range_size + (pending.range_remainder > 0 ? 1 : 0)
      pending.range_remainder -= 1

      ordered_remove(&ctx.pending, i)

      count := pending.counter^
      for k in 0 ..< count {
        add_job_to_list(&ctx.waiting_list[pending.priority], &ctx.waiting_list_last[pending.priority],
                        new_job(ctx, int(k), pending.callback, pending.user, range_start, range_end,
                        pending.counter, pending.tags, pending.priority))
      }
    }
  }
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

delete_job :: proc(ctx: ^Job_Context, job: ^Job) {
  lockless.lock_enter(&ctx.job_lock)
  pool.delete_from(ctx.job_pool, job)
  lockless.lock_exit(&ctx.job_lock)
}

test_and_del_job :: proc(ctx: ^Job_Context, job: Job_Handle) -> bool {
  if lockless.atomic_load32_explicit(transmute(^u32)job, .Acquire) == 0 {
    lockless.lock_enter(&ctx.counter_lock)
    pool.delete_from(ctx.counter_pool, cast(rawptr)job)
    lockless.lock_exit(&ctx.counter_lock)

    lockless.lock_enter(&ctx.job_lock)
    process_pending(ctx)
    lockless.lock_exit(&ctx.counter_lock)
    return true
  }
  return false
}

select_job :: proc(ctx: ^Job_Context, tid: int) -> (res: Selected_Job) {
  res = Selected_Job{}


  lockless.lock_enter(&ctx.job_lock)
  priority := 0
  for ; priority < int(Job_Priority.Count); priority += 1 {
    node := ctx.waiting_list[priority]
    for node != nil {
      res.waiting_list_alive = true
      if node.wait_counter^ == 0 {
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
    sync.sema_wait(&ctx.sem)

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
      sync.sema_post(&ctx.sem, 1)
      lockless.relax_cpu()
    }
  }

  fcontext.jump_fcontext(transfer.ctx, transfer.data)
}

dispatch :: proc(ctx: ^Job_Context, count: i32, callback: Job_Callback, user: rawptr, priority: Job_Priority, tags: u32) -> Job_Handle {
  assert(count > 0)

  num_workers := 0
  if tags != 0 {
    for i in 0 ..< len(ctx.threads) + 1 {
      if bool(ctx.tags[i] & tags) {
        num_workers += 1
      }
    }
  } else {
    num_workers = len(ctx.threads) + 1
  }

  range_size := int(count) / num_workers
  range_remainder := int(count) % num_workers
  num_jobs := range_size > 0 ? num_workers : (range_remainder > 0 ? range_remainder : 0)
  assert(num_jobs > 0)
  assert(num_jobs <= ctx.job_pool.capacity, "exceeded max configured number of jobs - update configuration settings")

  counter : Job_Handle
  lockless.lock_enter(&ctx.counter_lock)
  counter = cast(Job_Handle)pool.new_and_grow(ctx.counter_pool)
  lockless.lock_exit(&ctx.counter_lock)

  if counter == nil {
    assert(false, "exceeded maximum number of job instances")
    return nil
  }

  lockless.atomic_store32_explicit(transmute(^u32)counter, u32(num_jobs), .Release)
  assert(tl_thread_data != nil, "dispatch must be called from the main thread or another job worker thread")

  if tl_thread_data.current_job != nil {
    tl_thread_data.current_job.wait_counter = counter
  }

  lockless.lock_enter(&ctx.job_lock)
  if !pool.is_full_n(ctx.job_pool, num_jobs) {
    range_start := 0
    range_end := range_size + (range_remainder > 0 ? 1 : 0)
    range_remainder -= 1

    for i in 0 ..< num_jobs {
      add_job_to_list(&ctx.waiting_list[priority], &ctx.waiting_list_last[priority],
        new_job(ctx, i, callback, user, range_start, range_end, counter, tags, priority))
      
      range_start = range_end
      range_end += (range_size + (range_remainder > 0 ? 1 : 0))
      range_remainder -= 1
    }
    assert(range_remainder <= 0)

    sync.sema_post(&ctx.sem, num_jobs)
  } else {
    pending := Pending_Job {
      counter = counter,
      range_size = range_size,
      range_remainder = range_remainder,
      callback = callback,
      user = user,
      priority = priority,
      tags = tags,
    }
    append(&ctx.pending, pending)
  }
  lockless.lock_exit(&ctx.job_lock)

  return counter
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
  mem.zero(res, size_of(Job_Thread_Data))

  res.thread_index = index
  res.tid = tid
  res.tags = 0xffffffff
  res.main_thread = main_thread

  res.selector_stack = fcontext.create_fcontext_stack(platform.MIN_STACK_SIZE)
  assert(res != nil)

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
  sync.sema_post(&ctx.sem, len(ctx.threads) + 1)

  for t in ctx.threads {
    thread.destroy(t)
  }
  delete(ctx.threads)

  destroy_job_tdata(tl_thread_data)

  pool.destroy_pool(ctx.job_pool)
  pool.destroy_pool(ctx.counter_pool)

  free(ctx)
}

thread_index :: proc(ctx: ^Job_Context) -> int {
  return tl_thread_data.thread_index
}