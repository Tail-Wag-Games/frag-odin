package vfs

import "thirdparty:dmon"

import "linchpin:error"
import "linchpin:memio"
import "linchpin:queue/spsc"

import "frag:private"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:path/slashpath"
import "core:runtime"
import "core:strings"
import "core:sync"
import "core:thread"

Vfs_Async_Read_Callback :: proc (path: string, mem: ^memio.Mem_Block, user_data: rawptr)
Vfs_Async_Write_Callback :: proc (path: string, bytes_written: int, mem: ^memio.Mem_Block, user_data: rawptr)

Vfs_Modify_Async_Callback :: proc (path: string)

Dmon_Result :: struct {
  action: dmon.Action,
  path: string,
}

Vfs_Async_Command :: enum {
  Read,
  Write,
}

Vfs_Response_Code :: enum {
  Read_Failed,
  Read_Ok,
  Write_Failed,
  Write_Ok,
}

Vfs_Flag :: enum {
  None,
  Absolute_Path,
  Text_File,
  Append,
}

Vfs_Flags :: bit_set[Vfs_Flag]

Vfs_Async_Request :: struct {
  command: Vfs_Async_Command,
  flags: Vfs_Flags,
  path: string,
  write_mem: ^memio.Mem_Block,
  using rw: struct #raw_union {
    read_fn: Vfs_Async_Read_Callback,
    write_fn: Vfs_Async_Write_Callback,
  },
  user_data: rawptr,
}

Vfs_Async_Response :: struct {
  code: Vfs_Response_Code,
  using rw_mem: struct #raw_union {
    read_mem: ^memio.Mem_Block,
    write_mem: ^memio.Mem_Block,
  },
  using rw_cb: struct #raw_union {
    read_fn: Vfs_Async_Read_Callback,
    write_fn: Vfs_Async_Write_Callback,
  },
  user_data: rawptr,
  bytes_written: int,
  path: string,
}

Vfs_Mount_Point :: struct {
  path: string,
  alias: string,
  watch_id: u32,
}

Vfs_Context :: struct {
  alloc: mem.Allocator,
  mounts: [dynamic]Vfs_Mount_Point,
  modify_cbs: []Vfs_Modify_Async_Callback,
  worker_thread: ^thread.Thread,
  req_queue: ^spsc.Queue,
  res_queue: ^spsc.Queue,
  worker_sem: sync.Semaphore,
  quit: bool,
  dmon_queue: ^spsc.Queue,
}


ctx : Vfs_Context
dmon_event_cb :: proc "c" (watch_id: dmon.Watch_Id, action: dmon.Action, rootdir: cstring, file: cstring, old_filepath: cstring, user_data: rawptr) {

  context = runtime.default_context()
  context.allocator = ctx.alloc

  #partial switch(action) {
    case .Modify: {
      r : Dmon_Result = { action = action }
      filepath_str := strings.clone_from_cstring(file, context.temp_allocator)
      abs_filepath := filepath.join(strings.clone_from_cstring(rootdir, context.temp_allocator), filepath_str)
      info, err := os.stat(abs_filepath, context.temp_allocator)
      if err != os.ERROR_NONE {
        break
      }

      if !info.is_dir && info.size > 0 {
        for mp in &ctx.mounts {
          if mp.watch_id == watch_id.id {
            r.path = mp.alias
            alias_len := len(r.path)
            r.path = filepath.clean(filepath.join(r.path, filepath_str))
            break
          }
        }

        if r.path != "" {
          spsc.produce_and_grow(ctx.dmon_queue, &r)
        }
      }
    }
  }
}

mount :: proc "c" (path: string, alias: string, watch: bool) -> error.Error {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  if os.is_dir(path) {
    mp : Vfs_Mount_Point = {
      path = filepath.clean(path, context.temp_allocator),
      alias = slashpath.clean(alias, context.temp_allocator),
    }

    if watch {
      mp.watch_id = dmon.watch(strings.clone_to_cstring(mp.path), dmon_event_cb, 0x1, nil).id
    }

    for mnt in ctx.mounts {
      if mnt.path == mp.path {
        return .Already_Mounted
      }
    }

    append(&ctx.mounts, mp)
    return nil
  } else {
    return .Directory
  }

  return nil
}


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


resolve_path :: proc(path: string, flags: Vfs_Flags) -> (res: string, err: error.Error = nil) {
  if .Absolute_Path in flags {
    return filepath.clean(path, context.temp_allocator), nil
  } else {
    for mp in &ctx.mounts {
      if path == mp.alias {
        return filepath.join(mp.path, filepath.clean(path[len(mp.alias):], context.temp_allocator)), nil
      }
    }
    res = filepath.clean(path, context.temp_allocator)
    return res, os.exists(res) ? nil : .Path_Not_Found
  }
  return "", .Path_Not_Found
}


read :: proc(path: string, flags: Vfs_Flags) -> (res: ^memio.Mem_Block, err: error.Error = nil) {
  resolved_path := resolve_path(path, flags) or_return
  if .Text_File in flags {
    return load_text_file(resolved_path) or_return, nil
   } else {
     return load_binary_file(resolved_path) or_return, nil
   } 
}


worker_thread_fn :: proc(_: ^thread.Thread) {
  for !ctx.quit {
    req : Vfs_Async_Request
    if spsc.consume(ctx.res_queue, &req) {
      res := Vfs_Async_Response{bytes_written = -1}
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

init :: proc(alloc := context.allocator) -> (err: error.Error = nil) {
  ctx.alloc = alloc

  ctx.req_queue = spsc.create(size_of(Vfs_Async_Request), 128) or_return
  ctx.res_queue = spsc.create(size_of(Vfs_Async_Response), 128) or_return

  sync.semaphore_init(&ctx.worker_sem)
  ctx.worker_thread = thread.create_and_start(worker_thread_fn)

  dmon.init()
  ctx.dmon_queue = spsc.create(size_of(Dmon_Result), 128) or_return

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
    spsc.destroy(ctx.req_queue)
  }
  if ctx.res_queue != nil {
    spsc.destroy(ctx.res_queue)
  }

  dmon.deinit()

  if ctx.dmon_queue != nil {
    spsc.destroy(ctx.dmon_queue)
  }
}

@(init, private)
init_vfs_api :: proc() {
  private.vfs_api = {
    mount = mount,
  }
}
