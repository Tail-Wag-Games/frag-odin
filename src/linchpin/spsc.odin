package linchpin

import lockless "../../vendor/c89atomic"

import "core:mem"

SPSC_Queue_Node :: struct {
  next: ^SPSC_Queue_Node,
}

SPSC_Queue_Bin :: struct {
  ptrs: []^SPSC_Queue_Node,
  buff: []u8,
  next: ^SPSC_Queue_Bin,
  iter: int,
  _reserved: int,
}

SPSC_Queue :: struct {
  ptrs: []^SPSC_Queue_Node,
  buff: []u8,
  iter: int,
  capacity: int,
  stride: int,
  buff_size: int,

  first: ^SPSC_Queue_Node,
  last: lockless.Atomic_Ptr,
  divider: lockless.Atomic_Ptr,

  grow_bins: ^SPSC_Queue_Bin,
}

create_spsc_queue :: proc(item_size: int, capacity: int) -> (res: ^SPSC_Queue, err: Error = nil) {
  assert(item_size > 0)

  aligned_capacity := align_mask(capacity, 15)

  res = new(SPSC_Queue)
  res.ptrs = make([]^SPSC_Queue_Node, aligned_capacity) or_return
  res.buff = make([]u8, (item_size + size_of(SPSC_Queue_Node)) * aligned_capacity) or_return

  res.iter = aligned_capacity
  res.capacity = aligned_capacity
  res.stride = item_size
  res.buff_size = (item_size + size_of(SPSC_Queue_Node)) * aligned_capacity

  for i in 0 ..< aligned_capacity {
    res.ptrs[aligned_capacity - i - 1] =
      cast(^SPSC_Queue_Node)&res.buff[(size_of(SPSC_Queue_Node) +item_size) * i]
  }

  res.iter -= 1
  node := res.ptrs[res.iter]
  node.next = nil
  res.first = node
  res.last = lockless.Atomic_Ptr(uintptr(node))
  res.divider = res.last
  res.grow_bins = nil
  
  return res, err
}

consume_from_spsc_queue :: proc(queue: ^SPSC_Queue, data: rawptr) -> bool {
  if queue.divider != lockless.atomic_load64_explicit(&queue.last, lockless.Atomic_Memory_Order.Acquire) {

  }

  return false
}