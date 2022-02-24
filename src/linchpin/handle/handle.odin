package handle

import "../alloc"
import "../config"

import "core:slice"

Handle :: u32

INVALID_HANDLE :: Handle(0)

HANDLE_INDEX_MASK :: (1 << (32 - config.HANDLE_GEN_BITS)) - 1
HANDLE_GEN_MASK :: ((1 << config.HANDLE_GEN_BITS) - 1)
HANDLE_GEN_SHIFT :: (32 - config.HANDLE_GEN_BITS)

Handle_Pool :: struct {
  count: int,
  capacity: int,
  dense: []Handle,
  sparse: []int,
}

index_handle :: proc(h: Handle) -> int {
  return int(h & HANDLE_INDEX_MASK)
}

gen_handle :: proc(h: Handle) -> int {
  return int((h >> HANDLE_GEN_SHIFT) & HANDLE_GEN_MASK)
}

make_handle :: proc(g: int, idx: int) -> Handle {
  return Handle(((u32(g) & HANDLE_GEN_MASK) << HANDLE_GEN_SHIFT) | u32(idx) & HANDLE_INDEX_MASK)
}

valid_handle :: proc(pool: ^Handle_Pool, handle: Handle) -> bool {
  assert(handle > 0)
  idx := pool.sparse[index_handle(handle)]
  return idx < pool.count && pool.dense[idx] == handle
}

new_handle :: proc(pool: ^Handle_Pool) -> Handle {
  if pool.count < pool.capacity {
    idx := pool.count
    pool.count += 1

    handle := pool.dense[idx]

    gen := gen_handle(handle)
    index := index_handle(handle)
    gen += 1
    new_handle := make_handle(gen, index)

    pool.dense[idx] = new_handle
    pool.sparse[index] = idx
    return new_handle
  } else {
    assert(false, "handle pool is full")
  }

  return INVALID_HANDLE
}

delete_handle :: proc(pool: ^Handle_Pool, handle: Handle) {
  assert(pool.count > 0)
  assert(valid_handle(pool, handle))

  idx := pool.sparse[index_handle(handle)]
  pool.count -= 1
  last_handle := pool.dense[pool.count]

  pool.dense[pool.count] = handle
  pool.sparse[index_handle(last_handle)] = idx
  pool.dense[idx] = last_handle
}

reset_pool :: proc(pool: ^Handle_Pool) {
  pool.count = 0
  for d, i in &pool.dense {
    d = make_handle(0, i)
  }
}

grow_pool :: proc(ppool: ^^Handle_Pool) -> bool {
  pool := ppool^
  new_cap := pool.capacity << 1

  new_pool := create_pool(new_cap)
  if new_pool == nil {
    return false
  }

  new_pool.count = pool.count
  new_pool.dense = slice.clone(pool.dense)
  new_pool.sparse = slice.clone(pool.sparse)

  destroy_pool(pool)
  ppool^ = new_pool
  return true
}

create_pool :: proc(capacity: int) -> ^Handle_Pool {
  max_size := alloc.align_mask(capacity, 15)

  res := new(Handle_Pool)
  res.dense = make([]Handle, max_size)
  res.sparse = make([]int, max_size)
  res.capacity = capacity
  reset_pool(res)

  return res
}

destroy_pool :: proc(pool: ^Handle_Pool) {
  delete(pool.dense)
  delete(pool.sparse)

  if pool != nil {
    free(pool)
  }
}

new_handle_and_grow_pool :: proc(pool: ^^Handle_Pool) -> Handle {
  if pool_is_full(pool^) {
    grow_pool(pool)
  }
  return new_handle(pool^)
}

pool_is_full :: proc(pool: ^Handle_Pool) -> bool {
  return pool.count == pool.capacity
}