package vfs

import "../../linchpin"

import "core:sync"
import "core:thread"

Async_Read_Callback :: proc "c" (path: string, mem: ^linchpin.Mem_Block, user_data: rawptr)
Async_Write_Callback :: proc "c" (path: string, bytes_written: int, mem: ^linchpin.Mem_Block, user_data: rawptr)

Modify_Async_Callback :: proc "c" (path: string)

VFS_Async_Command :: enum {
  Read,
  Write,
}

VFS_Response_Code :: enum {
  Read_Failed,
  Read_Ok,
  Write_Failed,
  Write_Ok,
}

VFS_Flag :: enum {
  None,
  Absolute_Path,
  Text_File,
  Append,
}

VFS_Flags :: bit_set[VFS_Flag]

Async_Request :: struct {
  command: VFS_Async_Command,
  flags: VFS_Flags,
  path: string,
  write_mem: ^linchpin.Mem_Block,
  using rw: struct #raw_union {
    read_fn: Async_Read_Callback,
    write_fn: Async_Write_Callback,
  },
  user_data: rawptr,
}

Async_Response :: struct {
  code: VFS_Response_Code,
  using rw_mem: struct #raw_union {
    read_mem: ^linchpin.Mem_Block,
    write_mem: ^linchpin.Mem_Block,
  },
  using rw_cb: struct #raw_union {
    read_fn: Async_Read_Callback,
    write_fn: Async_Write_Callback,
  },
  user_data: rawptr,
  bytes_written: int,
  path: string,
}

VFS_Mount_Point :: struct {
  path: string,
  alias: string,
  watch_id: u32,
}

VFS_Context :: struct {
  mounts: []VFS_Mount_Point,
  modify_cbs: []Modify_Async_Callback,
  worker_thread: ^thread.Thread,
  req_queue: ^linchpin.SPSC_Queue,
  res_queue: ^linchpin.SPSC_Queue,
  worker_sem: sync.Semaphore,
  quit: bool,
  dmon_queue: ^linchpin.SPSC_Queue,
}

ctx : VFS_Context

worker_thread_fn :: proc(_: ^thread.Thread) {
  for !ctx.quit {
    req : Async_Request
    if linchpin.consume_from_spsc_queue(ctx.res_queue, &req) {

    }
  }
}

init :: proc() -> (err: linchpin.Error = nil) {
  ctx.req_queue = linchpin.create_spsc_queue(size_of(Async_Request), 128) or_return
  ctx.res_queue = linchpin.create_spsc_queue(size_of(Async_Response), 128) or_return

  sync.semaphore_init(&ctx.worker_sem)
  ctx.worker_thread = thread.create_and_start(worker_thread_fn)

  return err
}