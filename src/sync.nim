## sync.nim
## Coroutine-aware synchronization primitives: Pthread_mutex and WaitGroup.
## Equivalent to src/sync.h + src/sync.c

import std/[atomics, posix]
import csp_proc_types
import csp_proc_extra
import core
import scheduler
import context_switch

# ─── Pthread_mutex ────────────────────────────────────────────────────────────────────

type
  CspSyncMutex* = object
    locked*:      Atomic[int]
    mtx*:         Pthread_mutex
    cond*:        Pthread_cond
    waitersHead*: ptr CspProc
    waitersTail*: ptr CspProc

proc init*(m: var CspSyncMutex) {.exportc: "csp_sync_mutex_init".} =
  m.locked.store(0)
  m.waitersHead = nil
  m.waitersTail = nil
  discard pthread_mutex_init(addr m.mtx, nil)
  discard pthread_cond_init(addr m.cond, nil)

proc lock*(m: var CspSyncMutex) {.exportc: "csp_sync_mutex_lock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr m.mtx)
  if m.locked.load(moRelaxed) == 0:
    m.locked.store(1, moRelaxed)
    discard pthread_mutex_unlock(addr m.mtx)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  let self = if core != nil: core.running else: nil
  if self != nil:
    self.statSet(CspProcStatBlocked)
    self.next = nil
    if m.waitersTail != nil:
      m.waitersTail.next = self
      m.waitersTail = self
    else:
      m.waitersHead = self
      m.waitersTail = self
    discard pthread_mutex_unlock(addr m.mtx)
    cspCoreYield(self, addr core.anchor)
  else:
    while m.locked.load(moRelaxed) != 0:
      discard pthread_cond_wait(addr m.cond, addr m.mtx)
    m.locked.store(1, moRelaxed)
    discard pthread_mutex_unlock(addr m.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc unlock*(m: var CspSyncMutex) {.exportc: "csp_sync_mutex_unlock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr m.mtx)
  if m.waitersHead != nil:
    let p = m.waitersHead
    m.waitersHead = p.next
    if m.waitersHead == nil: m.waitersTail = nil
    discard pthread_mutex_unlock(addr m.mtx)
    cspSchedulerSubmit(p)
  else:
    m.locked.store(0, moRelaxed)
    discard pthread_cond_signal(addr m.cond)
    discard pthread_mutex_unlock(addr m.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

# ─── WaitGroup ───────────────────────────────────────────────────────────────

type
  CspSyncWaitGroup* = object
    counter*:     Atomic[int64]
    mtx*:         Pthread_mutex
    cond*:        Pthread_cond
    waitersHead*: ptr CspProc
    waitersTail*: ptr CspProc

proc init*(wg: var CspSyncWaitGroup) {.exportc: "csp_sync_waitgroup_init".} =
  wg.counter.store(0)
  wg.waitersHead = nil; wg.waitersTail = nil
  discard pthread_mutex_init(addr wg.mtx, nil)
  discard pthread_cond_init(addr wg.cond, nil)

proc add*(wg: var CspSyncWaitGroup, delta: int) {.exportc: "csp_sync_waitgroup_add".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  let val = wg.counter.fetchAdd(int64(delta)) + int64(delta)
  if val < 0:
    quit("panic: negative WaitGroup counter")

  if val == 0:
    discard pthread_mutex_lock(addr wg.mtx)
    var q = wg.waitersHead
    wg.waitersHead = nil; wg.waitersTail = nil
    discard pthread_cond_broadcast(addr wg.cond)
    discard pthread_mutex_unlock(addr wg.mtx)
    while q != nil:
      let nxt = q.next
      cspSchedulerSubmit(q)
      q = nxt

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc done*(wg: var CspSyncWaitGroup) {.exportc: "csp_sync_waitgroup_done".} =
  wg.add(-1)

proc wait*(wg: var CspSyncWaitGroup) {.exportc: "csp_sync_waitgroup_wait".} =
  if wg.counter.load(moSequentiallyConsistent) == 0: return

  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr wg.mtx)
  if wg.counter.load(moSequentiallyConsistent) == 0:
    discard pthread_mutex_unlock(addr wg.mtx)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  let self = if core != nil: core.running else: nil
  if self != nil:
    self.statSet(CspProcStatBlocked)
    self.next = nil
    if wg.waitersTail != nil:
      wg.waitersTail.next = self
      wg.waitersTail = self
    else:
      wg.waitersHead = self
      wg.waitersTail = self
    discard pthread_mutex_unlock(addr wg.mtx)
    cspCoreYield(self, addr core.anchor)
  else:
    while wg.counter.load(moSequentiallyConsistent) > 0:
      discard pthread_cond_wait(addr wg.cond, addr wg.mtx)
    discard pthread_mutex_unlock(addr wg.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

# ─── Once ──────────────────────────────────────────────────────────────────

type
  CspSyncOnce* = object
    done*:        Atomic[bool]
    started*:     bool
    mtx*:         Pthread_mutex
    cond*:        Pthread_cond
    waitersHead*: ptr CspProc
    waitersTail*: ptr CspProc

proc init*(o: var CspSyncOnce) {.exportc: "csp_sync_once_init".} =
  o.done.store(false)
  o.started = false
  o.waitersHead = nil
  o.waitersTail = nil
  discard pthread_mutex_init(addr o.mtx, nil)
  discard pthread_cond_init(addr o.cond, nil)

## Runs `fn` exactly once across however many goroutines/threads call `doOnce`
## on this `CspSyncOnce`, however many times each calls it. Every caller
## blocks until the first call's `fn` has fully returned (matching Go's
## sync.Once semantics) -- this is not just a "run once" flag, it's a
## synchronization point.
proc doOnce*(o: var CspSyncOnce, fn: proc() {.closure.}) {.exportc: "csp_sync_once_do".} =
  if o.done.load(moAcquire): return

  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr o.mtx)
  if o.done.load(moRelaxed):
    discard pthread_mutex_unlock(addr o.mtx)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  if not o.started:
    o.started = true
    discard pthread_mutex_unlock(addr o.mtx)
    # Run fn with the lock released: fn may itself block (e.g. on a channel
    # or another Once), and holding o.mtx across that would risk deadlock
    # for no benefit -- waiters only care that `done` eventually flips.
    fn()
    discard pthread_mutex_lock(addr o.mtx)
    o.done.store(true, moRelease)
    var q = o.waitersHead
    o.waitersHead = nil
    o.waitersTail = nil
    discard pthread_cond_broadcast(addr o.cond)
    discard pthread_mutex_unlock(addr o.mtx)
    while q != nil:
      let nxt = q.next
      q.next = nil
      cspSchedulerSubmit(q)
      q = nxt
  else:
    let self = if core != nil: core.running else: nil
    if self != nil:
      self.statSet(CspProcStatBlocked)
      self.next = nil
      if o.waitersTail != nil:
        o.waitersTail.next = self
        o.waitersTail = self
      else:
        o.waitersHead = self
        o.waitersTail = self
      discard pthread_mutex_unlock(addr o.mtx)
      cspCoreYield(self, addr core.anchor)
    else:
      while not o.done.load(moRelaxed):
        discard pthread_cond_wait(addr o.cond, addr o.mtx)
      discard pthread_mutex_unlock(addr o.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

# ─── RWMutex ───────────────────────────────────────────────────────────────
## Writer-preference RWMutex, matching Go's sync.RWMutex: once a writer is
## waiting, new readers queue up behind it rather than starving it out --
## only readers that already held the lock before the writer arrived get to
## finish first.

type
  CspSyncRWMutex* = object
    mtx*:            Pthread_mutex
    cond*:           Pthread_cond
    readers*:        int   ## active reader count
    writerActive*:   bool
    writerWaiting*:  int   ## queued writers, blocks new readers from joining
    readWaitersHead*, readWaitersTail*: ptr CspProc
    writeWaitersHead*, writeWaitersTail*: ptr CspProc

proc init*(rw: var CspSyncRWMutex) {.exportc: "csp_sync_rwmutex_init".} =
  rw.readers = 0
  rw.writerActive = false
  rw.writerWaiting = 0
  rw.readWaitersHead = nil; rw.readWaitersTail = nil
  rw.writeWaitersHead = nil; rw.writeWaitersTail = nil
  discard pthread_mutex_init(addr rw.mtx, nil)
  discard pthread_cond_init(addr rw.cond, nil)

proc rlock*(rw: var CspSyncRWMutex) {.exportc: "csp_sync_rwmutex_rlock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr rw.mtx)
  if not rw.writerActive and rw.writerWaiting == 0:
    rw.readers.inc
    discard pthread_mutex_unlock(addr rw.mtx)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  let self = if core != nil: core.running else: nil
  if self != nil:
    self.statSet(CspProcStatBlocked)
    self.next = nil
    if rw.readWaitersTail != nil:
      rw.readWaitersTail.next = self
      rw.readWaitersTail = self
    else:
      rw.readWaitersHead = self
      rw.readWaitersTail = self
    discard pthread_mutex_unlock(addr rw.mtx)
    cspCoreYield(self, addr core.anchor)
  else:
    while rw.writerActive or rw.writerWaiting > 0:
      discard pthread_cond_wait(addr rw.cond, addr rw.mtx)
    rw.readers.inc
    discard pthread_mutex_unlock(addr rw.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc runlock*(rw: var CspSyncRWMutex) {.exportc: "csp_sync_rwmutex_runlock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr rw.mtx)
  rw.readers.dec
  if rw.readers == 0 and rw.writeWaitersHead != nil:
    let p = rw.writeWaitersHead
    rw.writeWaitersHead = p.next
    if rw.writeWaitersHead == nil: rw.writeWaitersTail = nil
    rw.writerActive = true
    rw.writerWaiting.dec
    discard pthread_mutex_unlock(addr rw.mtx)
    cspSchedulerSubmit(p)
  else:
    discard pthread_cond_broadcast(addr rw.cond)
    discard pthread_mutex_unlock(addr rw.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc lock*(rw: var CspSyncRWMutex) {.exportc: "csp_sync_rwmutex_lock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr rw.mtx)
  if not rw.writerActive and rw.readers == 0:
    rw.writerActive = true
    discard pthread_mutex_unlock(addr rw.mtx)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  rw.writerWaiting.inc
  let self = if core != nil: core.running else: nil
  if self != nil:
    self.statSet(CspProcStatBlocked)
    self.next = nil
    if rw.writeWaitersTail != nil:
      rw.writeWaitersTail.next = self
      rw.writeWaitersTail = self
    else:
      rw.writeWaitersHead = self
      rw.writeWaitersTail = self
    discard pthread_mutex_unlock(addr rw.mtx)
    cspCoreYield(self, addr core.anchor)
  else:
    while rw.writerActive or rw.readers > 0:
      discard pthread_cond_wait(addr rw.cond, addr rw.mtx)
    rw.writerActive = true
    rw.writerWaiting.dec
    discard pthread_mutex_unlock(addr rw.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc unlock*(rw: var CspSyncRWMutex) {.exportc: "csp_sync_rwmutex_unlock".} =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr rw.mtx)
  rw.writerActive = false
  if rw.writeWaitersHead != nil:
    let p = rw.writeWaitersHead
    rw.writeWaitersHead = p.next
    if rw.writeWaitersHead == nil: rw.writeWaitersTail = nil
    rw.writerActive = true
    rw.writerWaiting.dec
    discard pthread_mutex_unlock(addr rw.mtx)
    cspSchedulerSubmit(p)
  elif rw.readWaitersHead != nil:
    var q = rw.readWaitersHead
    rw.readWaitersHead = nil
    rw.readWaitersTail = nil
    var n = 0
    var it = q
    while it != nil:
      n.inc
      it = it.next
    rw.readers = n
    discard pthread_mutex_unlock(addr rw.mtx)
    while q != nil:
      let nxt = q.next
      q.next = nil
      cspSchedulerSubmit(q)
      q = nxt
  else:
    discard pthread_cond_broadcast(addr rw.cond)
    discard pthread_mutex_unlock(addr rw.mtx)

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
