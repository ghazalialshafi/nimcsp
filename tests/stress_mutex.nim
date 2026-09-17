## stress_mutex.nim
## Adversarial stress test: many goroutines all contending for a single
## mutex-protected counter, plus a WaitGroup to know when they're all done.
## A correct implementation must produce EXACTLY NumGoroutines*IncsPerGoroutine
## in the counter -- any race in the mutex's lock/unlock/wait-queue handling
## shows up immediately as a wrong final count, not just a crash.

import ../src/csp
import ../src/core
import std/posix

const
  NumGoroutines = 300
  IncsPerGoroutine = 300

var
  wg: WaitGroupT
  mtx: MutexT
  counter: int64 = 0

proc incrementer(arg: pointer) {.cdecl.} =
  for i in 0 ..< IncsPerGoroutine:
    mutexLock(mtx)
    # Deliberately non-atomic read-modify-write: only correct if the mutex
    # genuinely provides mutual exclusion.
    let old = counter
    # A tiny bit of "work" while holding the lock increases the odds that
    # a broken mutex lets another goroutine interleave here.
    cspYield()
    counter = old + 1
    mutexUnlock(mtx)
  wgDone(wg)

proc reporter(arg: pointer) {.cdecl.} =
  wgWait(wg)
  let expected = int64(NumGoroutines * IncsPerGoroutine)
  let msg = "counter=" & $counter & " expected=" & $expected & "\n"
  discard write(1, msg.cstring, msg.len)
  if counter != expected:
    discard write(1, "FAIL: lost or duplicated increments (mutex is not providing mutual exclusion)\n".cstring, 80)
    quit(1)
  discard write(1, "PASS\n".cstring, 5)
  quit(0)

proc main() =
  cspInit(4)
  mutexInit(mtx)
  wgInit(wg)
  wgAdd(wg, NumGoroutines)

  discard cspProcCreate(0, reporter, nil)
  for i in 0 ..< NumGoroutines:
    discard cspProcCreate(0, incrementer, nil)

  discard cspCoreRun(cspThisCore)

main()
