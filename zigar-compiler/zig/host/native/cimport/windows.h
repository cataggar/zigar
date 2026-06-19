#if defined(__i386__) && !defined(_X86_)
#define _X86_ 1
#endif
#include <windows.h>
#include <winternl.h>
