package vfs

import "../../linchpin"

import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:thread"

VFS_Async_Read_Callback :: proc "c" (path: string, mem: ^linchpin.Mem_Block, user_data: rawptr)
VFS_Async_Write_Callback :: proc "c" (path: string, bytes_written: int, mem: ^linchpin.Mem_Block, user_data: rawptr)

VFS_Modify_Async_Callback :: proc "c" (path: string)

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

VFS_Async_Request :: struct {
  command: VFS_Async_Command,
  flags: VFS_Flags,
  path: string,
  write_mem: ^linchpin.Mem_Block,
  using rw: struct #raw_union {
    read_fn: VFS_Async_Read_Callback,
    write_fn: VFS_Async_Write_Callback,
  },
  user_data: rawptr,
}

VFS_Async_Response :: struct {
  code: VFS_Response_Code,
  using rw_mem: struct #raw_union {
    read_mem: ^linchpin.Mem_Block,
    write_mem: ^linchpin.Mem_Block,
  },
  using rw_cb: struct #raw_union {
    read_fn: VFS_Async_Read_Callback,
    write_fn: VFS_Async_Write_Callback,
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
  modify_cbs: []VFS_Modify_Async_Callback,
  worker_thread: ^thread.Thread,
  req_queue: ^linchpin.SPSC_Queue,
  res_queue: ^linchpin.SPSC_Queue,
  worker_sem: sync.Semaphore,
  quit: bool,
  dmon_queue: ^linchpin.SPSC_Queue,
}

ctx : VFS_Context

load_text_file :: proc(path: string) -> (res: ^linchpin.Mem_Block, err: bool = false) {
  handle, open_err := os.open(path)
  if open_err != os.ERROR_NONE {
    return res, err
  }
  defer os.close(handle)

  size, size_err := os.file_size(handle)
  if size_err != os.ERROR_NONE {
    return res, err
  }

  if size > 0 {
    res, mem_err := linchpin.create_mem_block(size + 1, nil, 0)
    if mem_err != nil {
      return res, err
    }
  }

  return res, true
}

load_binary_file :: proc(path: string) -> (res: ^linchpin.Mem_Block, err: bool = false) {
  return nil, false
}

resolve_path :: proc(path: string, flags: VFS_Flags) -> (res: string, resolved: bool = false) {
  if .Absolute_Path in flags {
    return filepath.clean(path), true
  } else {
    for mp in &ctx.mounts {
      if path == mp.alias {
        return filepath.join(mp.path, filepath.clean(path[len(mp.alias):])), true
      }
    }
    res = filepath.clean(path)
    return res, os.exists(res)
  }
  return "", false
}

read :: proc(path: string, flags: VFS_Flags) -> (res: ^linchpin.Mem_Block, read: bool = false) {
  resolved_path := resolve_path(path, flags) or_return
  if .Text_File in flags {
    return load_text_file(resolved_path) or_return, true
   } else {
     return load_binary_file(resolved_path) or_return, true
   } 
}

worker_thread_fn :: proc(_: ^thread.Thread) {
  for !ctx.quit {
    req : VFS_Async_Request
    if linchpin.consume_from_spsc_queue(ctx.res_queue, &req) {
      res := VFS_Async_Response{bytes_written = -1}
      res.path = req.path
      res.user_data = req.user_data

      switch req.command {
        case .Read:
          res.read_fn = req.read_fn
          mem, read := read(req.path, req.flags); if read {
            res.code = .Read_Ok
            res.read_mem = mem
          } else {
            res.code = .Read_Failed
          }
        case .Write:
          res.write_fn = req.write_fn
      }
    }
  }
}

init :: proc() -> (err: linchpin.Error = nil) {
  ctx.req_queue = linchpin.create_spsc_queue(size_of(VFS_Async_Request), 128) or_return
  ctx.res_queue = linchpin.create_spsc_queue(size_of(VFS_Async_Response), 128) or_return

  sync.semaphore_init(&ctx.worker_sem)
  ctx.worker_thread = thread.create_and_start(worker_thread_fn)

  return err
}