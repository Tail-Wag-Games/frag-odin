package mfio

Mem_Block :: struct {
  data: rawptr,
  size: int,
  start_offset: int,
  align: int,
  refcount: int,
}