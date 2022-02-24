package asset

import "thirdparty:lockless"

import "linchpin:handle"
import "linchpin:job"
import "linchpin:memio"

import "frag:api"
import "frag:private"

import "core:bytes"
import "core:fmt"
import "core:hash"
import "core:hash/xxhash"
import "core:io"
import "core:mem"
import "core:path/filepath"
import "core:path/slashpath"
import "core:runtime"
import "core:strings"

make_four_cc :: proc(a, b, c, d: rune) -> u32 {
  return ((u32(a) | (u32(b) << 8) | (u32(c) << 16) | (u32(d) << 24)))
}

ASSET_FLAG := make_four_cc('F', 'R', 'A', 'G')

Asset_Job_State :: enum i32 {
  Spawn,
  Failed,
  Success,
}

Async_Asset_Job :: struct {
  load_data: api.Asset_Load_Data,
  mem_block: ^memio.Mem_Block,
  mgr: ^Asset_Manager,
  load_params: api.Asset_Load_Params,
  job: job.Job_Handle,
  state: Asset_Job_State,
  asset: api.Asset_Handle,
  next: ^Async_Asset_Job,
  prev: ^Async_Asset_Job,
}

Async_Asset_Load_Req :: struct {
  path_hash : u32,
  asset: api.Asset_Handle,
}

Asset_Resource :: struct {
  path: string,
  real_path: string,
  path_hash: u32,
  last_modified: u64,
  asset_mgr_id: int,
  used: bool,
}

Asset :: struct {
  handle: handle.Handle,
  params_id: u32,
  resource_id: u32,
  asset_mgr_id: int,
  ref_count: int,
  obj: api.Asset_Object,
  dead_obj: api.Asset_Object,
  hash: u32,
  tags: u32,
  load_flags: api.Asset_Load_Flags,
  state: api.Asset_State,
}

Asset_Manager :: struct {
  name: string,
  callbacks: api.Asset_Callbacks,
  name_hash: u32,
  params_size: int,
  params_type_name: string,
  failed_obj: api.Asset_Object,
  async_obj: api.Asset_Object,
  params_buff: [dynamic]u8,
  forced_flags: api.Asset_Load_Flags,
}

Asset_Context :: struct {
  alloc: mem.Allocator,
  asset_managers: [dynamic]Asset_Manager,
  asset_name_hashes: [dynamic]u32,
  assets: [dynamic]Asset,
  asset_handles: ^handle.Handle_Pool,
  asset_tbl: map[u32]api.Asset_Handle,
  resource_tbl: map[u32]int,
  resources: [dynamic]Asset_Resource,
  async_reqs: [dynamic]Async_Asset_Load_Req,
  assets_lock: lockless.Spinlock,
}


ctx := Asset_Context{}

find_async_req :: proc(path: string) -> int {
  path_hash := hash.fnv32a(transmute([]u8)path)
  for req, i in ctx.async_reqs {
    if req.path_hash == path_hash {
      return i
    }
  }
  return -1
}

on_asset_modified :: proc "c" (path: cstring) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  unix_path := slashpath.clean(strings.clone_from_cstring(path, context.temp_allocator))
}

asset_load_job_cb :: proc "c" (start, end, thread_idx: i32, user: rawptr) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  ajob := cast(^Async_Asset_Job)user

  ajob.state = ajob.mgr.callbacks.on_load(&ajob.load_data, &ajob.load_params, ajob.mem_block) ? .Success : .Failed
}

on_asset_read :: proc "c" (path: cstring, mb: ^memio.Mem_Block, user: rawptr) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  spath := strings.clone_from_cstring(path, context.temp_allocator)
  async_req_idx := find_async_req(spath)

  if mb == nil {
    if async_req_idx != -1 {
      req := &ctx.async_reqs[async_req_idx]
      asset := req.asset
      a := &ctx.assets[handle.index_handle(asset.id)]
      assert(bool(a.resource_id))
      res := &ctx.resources[api.to_index(a.resource_id)]
      mgr := &ctx.asset_managers[a.asset_mgr_id]

      fmt.println("warn: failed loading asset: %s", res.path)
      a.state = .Failed
      a.obj = mgr.failed_obj
    }
    return
  } else if async_req_idx == -1 {
    memio.destroy_block(mb)
    return
  }

  req := &ctx.async_reqs[async_req_idx]
  asset := req.asset
  a := &ctx.assets[handle.index_handle(asset.id)]
  assert(bool(a.resource_id))
  res := &ctx.resources[api.to_index(a.resource_id)]
  mgr := &ctx.asset_managers[a.asset_mgr_id]

  params_ptr : rawptr = nil
  if bool(a.params_id) {
    params_ptr = &mgr.params_buff[api.to_index(a.params_id)]
  }
  load_params := api.Asset_Load_Params {
    path = strings.clone_to_cstring(res.path, context.temp_allocator),
    params = params_ptr,
    tags = a.tags,
    flags = a.load_flags,
  }

  metas : []api.Asset_Meta_Key_Val
  fixed_path := check_and_fix_asset_type(mb, spath, &load_params.num_meta)
  is_path_fixed := bool(len(fixed_path))
  if is_path_fixed {
    load_params.path = strings.clone_to_cstring(fixed_path, context.temp_allocator)
    if load_params.num_meta > 0 {
      assert(load_params.num_meta < 64)
      metas = make([]api.Asset_Meta_Key_Val, load_params.num_meta)
      mem.copy(&metas[0], mb.data, int(size_of(api.Asset_Meta_Key_Val) * load_params.num_meta))
      load_params.metas = transmute([^]api.Asset_Meta_Key_Val)&metas[0]
    }
  }

  load_data := mgr.callbacks.on_prepare(&load_params, mb)
  ordered_remove(&ctx.async_reqs, async_req_idx)
  if !bool(load_data.obj.id) {
    fmt.println("error: failed preparing asset")
    memio.destroy_block(mb)
    return
  }

  buff := &make([]u8, size_of(Async_Asset_Job) + mgr.params_size + api.MAX_PATH + size_of(api.Asset_Meta_Key_Val) * int(load_params.num_meta))[0]

  ajob := cast(^Async_Asset_Job)buff
  buff = mem.ptr_offset(buff, size_of(Async_Asset_Job))
  load_params.path = cast(cstring)buff
  if is_path_fixed {
    mem.copy(buff, raw_data(fixed_path), len(fixed_path))
  } else {
    mem.copy(buff, raw_data(res.path), len(res.path))
  }
  buff = mem.ptr_offset(buff, api.MAX_PATH)
  
  if bool(load_params.num_meta) {
    assert(uintptr(buff) % 8 == 0)
    load_params.metas = cast([^]api.Asset_Meta_Key_Val)buff
    mem.copy(buff, &metas[0], size_of(api.Asset_Meta_Key_Val) * int(load_params.num_meta))
    buff = mem.ptr_offset(buff, size_of(api.Asset_Meta_Key_Val) * int(load_params.num_meta))
  }

  if params_ptr != nil {
    assert(uintptr(buff) % 8 == 0)
    load_params.params = buff
    mem.copy(buff, params_ptr, mgr.params_size)
  }

  ajob^ = {
    load_data = load_data,
    mem_block = mb, mgr = mgr,
    load_params = load_params,
    asset = asset,
  }

  ajob.job = private.core_api.dispatch_job(1, asset_load_job_cb, ajob, .High, 0)


  // a = &ctx.assets[handle.index_handle(asset.id)]
  // if bool(load_data.obj.id) {
  //   if mgr.callbacks.on_load(&load_data, &load_params, mb) {
  //     mgr.callbacks.on_finalize(&load_data, &load_params, mb)
  //     success = true
  //   }
  // }

  // memio.destroy_block(mb)
  // if success {
  //   a.state = .Ok
  //   a.obj = load_data.obj
  // } else {
  //   if bool(load_data.obj.id) {
  //     mgr.callbacks.on_release(load_data.obj)
  //     fmt.println("error during loading of asset")
  //     if bool(a.obj.id) && !bool(a.dead_obj.id) {
  //       a.state = .Failed
  //     } else {
  //       a.obj = a.dead_obj
  //       a.dead_obj = { id = 0 }
  //     }
  //   }
  // }

  // if bool(flags & ASSET_LOAD_FLAG_RELOAD) {
  //   mgr.callbacks.on_reload(asset, a.dead_obj)
  //   if bool(a.dead_obj.id) {
  //     mgr.callbacks.on_release(a.ead_obj)
  //     a.dead_obj = { id = 0 }
  //   }
  // }

  // return asset
}

check_and_fix_asset_type :: proc(mb: ^memio.Mem_Block, asset_path: string, num_meta: ^u32) -> string {
  if mb.size < 4 {
    return ""
  }

  byte_reader : bytes.Reader
  bytes.reader_init(&byte_reader, mem.byte_slice(mb.data, int(mb.size)))
  reader, _ := io.to_reader(bytes.reader_to_stream(&byte_reader))

  flag : u32
  io.read_ptr(reader, &flag, size_of(flag))
  if flag != ASSET_FLAG {
    return ""
  }

  ext_bytes : [5]u8
  bytes, _ := io.read_ptr(reader, &ext_bytes[0], 4)
  assert(bytes == 4, fmt.tprintf("invalid _frag_ header for asset : %s", asset_path))
  ext := strings.clone_from_bytes(ext_bytes[:], context.temp_allocator)

  dir, file := filepath.split(asset_path)
  path_ext := filepath.ext(file)

  if ext[0] != '.' {
    file = strings.concatenate({file, "."}, context.temp_allocator)
  }
  file = strings.concatenate({file, ext}, context.temp_allocator)

  bytes, _ = io.read_ptr(reader, num_meta, size_of(u32))
  assert(bytes == size_of(u32), fmt.tprintf("invalid _rizz_ header for asset: %s", asset_path))

  memio.add_offset(mb, byte_reader.i)

  return file
}

register_asset_type :: proc "c" (name: cstring, callbacks: api.Asset_Callbacks, params_type_name: cstring, params_size: i32) {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  params_type_name_str := strings.clone_from_cstring(params_type_name, context.temp_allocator)
  name_str := strings.clone_from_cstring(name, context.temp_allocator)
  name_hash := hash.fnv32a(transmute([]u8)name_str)

  for asset_name_hash in ctx.asset_name_hashes {
    if name_hash == asset_name_hash {
      assert(false, fmt.tprintf("asset with name: %s - already registered", name))
    }
  }

  append(&ctx.asset_managers, Asset_Manager{
    name = name_str,
    name_hash = name_hash,
    callbacks = callbacks,
    params_size = int(params_size),
    params_type_name = params_type_name_str,
  })
  append(&ctx.asset_name_hashes, name_hash)
}

hash_asset :: proc(path: string, params: rawptr, params_size: int) -> u32 {
  state, _ := xxhash.XXH32_create_state()
  xxhash.XXH32_update(state, mem.byte_slice(raw_data(path), len(path)))
  if params_size > 0 {
    xxhash.XXH32_update(state, mem.byte_slice(params, params_size))
  }
  return xxhash.XXH32_digest(state)
}

find_asset_manager_id :: proc(name_hash: u32) -> int {
  for i in 0 ..< len(ctx.asset_name_hashes) {
    if ctx.asset_name_hashes[i] == name_hash {
      return i
    }
  }
  return -1
}

create_new_asset :: proc(path: string, params: rawptr, obj: api.Asset_Object, name_hash: u32, flags: api.Asset_Load_Flags, tags: u32) -> api.Asset_Handle {
  mgr_id := find_asset_manager_id(name_hash)
  assert(mgr_id != -1, "asset type must be registered first")
  mgr := &ctx.asset_managers[mgr_id]

  path_hash := hash.fnv32a(transmute([]u8)path)
  res_idx, ok := ctx.resource_tbl[path_hash]
  if !ok {
    res := Asset_Resource { used = true, path = path, real_path = path, path_hash = path_hash, asset_mgr_id = mgr_id }

    res_idx := len(ctx.resources)
    append(&ctx.resources, res)
    ctx.resource_tbl[path_hash] = res_idx
  } else {
    ctx.resources[res_idx].used = true
  }

  params_size := mgr.params_size
  params_id := u32(0)
  if params_size > 0 {
    params_id = api.to_id(len(mgr.params_buff))
    resize(&mgr.params_buff, params_size)
    append_elems(&mgr.params_buff, ..mem.byte_slice(params, params_size))
  }

  hnd := handle.new_handle_and_grow_pool(&ctx.asset_handles)
  assert(bool(hnd))

  asset := Asset {
    handle = hnd,
    params_id = params_id,
    resource_id = api.to_id(res_idx),
    asset_mgr_id = mgr_id,
    ref_count = 1,
    obj = obj,
    hash = hash_asset(path, params, params_size),
    tags = tags,
    load_flags = flags,
    state = .Zombie,
  }

  idx := handle.index_handle(hnd)
  lockless.lock_enter(&ctx.assets_lock)
  if idx >= len(ctx.assets) {
    append(&ctx.assets, asset)
  } else {
    ctx.assets[idx] = asset
  }

  ctx.asset_tbl[asset.hash] = {hnd}

  return { hnd }
}

add_asset :: proc(path: string, params: rawptr, obj: api.Asset_Object, name_hash: u32, flags: api.Asset_Load_Flags, tags: u32, override_asset: api.Asset_Handle) -> api.Asset_Handle {
  res := override_asset
  if bool(res.id) {
    assert(flags & api.ASSET_LOAD_FLAG_RELOAD != 0)

    a := &ctx.assets[handle.index_handle(res.id)]
    mgr := &ctx.asset_managers[a.asset_mgr_id]

    assert(a.handle == res.id)
    if a.state == .Ok {
      a.dead_obj = a.obj
    }
    a.obj = obj
    if mgr.params_size > 0 {
      assert(bool(a.params_id))
      mem.copy(&mgr.params_buff[api.to_index(a.params_id)], params, mgr.params_size)
    }
  } else {
    res = create_new_asset(path, params, obj, name_hash, flags, tags)
  }

  return res
}

load_hashed :: proc(name_hash: u32, path: string, params: rawptr, flags: api.Asset_Load_Flags, tags: u32) -> api.Asset_Handle {
  if len(path) == 0 {
    return {0}
  }

  assert(private.core_api.job_thread_index() == 0, "assets must be loaded from main thread")

  load_flags := flags
  if (load_flags & api.ASSET_LOAD_FLAG_RELOAD) != 0 {
    load_flags |= api.ASSET_LOAD_FLAG_WAIT_ON_LOAD
  }

  mgr_id := find_asset_manager_id(name_hash)
  assert(mgr_id != -1, "asset type must be reigstered first")
  mgr := &ctx.asset_managers[mgr_id]
  load_flags |= mgr.forced_flags

  if mgr.params_size > 0 && params == nil {
    assert(false, "load parameters must be provided for this asset type")
  }

  asset, ok := ctx.asset_tbl[hash_asset(path, params, mgr.params_size)]
  if ok && (load_flags & api.ASSET_LOAD_FLAG_RELOAD) == 0 {
    ctx.assets[handle.index_handle(asset.id)].ref_count += 1
  } else {
    res_idx, ok := ctx.resource_tbl[hash.fnv32a(transmute([]u8)path)]
    res : ^Asset_Resource
    real_path := path
    if ok {
      res = &ctx.resources[res_idx]
      real_path = res.real_path
    }
    real_path_cstr := strings.clone_to_cstring(real_path, context.temp_allocator)

    if (load_flags & api.ASSET_LOAD_FLAG_WAIT_ON_LOAD) == 0 {
      asset = create_new_asset(path, params, mgr.async_obj, name_hash, load_flags, tags)
      a := &ctx.assets[handle.index_handle(asset.id)]
      a.state = .Loading

      req := Async_Asset_Load_Req { path_hash = hash.fnv32a(transmute([]u8)real_path), asset = asset }
      append(&ctx.async_reqs, req)

      private.vfs_api.read_async(
        real_path_cstr,
        (load_flags & api.ASSET_LOAD_FLAG_ABSOLUTE_PATH) != 0 ? api.VFS_FLAG_ABSOLUTE_PATH : 0,
        on_asset_read,
        nil,
      )
    } else {
      asset = add_asset(path, params, mgr.failed_obj, name_hash, load_flags, tags, (load_flags & api.ASSET_LOAD_FLAG_RELOAD) != 0 ? asset : {0})

      mb := private.vfs_api.read(
        real_path_cstr,
        (load_flags & api.ASSET_LOAD_FLAG_ABSOLUTE_PATH) != 0 ? api.VFS_FLAG_ABSOLUTE_PATH : 0,
      )

      if mb == nil {
        assert(false, "failed reading file")
        return asset
      }

      a := &ctx.assets[handle.index_handle(asset.id)]

      if res == nil {
        assert(bool(a.resource_id))
        res = &ctx.resources[api.to_index(a.resource_id)]
      }

      params := api.Asset_Load_Params {
        path = strings.clone_to_cstring(path, context.temp_allocator), params = params, tags = tags, flags = load_flags,
      }

      success := false
      
    }
  }

  return asset
}

load :: proc "c" (name: cstring, path: cstring, params: rawptr, flags: api.Asset_Load_Flags, tags: u32) -> api.Asset_Handle {
  context = runtime.default_context()
  context.allocator = ctx.alloc

  name_str := strings.clone_from_cstring(name, context.temp_allocator)
  asset := load_hashed(hash.fnv32a(transmute([]u8)name_str), strings.clone_from_cstring(path, context.temp_allocator), params, flags, tags)

  return asset
}


init :: proc(allocator := context.allocator) {
  ctx.alloc = allocator

  private.vfs_api.register_modify_cb(on_asset_modified)

  ctx.asset_handles = handle.create_pool(api.ASSET_POOL_SIZE)
}

shutdown :: proc() {
  delete(ctx.assets)
  delete(ctx.asset_tbl)
  delete(ctx.asset_managers)
  delete(ctx.asset_name_hashes)
}

@(init, private)
init_asset_api :: proc() {
  private.asset_api = api.Asset_Api {
    register_asset_type = register_asset_type,
    load = load,
  }
}

