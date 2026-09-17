## mutex.nim
## Lightweight spinlock mutex using atomic flag.
## Equivalent to src/mutex.h

import std/atomics

type
  CspMutex* = object
    flag: Atomic[bool]

proc init*(m: var CspMutex) =
  m.flag.store(false)

proc tryLock*(m: var CspMutex): bool =
  ## Returns true if lock was acquired
  not m.flag.exchange(true, moAcquire)

proc lock*(m: var CspMutex) =
  while not m.tryLock():
    cpuRelax()

proc unlock*(m: var CspMutex) =
  m.flag.store(false, moRelease)

template withLock*(m: var CspMutex, body: untyped) =
  m.lock()
  try:
    body
  finally:
    m.unlock()
