## bench_context_switch.nim
## Honest measurement of the actual context-switch path -- the thing
## bench_million.nim's `task` (one atomic op, no blocking) never touches.
##
## Design: two goroutines, `pinger` and `ponger`, connected by two
## UNBUFFERED channels (capacity 0). An unbuffered chanSend cannot complete
## by dropping a value into a buffer -- it MUST hand off directly to a
## waiting receiver, or block until one arrives. That means every single
## send/recv pair in this loop forces a real trip through cspCoreYield
## (give up this goroutine's stack) and cspProcRestore (resume the other
## one) -- the exact hand-written asm switching path this whole library
## lives or dies on. Nothing here can complete without exercising it.
##
## Each round trip is: pinger sends -> ponger's blocked recv resumes ->
## ponger sends -> pinger's blocked recv resumes. That's a minimum of two
## full context switches per round trip (often more, depending on which
## side happens to be waiting first), so the "ns per switch" figure below
## is a conservative upper bound on real switch cost, not an exact one --
## but it's a real, load-bearing number, not a fiction.

import ../src/csp
import ../src/core
import std/times

const RoundTrips = 500_000

var
  chPingToPong: ptr CspGoChan
  chPongToPing: ptr CspGoChan
  wg: WaitGroupT
  startTime: float

proc pinger(arg: pointer) {.cdecl.} =
  for i in 0 ..< RoundTrips:
    discard chanSend(chPingToPong, cast[pointer](i + 1))
    var ok: bool
    discard chanRecv(chPongToPing, addr ok)
  wgDone(wg)

proc ponger(arg: pointer) {.cdecl.} =
  for i in 0 ..< RoundTrips:
    var ok: bool
    discard chanRecv(chPingToPong, addr ok)
    discard chanSend(chPongToPing, cast[pointer](1))
  wgDone(wg)

proc reporter(arg: pointer) {.cdecl.} =
  wgWait(wg)
  let elapsed = epochTime() - startTime
  # Conservative: at least 2 switches per round trip (one to hand off, one
  # to resume the sender). In practice often more, since either side can
  # be the one left waiting -- treat this as an upper-bound estimate of
  # per-switch cost, not a cycle-exact figure.
  let minSwitches = RoundTrips * 2
  echo "Round trips: ", RoundTrips
  echo "Elapsed: ", elapsed, "s"
  echo "Round trips/s: ", RoundTrips.float / elapsed
  echo "Context switches (lower bound): ", minSwitches
  echo "ns per context switch (upper bound estimate): ",
       (elapsed * 1_000_000_000.0) / minSwitches.float
  quit(0)

proc main() =
  cspInit(2)
  chPingToPong = chanNew(0) # unbuffered -- see file header
  chPongToPing = chanNew(0)
  wgInit(wg)
  wgAdd(wg, 2)
  startTime = epochTime()
  discard cspProcCreate(0, reporter, nil)
  discard cspProcCreate(0, pinger, nil)
  discard cspProcCreate(0, ponger, nil)
  discard cspCoreRun(cspThisCore)

main()
