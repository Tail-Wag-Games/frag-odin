package vfs

import "linchpin:error"
import "linchpin:memio"
import "linchpin:queue"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:thread"

VFS_Async_Read_Callback :: proc (path: string, mem: ^memio.Mem_Block, user_data: rawptr)
VFS_Async_Write_Callback :: proc (path: string, bytes_written: int, mem: ^memio.Mem_Block, user_data: rawptr)

VFS_Modify_Async_Callback :: proc (path: string)

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
  write_mem: ^memio.Mem_Block,
  using rw: struct #raw_union {
    read_fn: VFS_Async_Read_Callback,
    write_fn: VFS_Async_Write_Callback,
  },
  user_data: rawptr,
}

VFS_Async_Response :: struct {
  code: VFS_Response_Code,
  using rw_mem: struct #raw_union {
    read_mem: ^memio.Mem_Block,
    write_mem: ^memio.Mem_Block,
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
  req_queue: ^queue.SPSC_Queue,
  res_queue: ^queue.SPSC_Queue,
  worker_sem: sync.Semaphore,
  quit: bool,
  dmon_queue: ^queue.SPSC_Queue,
}


ctx : VFS_Context


load_text_file :: proc(path: string) -> (res: ^memio.Mem_Block, err: error.Error = nil) {
  handle, open_err := os.open(path)
  if open_err != os.ERROR_NONE {
    return res, .None
  }

  size, size_err := os.file_size(handle)
  if size_err != os.ERROR_NONE && size > 0 {
    res = memio.create_mem_block(size + 1, nil, 0) or_return
    os.read_ptr(handle, res.data, int(size))
    os.close(handle)
    (cast([^]rune)res.data)[size] = rune(0)
    return res, nil
  }

  os.close(handle)

  return res, .None
}


load_binary_file :: proc(path: string) -> (res: ^memio.Mem_Block, err: error.Error = nil) {
   handle, open_err := os.open(path)
  if open_err != os.ERROR_NONE {
    return res, .None
  }
  defer os.close(handle)

  size, size_err := os.file_size(handle)
  if size_err != os.ERROR_NONE {
    return res, .None
  }

  if size > 0 {
    res, mem_err := memio.create_mem_block(size, nil, 0)
    if mem_err != nil {
      return res, .None
    }
    res = memio.create_mem_block(size, nil, 0) or_return
    os.read_ptr(handle, res.data, int(size))
    os.close(handle)
    return res, nil
  }

  return res, .None
}


resolve_path :: proc(path: string, flags: VFS_Flags) -> (res: string, err: error.Error = nil) {
  if .Absolute_Path in flags {
    return filepath.clean(path), nil
  } else {
    for mp in &ctx.mounts {
      if path == mp.alias {
        return filepath.join(mp.path, filepath.clean(path[len(mp.alias):])), nil
      }
    }
    res = filepath.clean(path)
    return res, os.exists(res) ? nil : .Path_Not_Found
  }
  return "", .Path_Not_Found
}


read :: proc(path: string, flags: VFS_Flags) -> (res: ^memio.Mem_Block, err: error.Error = nil) {
  resolved_path := resolve_path(path, flags) or_return
  if .Text_File in flags {
    return load_text_file(resolved_path) or_return, nil
   } else {
     return load_binary_file(resolved_path) or_return, nil
   } 
}


worker_thread_fn :: proc(_: ^thread.Thread) {
  for !ctx.quit {
    req : VFS_Async_Request
    if queue.consume_from_spsc_queue(ctx.res_queue, &req) {
      res := VFS_Async_Response{bytes_written = -1}
      res.path = req.path
      res.user_data = req.user_data

      switch req.command {
        case .Read:
          res.read_fn = req.read_fn
          mem, err := read(req.path, req.flags); if err == .None {
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

init :: proc() -> (err: error.Error = nil) {
  ctx.req_queue = queue.create_spsc_queue(size_of(VFS_Async_Request), 128) or_return
  ctx.res_queue = queue.create_spsc_queue(size_of(VFS_Async_Response), 128) or_return

  sync.semaphore_init(&ctx.worker_sem)
  ctx.worker_thread = thread.create_and_start(worker_thread_fn)

  return err
}


shutdown :: proc() {
  if ctx.worker_thread != nil {
    ctx.quit = true
    sync.semaphore_post(&ctx.worker_sem)
    thread.destroy(ctx.worker_thread)
    sync.semaphore_destroy(&ctx.worker_sem)
  }
  
  if ctx.req_queue != nil {
    queue.destroy_spsc_queue(ctx.req_queue)
  }
  if ctx.res_queue != nil {
    queue.destroy_spsc_queue(ctx.res_queue)
  }
}