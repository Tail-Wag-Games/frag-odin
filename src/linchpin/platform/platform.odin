package platform

import win32 "core:sys/windows"

MIN_STACK_SIZE :: 32768 // 32kb

num_cores :: proc() -> int {
  	info: win32.SYSTEM_INFO
	  win32.GetSystemInfo(&info)
	  return int(info.dwNumberOfProcessors)
}