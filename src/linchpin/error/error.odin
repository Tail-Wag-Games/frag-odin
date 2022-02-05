package error

import "core:runtime"

Plugin_Error :: enum {
  Load,
  Init,
  Inital_Update,
  Symbol_Not_Found,
}

IO_Error :: enum {
  Path_Not_Found,
  Directory,
}

Error :: union {
	runtime.Allocator_Error,
  IO_Error,
  Plugin_Error,
};

error_descriptions := map[Error]string{
  .Path_Not_Found = "The system cannot find the path specified.",
  .Directory = "The directory name is invalid.",
}