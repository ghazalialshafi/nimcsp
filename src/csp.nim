## csp.nim
## Top-level public API for the CSP Nim runtime.

import std/atomics
import chan
import sync
import netpoll
import context
import runtime
import timer
import timer_ext
import sched
import csp_proc_types
import csp_proc
import csp_proc_extra
import scheduler
import core

export chan
export sync
export netpoll
export context
export runtime
export timer
export timer_ext
export sched
export csp_proc_types
export csp_proc
export scheduler

# ─── High-level aliases (mirroring Go naming) ─────────────────────────────────

template chanT*(T: typedesc): typedesc = ptr CspGoChan
template chanNew*(capacity: uint): ptr CspGoChan = newGoChan(capacity)

proc chanSend*(ch: ptr CspGoChan, val: pointer): bool {.inline.} =
  sendGoChan(ch, val)

proc chanRecv*(ch: ptr CspGoChan, ok: ptr bool): pointer {.inline.} =
  recvGoChan(ch, ok)

proc chanClose*(ch: ptr CspGoChan) {.inline.} =
  closeGoChan(ch)

template cspAsync*(tasks: untyped) =
  cspSchedProcAnchor(false)
  cspProcNchildSet(0)
  tasks
  cspSchedYield()

template cspSync*(tasks: untyped) =
  cspSchedProcAnchor(true)
  cspProcNchildSet(0)
  tasks
  cspSchedYield()

template cspBlock*(tasks: untyped) =
  let core = cspThisCore
  let running = if core != nil: core.running else: nil
  let extra = if running != nil: cast[ptr CspProcExtra](running.extra) else: nil
  # Capture everything we need from `core` BEFORE calling
  # cspCoreBlockPrologue: it hands the core back to the free pool, after
  # which any other thread may claim it and start mutating its fields
  # (including `running`/`pid`) immediately. Reading them from `core`
  # afterward is a use-after-release race (confirmed by ThreadSanitizer).
  let pidBeforeRelease = if core != nil: core.pid else: 0.uint
  if core != nil and cspCoreBlockPrologue(core):
    if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)
    let savedProc = running
    let savedPid = pidBeforeRelease
    cspThisCore = nil
    tasks
    cspCoreBlockEpilogue(savedProc, savedPid)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  else:
    tasks

template cspYield*() =
  cspSchedYield()

template cspHangup*(ns: uint64) =
  cspSchedHangup(ns)

template timeAfter*(d: CspTimerDuration): ptr CspGoChan = cspTimeAfter(d)
template tickerNew*(d: CspTimerDuration): ptr CspTicker = cspTickerNew(d)
template tickerStop*(t: ptr CspTicker) = cspTickerStop(t)

type
  MutexT*     = CspSyncMutex
  WaitGroupT* = CspSyncWaitGroup
  OnceT*      = CspSyncOnce
  RWMutexT*   = CspSyncRWMutex

proc mutexInit*(m: var MutexT)    {.inline.} = m.init()
proc mutexLock*(m: var MutexT)    {.inline.} = m.lock()
proc mutexUnlock*(m: var MutexT)  {.inline.} = m.unlock()

proc wgInit*(wg: var WaitGroupT)  {.inline.} = wg.init()
proc wgAdd*(wg: var WaitGroupT, n: int) {.inline.} = wg.add(n)
proc wgDone*(wg: var WaitGroupT)  {.inline.} = wg.done()
proc wgWait*(wg: var WaitGroupT)  {.inline.} = wg.wait()

proc onceInit*(o: var OnceT) {.inline.} = o.init()
## Runs `fn` exactly once, no matter how many goroutines call `onceDo` on
## the same `OnceT`, or how many times each of them calls it. Every caller
## blocks until the very first call's `fn` has returned. Mirrors Go's
## `sync.Once.Do`.
proc onceDo*(o: var OnceT, fn: proc() {.closure.}) {.inline.} = o.doOnce(fn)

proc rwMutexInit*(rw: var RWMutexT)    {.inline.} = rw.init()
proc rwMutexRLock*(rw: var RWMutexT)   {.inline.} = rw.rlock()
proc rwMutexRUnlock*(rw: var RWMutexT) {.inline.} = rw.runlock()
proc rwMutexLock*(rw: var RWMutexT)    {.inline.} = rw.lock()
proc rwMutexUnlock*(rw: var RWMutexT)  {.inline.} = rw.unlock()
