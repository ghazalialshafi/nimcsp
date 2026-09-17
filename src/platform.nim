## platform.nim
## Platform-level types, imports and utilities.
## Equivalent to src/platform.h

{.push header: "<sched.h>".}
{.pop.}

import std/[posix, atomics, os, times, strutils]

export posix, atomics

# Ensure GNU source features
{.passC: "-D_GNU_SOURCE".}
{.passC: "-pthread".}
{.passL: "-pthread".}

type
  ## Nim equivalent of uint64_t, used pervasively
  Uintptr* = uint

# Re-export common C stdlib types
type
  CSizeT* = csize_t
  CInt*   = cint
