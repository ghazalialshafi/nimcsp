## test_context.nim
## Correctness checks for Context: cancel propagation to children, timeout
## firing with DeadlineExceeded, explicit cancel winning a race against a
## timeout, and Err() reporting the right reason in each case.

import ../src/csp
import ../src/core
import std/posix

var
  wg: WaitGroupT
  failures: int

proc fail(msg: string) =
  discard write(1, ("FAIL: " & msg & "\n").cstring, msg.len + 7)
  failures.inc

# 1. WithTimeout: context should finish on its own with DeadlineExceeded.
proc testTimeout(arg: pointer) {.cdecl.} =
  let ctx = cspContextWithTimeout(nil, 20_000_000) # 20ms
  var ok: bool
  discard recvGoChan(cspContextDone(ctx), addr ok)
  if cspContextErr(ctx) != CspContextErr.DeadlineExceeded:
    fail("WithTimeout did not report DeadlineExceeded")
  else:
    discard write(1, "PASS timeout\n".cstring, 13)
  wgDone(wg)

# 2. WithCancel: explicit cancel should fire Done with Canceled, well before
#    any timeout would.
proc testCancel(arg: pointer) {.cdecl.} =
  let root = cspContextBackground()
  let ctx = cspContextWithCancel(root)
  cspContextCancel(ctx)
  var ok: bool
  discard recvGoChan(cspContextDone(ctx), addr ok)
  if cspContextErr(ctx) != CspContextErr.Canceled:
    fail("WithCancel did not report Canceled")
  else:
    discard write(1, "PASS cancel\n".cstring, 12)
  wgDone(wg)

# 3. Parent cancel propagates to child.
proc testPropagate(arg: pointer) {.cdecl.} =
  let root = cspContextBackground()
  let parent = cspContextWithCancel(root)
  let child = cspContextWithCancel(parent)
  cspContextCancel(parent)
  var ok: bool
  discard recvGoChan(cspContextDone(child), addr ok)
  if cspContextErr(child) != CspContextErr.Canceled:
    fail("parent cancel did not propagate to child")
  else:
    discard write(1, "PASS propagate\n".cstring, 15)
  wgDone(wg)

# 4. Explicit cancel racing a longer timeout: cancel should win, and the
#    context must not later flip to DeadlineExceeded once the timer fires.
proc testCancelBeatsTimeout(arg: pointer) {.cdecl.} =
  let ctx = cspContextWithTimeout(nil, 200_000_000) # 200ms -- long
  cspContextCancel(ctx) # fires almost immediately
  var ok: bool
  discard recvGoChan(cspContextDone(ctx), addr ok)
  let errAtCancel = cspContextErr(ctx)
  if errAtCancel != CspContextErr.Canceled:
    fail("explicit cancel did not win the race against a pending timeout")
  # Wait past the timeout window and make sure Err() didn't change out from
  # under us -- the reason is supposed to be fixed at first cancellation.
  cspHangup(250_000_000)
  if cspContextErr(ctx) != errAtCancel:
    fail("Err() changed after the fact once the losing timer fired")
  else:
    discard write(1, "PASS cancel_beats_timeout\n".cstring, 26)
  wgDone(wg)

proc reporter(arg: pointer) {.cdecl.} =
  wgWait(wg)
  if failures == 0:
    discard write(1, "PASS all\n".cstring, 9)
    quit(0)
  else:
    quit(1)

proc main() =
  cspInit(4)
  wgInit(wg)
  wgAdd(wg, 4)
  discard cspProcCreate(0, reporter, nil)
  discard cspProcCreate(0, testTimeout, nil)
  discard cspProcCreate(0, testCancel, nil)
  discard cspProcCreate(0, testPropagate, nil)
  discard cspProcCreate(0, testCancelBeatsTimeout, nil)
  discard cspCoreRun(cspThisCore)

main()
