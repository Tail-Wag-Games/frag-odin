package linchpin

import win32 "core:sys/windows"

num_cores :: proc() -> int {
  	info: win32.SYSTEM_INFO
	  win32.GetSystemInfo(&info)
	  return int(info.dwNumberOfProcessors)
}