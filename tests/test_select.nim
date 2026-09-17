import ../src/csp
import ../src/core
import std/posix
import std/os
import std/times

proc senderTask(arg: pointer) {.cdecl.} =
  let ch = cast[ptr CspGoChan](arg)
  discard write(1, "sender: sleeping\n".cstring, 17)
  cspHangup(uint64(100 * 1_000_000)) # 100ms
  discard write(1, "sender: sending to ch\n".cstring, 22)
  var v = cast[pointer](42)
  discard chanSend(ch, v)
  discard write(1, "sender: sent\n".cstring, 13)

proc mainTask(arg: pointer) {.cdecl.} =
  let ch1 = chanNew(0)
  let ch2 = chanNew(0)

  discard cspProcCreate(0, senderTask, ch2)

  discard write(1, "main: select starting\n".cstring, 22)
  var cases: array[2, CspSelectCase]
  cases[0] = CspSelectCase(ch: ch1, op: CspSelectOp.Recv, val: nil)
  cases[1] = CspSelectCase(ch: ch2, op: CspSelectOp.Recv, val: nil)

  let chosen = cspSelect(addr cases[0], 2)

  discard write(1, "main: select returned\n".cstring, 22)

  if chosen == 1:
    discard write(1, "SUCCESS: select blocked and woke up correctly\n".cstring, 46)
    quit(0)
  else:
    discard write(1, "FAILURE: select did not behave as expected\n".cstring, 43)
    quit(1)

proc main() =
  cspInit(1)
  discard cspProcCreate(0, mainTask, nil)
  discard cspCoreRun(cspThisCore)

main()
