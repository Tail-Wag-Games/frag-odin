package vfs

import "thirdparty:dmon"

import "linchpin:error"
import "linchpin:memio"
import "linchpin:queue/spsc"

import "frag:api"
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

Dmon_Result :: struct {
  action: dmon.Action,
  path: string,
}

Async_Command :: enum {
  Read,
  Write,
}

Response_Code :: enum {
  Read_Failed,
  Read_Ok,
  Write_Failed,
  Write_Ok,
}

Async_Request :: struct {
  cmd: Async_Command,
  flags: api.Vfs_Flags,
  path: string,
  write_mem: ^memio.Mem_Block,
  using rw_cb: struct #raw_union {
    read_fn: api.Async_Read_Callback,
    write_fn: api.Async_Write_Callback,
  },
  user: rawptr,
}

Async_Response :: struct {
  code: Response_Code,
  using rw_mem: struct #raw_union {
    read_mem: ^memio.Mem_Block,
    write_mem: ^memio.Mem_Block,
  },
  using rw_cb: struct #raw_union {
    read_fn: api.Async_Read_Callback,
    write_fn: api.Async_Write_Callback,
  },
  user: rawptr,
  bytes_written: int,
  path: string,
}

Mount_Point :: struct {
  path: string,
  alias: string,
  watch_id: u32,
}

Context :: struct {
  alloc: mem.Allocator,
  mounts: [dynamic]Mount_Point,
  modify_cbs: [dynamic]proc "c" (path: cstring),
  worker_thread: ^thread.Thread,
  req_queue: ^spsc.Queue,
  res_queue: ^spsc.Queue,
  worker_sem: sync.Semaphore,
  quit: bool,
  dmon_queue: ^spsc.Queue,
}

ctx : Context

dmon_event_cb :: proc "c" (watch_id: dmon.Watch_Id, action: dmon.Action, rootdir: cstring, file: cstring, old_filepath: cstring, user: rawptr) {
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

register_modify_cb :: proc "c" (modify_cb: proc "c" (path: cstring)) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  assert(modify_cb != nil)
  append(&ctx.modify_cbs, modify_cb)
}

mount :: proc "c" (path: cstring, alias: cstring, watch: bool) -> error.Error {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  path_str := string(path)
  alias_str := string(alias)

  if os.is_dir(path_str) {
    mp : Mount_Point = {
      path = filepath.clean(path_str, context.temp_allocator),
      alias = slashpath.clean(alias_str, context.temp_allocator),
    }

    if watch {
      mp.watch_id = dmon.watch(strings.clone_to_cstring(mp.path, context.temp_allocator), dmon_event_cb, 0x1, nil).id
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
    res = memio.create_block(size + 1, nil, 0) or_return
    os.read_ptr(handle, res.data, int(size))
    os.close(handle)
    (cast([^]rune)res.data)[size] = rune(0)
    return res, nil
  }

  os.close(handle)

  return res, .None
}


load_binary_file :: proc(path: string) -> (^memio.Mem_Block, error.Error) {
  handle, open_err := os.open(path)
  if open_err != os.ERROR_NONE {
    return nil, .None
  }
  defer os.close(handle)

  size, size_err := os.file_size(handle)
  if size_err != os.ERROR_NONE {
    return nil, .None
  }

  if size > 0 {
    res, mem_err := memio.create_block(size, nil, 0)
    if mem_err != nil {
      return nil, .None
    }
    
    read, err := os.read_ptr(handle, res.data, int(size))
    if bool(err) {
      return nil, .None
    }
    return res, nil
  }

  return nil, .None
}


resolve_path :: proc(path: string, flags: api.Vfs_Flags) -> (res: string, err: error.Error = nil) {
  if bool(flags & api.VFS_FLAG_ABSOLUTE_PATH) {
    return filepath.clean(path, context.temp_allocator), nil
  } else {
    for mp in &ctx.mounts {
      if strings.contains(path, mp.alias) {
        return filepath.join(mp.path, filepath.clean(path[len(mp.alias):], context.temp_allocator)), nil
      }
    }
    res = filepath.clean(path, context.temp_allocator)
    return res, os.exists(res) ? nil : .Path_Not_Found
  }
  return "", .Path_Not_Found
}


read_file :: proc(path: string, flags: api.Vfs_Flags) -> (res: ^memio.Mem_Block, err: error.Error = nil) {
  resolved_path := resolve_path(path, flags) or_return
  if bool(flags & api.VFS_FLAG_TEXT_FILE) {
    return load_text_file(resolved_path) or_return, nil
   } else {
     return load_binary_file(resolved_path) or_return, nil
   } 
}

read :: proc "c" (path: cstring, flags: api.Vfs_Flags) -> ^memio.Mem_Block {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  res, err := read_file(strings.clone_from_cstring(path, context.temp_allocator), flags)
  if err != nil {
    return nil
  }

  return res
}

read_async :: proc "c" (path: cstring, flags: api.Vfs_Flags, read_fn: api.Async_Read_Callback, user: rawptr) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  req := Async_Request {
    cmd = .Read,
    flags = flags,
    user = user,
    path = strings.clone_from_cstring(path, context.temp_allocator),
  }
  req.rw_cb.read_fn = read_fn
  spsc.produce_and_grow(ctx.req_queue, &req)
  sync.semaphore_post(&ctx.worker_sem, 1)
}

worker_thread_fn :: proc(_: ^thread.Thread) {
  for !ctx.quit {
    req : Async_Request
    if spsc.consume(ctx.req_queue, &req) {
      res := Async_Response{bytes_written = -1}
      res.path = req.path
      res.user = req.user

      switch req.cmd {
        case .Read:
          res.read_fn = req.read_fn
          mem, err := read_file(req.path, req.flags); if err == nil {
            res.code = .Read_Ok
            res.read_mem = mem
          } else {
            res.code = .Read_Failed
          }
          spsc.produce_and_grow(ctx.res_queue, &res)
        case .Write:
          res.write_fn = req.write_fn
      }
    }
    sync.semaphore_wait_for(&ctx.worker_sem)
  }
}

update :: proc() {
  res : Async_Response
  for spsc.consume(ctx.res_queue, &res) {
    switch res.code {
      case .Read_Ok, .Read_Failed: {
        res.read_fn(strings.clone_to_cstring(res.path, context.temp_allocator), res.read_mem, res.user)
      }
      case .Write_Ok, .Write_Failed: {
        res.write_fn(strings.clone_to_cstring(res.path, context.temp_allocator), i32(res.bytes_written), res.write_mem, res.user)
      }
    }
  }

  dmon_res: Dmon_Result
  for spsc.consume(ctx.dmon_queue, &dmon_res) {
    if dmon_res.action == .Modify {
      for i in 0 ..< len(ctx.modify_cbs) {
        ctx.modify_cbs[i](strings.clone_to_cstring(dmon_res.path, context.temp_allocator))
      }
    }
  }
}

init :: proc(alloc := context.allocator) -> (err: error.Error = nil) {
  ctx.alloc = alloc

  ctx.req_queue = spsc.create(size_of(Async_Request), 128) or_return
  ctx.res_queue = spsc.create(size_of(Async_Response), 128) or_return

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
    register_modify_cb = register_modify_cb,
    read_async = read_async,
    read = read,
  }
}
