## test_deadlock.nim
## Deliberately deadlocks (two goroutines each waiting to receive from a
## channel that nothing will ever send on) and checks that the runtime
## detects it and exits with the documented fatal-error message + exit
## code, instead of hanging forever.

import ../src/csp
import ../src/core

var ch: ptr CspGoChan

proc waiter(arg: pointer) {.cdecl.} =
  var ok: bool
  # Nobody will ever send on this channel and it's never closed --
  # unbuffered, so this blocks forever with no timer, no I/O, nothing.
  discard chanRecv(ch, addr ok)

proc main() =
  cspInit(2)
  ch = chanNew(0)
  discard cspProcCreate(0, waiter, nil)
  discard cspProcCreate(0, waiter, nil)
  discard cspCoreRun(cspThisCore)

main()
