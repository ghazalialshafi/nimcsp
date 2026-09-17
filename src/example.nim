## example.nim
## Demonstrates the CSP Nim runtime API.
## Equivalent to a Go program using goroutines, channels, waitgroups, select.

import csp
import core

# ─── Simple goroutine + channel example ──────────────────────────────────────
# NOTE on allocation: any value handed across a channel (or otherwise shared
# between goroutines) must come from the thread-safe shared heap
# (allocShared/deallocShared), never plain alloc/dealloc. Goroutines are not
# pinned to an OS thread in this M:N scheduler, so a value allocated on one
# thread can easily end up freed on a different one -- plain alloc/dealloc
# use a thread-local heap and corrupt allocator state in that case. See
# README.md "Correctness notes" for the general rule.

var chanExampleDone: WaitGroupT

proc producer(arg: pointer) {.cdecl.} =
  let ch = cast[ptr CspGoChan](arg)
  for i in 1 .. 5:
    let val = allocShared(sizeof(int))
    cast[ptr int](val)[] = i
    discard chanSend(ch, val)
  chanClose(ch)

proc consumer(arg: pointer) {.cdecl.} =
  let ch = cast[ptr CspGoChan](arg)
  while true:
    var ok: bool
    let val = chanRecv(ch, addr ok)
    if not ok: break
    echo "received: ", cast[ptr int](val)[]
    deallocShared(val)
  wgDone(chanExampleDone)

# ─── WaitGroup example ───────────────────────────────────────────────────────

var wg: WaitGroupT

proc worker(arg: pointer) {.cdecl.} =
  let id = cast[int](arg)
  echo "worker ", id, " started"
  # simulate work
  cspHangup(uint64(CspTimerMillisecond * 10))
  echo "worker ", id, " done"
  wgDone(wg)

# ─── Ticker example ──────────────────────────────────────────────────────────

var tickerExampleDone: WaitGroupT

proc tickerDemo(arg: pointer) {.cdecl.} =
  let ticker = tickerNew(CspTimerMillisecond * 100)
  for i in 1 .. 3:
    discard chanRecv(ticker.ch, nil)
    echo "tick ", i
  tickerStop(ticker)
  wgDone(tickerExampleDone)

# ─── Main ─────────────────────────────────────────────────────────────────────
# All goroutine bodies above just define what will run once cspCoreRun
# starts the scheduler below. Each stage below uses a WaitGroup to actually
# wait for its goroutine(s) to finish before moving on and, at the end,
# before the process exits -- without that, main() would fall through to
# cspCoreRun almost immediately and the goroutines would never be observed
# to run at all.

proc runExamples() =
  echo "=== Channel Example ==="
  wgInit(chanExampleDone)
  wgAdd(chanExampleDone, 1)
  let ch = chanNew(0u)  # unbuffered
  discard cspProcCreate(0, producer, ch)
  discard cspProcCreate(0, consumer, ch)
  wgWait(chanExampleDone) # wait for consumer to drain and close to propagate

  echo "=== WaitGroup Example ==="
  wgInit(wg)
  for i in 1 .. 3:
    wgAdd(wg, 1)
    discard cspProcCreate(0, worker, cast[pointer](i))
  wgWait(wg)
  echo "all workers done"

  echo "=== Ticker Example ==="
  wgInit(tickerExampleDone)
  wgAdd(tickerExampleDone, 1)
  discard cspProcCreate(0, tickerDemo, nil)
  wgWait(tickerExampleDone)

  quit(0)

proc runExamplesTask(arg: pointer) {.cdecl.} =
  runExamples()

proc main() =
  cspInit()
  discard cspProcCreate(0, runExamplesTask, nil)
  discard cspCoreRun(cspThisCore)

when isMainModule:
  main()
