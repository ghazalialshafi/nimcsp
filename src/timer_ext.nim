## timer_ext.nim
## Higher-level timer utilities.

import std/atomics
import csp_proc_types
import chan
import timer
import sched
import csp_proc

type
  TimerTaskArg = object
    ch*:       ptr CspGoChan
    duration*: CspTimerDuration
    periodic*: bool
    stopped*:  Atomic[bool]

  CspTicker* = object
    ch*: ptr CspGoChan
    ta*: ptr TimerTaskArg

proc timerTask(arg: pointer) {.cdecl.} =
  let ta = cast[ptr TimerTaskArg](arg)
  while not ta.stopped.load(moSequentiallyConsistent):
    cspSchedHangup(uint64(ta.duration))
    if ta.stopped.load(moSequentiallyConsistent) or ta.ch.closed: break
    if ta.periodic:
      discard trySendGoChan(ta.ch, nil)
    else:
      discard sendGoChan(ta.ch, nil)
    if not ta.periodic: break
  if not ta.periodic:
    deallocShared(ta)

proc cspTimeAfter*(d: CspTimerDuration): ptr CspGoChan {.exportc: "csp_time_after".} =
  let ch = newGoChan(1)
  let ta = cast[ptr TimerTaskArg](allocShared0(sizeof(TimerTaskArg)))
  ta.ch       = ch
  ta.duration = d
  ta.periodic = false
  ta.stopped.store(false)
  discard cspProcCreate(0, timerTask, ta)
  ch

proc cspTickerNew*(d: CspTimerDuration): ptr CspTicker {.exportc: "csp_ticker_new".} =
  let ticker = cast[ptr CspTicker](allocShared0(sizeof(CspTicker)))
  ticker.ch = newGoChan(1)
  let ta = cast[ptr TimerTaskArg](allocShared0(sizeof(TimerTaskArg)))
  ta.ch       = ticker.ch
  ta.duration = d
  ta.periodic = true
  ta.stopped.store(false)
  ticker.ta = ta
  discard cspProcCreate(0, timerTask, ta)
  ticker

proc cspTickerStop*(ticker: ptr CspTicker) {.exportc: "csp_ticker_stop".} =
  if ticker != nil:
    ticker.ta.stopped.store(true, moSequentiallyConsistent)
