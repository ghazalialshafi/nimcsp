## test_not_deadlock_timer.nim
## A goroutine sleeping on a timer, with no other runnable work, must NOT
## be reported as a deadlock -- the timer will fire and wake it up. This is
## the negative-case counterpart to test_deadlock.nim.

import ../src/csp
import ../src/core
import std/posix

proc sleeper(arg: pointer) {.cdecl.} =
  cspHangup(300_000_000) # 300ms -- comfortably longer than the scheduler's
                          # own 10ms idle poll interval, so if the deadlock
                          # check were wrong about timers it would fire
                          # well before this legitimately wakes up.
  discard write(1, "PASS: woke up from timer, not falsely deadlocked\n".cstring, 50)
  quit(0)

proc main() =
  cspInit(2)
  discard cspProcCreate(0, sleeper, nil)
  discard cspCoreRun(cspThisCore)

main()
