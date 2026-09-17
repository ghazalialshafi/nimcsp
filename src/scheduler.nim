## scheduler.nim
## M:N work-stealing scheduler.

import std/[atomics, posix, os]
import csp_proc_types
import csp_proc_extra
import runq
import rbq
import core
import corepool
import worker
import netpoll
import common
import timer
import csp_tsan

type
  CspScheduler* = object
    numWorkers*: Atomic[int]
    maxWorkers*: int
    workers*: ptr UncheckedArray[ptr CspWorker]
    globalRunq*: GRunq
    numProcs*: Atomic[int]
    lock*: Pthread_mutex
    cond*: Pthread_cond
    idleWorkers*: Atomic[int]
    preempterTid*: Pthread
    stopPreempter*: Atomic[bool]
    schedTick*: Atomic[uint64]
    lastSpawnNs*: Atomic[int64]
    deadlockReported*: Atomic[bool]
    deadlockSuspectedSinceNs*: Atomic[int64]

const
  WorkerSpawnMinBacklog = 4    ## don't grow the OS-thread pool for a
                               ## transient blip; require a real backlog
  WorkerSpawnCooldownNs = 2_000_000  ## 2ms: give a just-spawned worker time
                                     ## to start and register itself idle
                                     ## before spawning yet another one

var cspGlobalScheduler* {.exportc: "csp_global_scheduler".}: ptr CspScheduler = nil

# `workers` slots are written once (by whichever thread spawns that worker,
# published only after numWorkers' CAS bump) and read from any thread doing
# the preempt sweep, the steal loop, or startup. A plain pointer read/write
# through the array is a data race per the C memory model even though it
# happens to be "safe" in practice on x86 (confirmed by ThreadSanitizer,
# which is correct to flag it: nothing here guarantees the store is visible
# to another core before the numWorkers bump that gates the read, without
# an explicit synchronizes-with edge). Route every access through these two
# helpers instead of indexing `workers` directly.
proc workerGet(idx: int): ptr CspWorker {.inline.} =
  cast[ptr CspWorker](cast[ptr Atomic[pointer]](addr cspGlobalScheduler.workers[idx])[].load(moAcquire))

proc workerSet(idx: int, w: ptr CspWorker) {.inline.} =
  cast[ptr Atomic[pointer]](addr cspGlobalScheduler.workers[idx])[].store(cast[pointer](w), moRelease)


proc cspSchedulerNumProcsAdd*(delta: int) {.stackTrace: off, exportc: "csp_scheduler_num_procs_add".} =
  if cspGlobalScheduler != nil:
    discard cspGlobalScheduler.numProcs.fetchAdd(delta)

# ─── Preemption ───────────────────────────────────────────────────────────────

proc preemptionHandler(sig: cint, si: ptr SigInfo, uc: pointer) {.cdecl, stackTrace: off.} =
  if cspThisCore == nil or cspThisCore.running == nil: return
  let p = cspThisCore.running
  if p.extra == nil: return
  let extra = cast[ptr CspProcExtra](p.extra)
  if extra.preemptible and extra.inCriticalSection.load(moRelaxed) == 0:
    {.emit: """
      extern void csp_async_preempt(void);
      ucontext_t *ctx = (ucontext_t *)`uc`;
      greg_t old_rip = ctx->uc_mcontext.gregs[REG_RIP];
      ctx->uc_mcontext.gregs[REG_RSP] -= 8;
      *(greg_t *)(ctx->uc_mcontext.gregs[REG_RSP]) = old_rip;
      ctx->uc_mcontext.gregs[REG_RIP] = (greg_t)csp_async_preempt;
    """.}

proc preempterLoop(arg: pointer): pointer {.noconv, stackTrace: off.} =
  while not cspGlobalScheduler.stopPreempter.load(moRelaxed):
    discard usleep(10_000)
    let n = cspGlobalScheduler.numWorkers.load(moRelaxed)
    for i in 0 ..< n:
      let w = workerGet(i)
      if w != nil and w.tid != 0:
        discard pthread_kill(w.tid, SIGALRM)
  nil

# ─── Scheduler init ───────────────────────────────────────────────────────────

proc cspSchedulerInit*(numWorkers: int) {.stackTrace: off, exportc: "csp_scheduler_init".} =
  if cspGlobalScheduler != nil: return

  cspGlobalScheduler = cast[ptr CspScheduler](alloc0(sizeof(CspScheduler)))
  cspGlobalScheduler.numWorkers.store(numWorkers)
  # Bounded relative to actual CPU count, not a flat constant: spawning
  # more OS threads than there are CPUs can only ever help when those
  # extra threads are legitimately blocked on real I/O (cspBlock) freeing
  # up a core for someone else -- for a purely CPU-bound backlog (e.g. a
  # large synchronous burst of cspProcCreate calls), more threads than
  # CPUs is pure overhead, and a flat 1024 cap let a single-core sandbox
  # spawn ~450 threads chasing a backlog that no amount of extra OS
  # threads could actually help drain, catastrophically worsening lock
  # contention (confirmed via tests/bench_million.nim). 32x still allows
  # substantial growth for genuinely I/O-heavy workloads.
  cspGlobalScheduler.maxWorkers = max(numWorkers * 32, 256)
  cspGlobalScheduler.workers = cast[ptr UncheckedArray[ptr CspWorker]](
    alloc0(uint(cspGlobalScheduler.maxWorkers) * uint(sizeof(ptr CspWorker))))
  # Sized from cspMaxProcsHint (public, user-settable -- see corepool.nim;
  # default 100_000) rather than a hardcoded capacity. This queue is a
  # fixed-size ring buffer: once a creation burst exceeds it, producers
  # stall in a retry loop waiting for consumers to drain space, which
  # compounds badly under contention (confirmed via tests/bench_million.nim
  # -- a 3x larger burst than the old hardcoded 65536 capacity took vastly
  # longer than 3x as long under heavy single-core contention, not just
  # proportionally longer). Floor of 16 (65536) preserves the old default
  # for small/default workloads; anyone expecting bigger creation bursts
  # should set cspMaxProcsHint before calling cspInit.
  let grunqCapExp = max(cspExp(cspMaxProcsHint), 16u)
  cspGlobalScheduler.globalRunq = newGRunq(grunqCapExp)

  discard pthread_mutex_init(addr cspGlobalScheduler.lock, nil)
  discard pthread_cond_init(addr cspGlobalScheduler.cond, nil)

  let w0 = newWorker(0)
  w0.tid = pthread_self()
  cspCoreInitMain(w0.core)
  workerSet(0, w0)

  for i in 1 ..< numWorkers:
    let wi = newWorker(i)
    startWorker(wi)
    workerSet(i, wi)

  {.emit: """
    struct sigaction sa;
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = (void (*)(int, siginfo_t *, void *))`preemptionHandler`;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);
  """.}

  cspGlobalScheduler.stopPreempter.store(false)

  if getEnv("LIBCSP_PREEMPT") != "":
    var preempter: Pthread
    discard pthread_create(addr preempter, nil, preempterLoop, nil)
    discard pthread_detach(preempter)

# ─── Submit ───────────────────────────────────────────────────────────────────

proc cspSchedulerMaybeSpawnWorker*() {.stackTrace: off, exportc: "csp_scheduler_maybe_spawn_worker".} =
  if cspGlobalScheduler == nil: return

  let idle = cspGlobalScheduler.idleWorkers.load(moRelaxed)
  if idle > 0:
    # Deliberately signal WITHOUT holding cspGlobalScheduler.lock. This
    # used to lock+signal+unlock unconditionally on every single call --
    # i.e. on every cspProcCreate -- which under a large synchronous
    # creation burst meant potentially millions of acquisitions of the
    # SAME mutex that idle workers are themselves constantly contending
    # for in their own idle-check loop (see cspSchedulerGetWork), directly
    # causing severe lock-convoy stalls (confirmed via
    # tests/bench_million.nim under heavy single-core contention: a
    # supposedly-just-3x-larger creation burst took vastly more than 3x as
    # long). This is safe without the lock: POSIX does not require holding
    # the mutex to call pthread_cond_signal, only that the predicate
    # change be visible before waking; and even in the worst case where a
    # signal is missed entirely (the classic race this lock would guard
    # against), the waiter's cspSchedulerGetWork uses a bounded 10ms
    # pthread_cond_timedwait, not an unbounded wait -- so a missed signal
    # costs at most one extra 10ms poll cycle, never a hang.
    discard pthread_cond_signal(addr cspGlobalScheduler.cond)
    cspNetpollWakeup()
    return

  # No worker is currently idle, but that alone doesn't mean we need a new
  # OS thread: every existing worker may simply be a few instructions away
  # from finishing its current proc and going idle. Spawning unconditionally
  # here (as this used to) means a burst of N proc creations in quick
  # succession -- e.g. fanning out a few hundred goroutines, all created
  # before any worker has had a chance to register itself idle -- spawns up
  # to N OS threads before the first one even starts running, which is both
  # wasteful (each thread costs a stack + kernel bookkeeping) and was
  # observed to cause severe scheduling thrash / apparent hangs under a
  # 200+ goroutine stress test on a machine with few CPUs. Real growth need
  # is signaled by a *sustained* backlog, not a momentary idle-count of
  # zero, so require both a minimum backlog size and a cooldown since the
  # last spawn before growing the pool further.
  let backlog = cspGlobalScheduler.globalRunq.len()
  let nowNs = cspTimerNow()
  if backlog < WorkerSpawnMinBacklog:
    return
  var last = cspGlobalScheduler.lastSpawnNs.load(moRelaxed)
  if nowNs - last < WorkerSpawnCooldownNs:
    return
  if not cspGlobalScheduler.lastSpawnNs.compareExchange(last, nowNs):
    return # another thread just spawned one; let it take effect first

  var n = cspGlobalScheduler.numWorkers.load(moRelaxed)
  while n < cspGlobalScheduler.maxWorkers:
    if cspGlobalScheduler.numWorkers.compareExchange(n, n + 1):
      let w = newWorker(n)
      startWorker(w)
      workerSet(n, w)
      break
    n = cspGlobalScheduler.numWorkers.load(moRelaxed)

proc cspSchedulerEnqueue*(p: ptr CspProc) {.stackTrace: off, exportc: "csp_scheduler_enqueue".} =
  while not cspGlobalScheduler.globalRunq.tryPush(p):
    discard usleep(1)
  cspSchedulerMaybeSpawnWorker()

proc cspSchedulerSubmit*(p: ptr CspProc) {.stackTrace: off, exportc: "csp_scheduler_submit".} =
  if p == nil: return
  var mask, oldmask: Sigset
  discard sigemptyset(mask)
  discard sigaddset(mask, SIGALRM)
  discard pthread_sigmask(SIG_BLOCK, mask, oldmask)

  let self  = if cspThisCore != nil: cspThisCore.running else: nil
  let extra = if self != nil: cast[ptr CspProcExtra](self.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  while true:
    var oldStat = p.statGet()
    if oldStat == CspProcStatRunnable:
      # Already runnable, someone else is responsible for it.
      break
    if p.statCas(oldStat, CspProcStatRunnable):
      cspSchedulerEnqueue(p)
      break

  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  var dummy: Sigset
  discard pthread_sigmask(SIG_SETMASK, oldmask, dummy)

# cspTimerPoll/cspNetpollPoll transition a proc straight to Runnable as part
# of removing it from their internal heap/waiter structures (see poll() in
# timer.nim and the equivalent in netpoll.nim) -- they do NOT enqueue it onto
# any run queue themselves; that is left to the caller. Feeding such a proc
# through cspSchedulerSubmit is wrong: submit's "already Runnable = someone
# else is handling it" check assumes Runnable implies "already enqueued",
# which is false here, so the proc is silently dropped and never runs again
# (a real, previously-confirmed hang: the background monitor thread and a
# worker's cspSchedulerGetWork both poll the same timer heap, and whichever
# loses that race drops the proc on the floor). Callers handling poll()
# results for anything past the first proc in the returned list must use
# this instead, which enqueues unconditionally since the proc's Runnable
# state is already established and owned by the caller at this point.
proc cspSchedulerSubmitRunnable*(p: ptr CspProc) {.stackTrace: off, exportc: "csp_scheduler_submit_runnable".} =
  if p == nil: return
  cspSchedulerEnqueue(p)

# ─── Get work ─────────────────────────────────────────────────────────────────

# ─── Deadlock detection ─────────────────────────────────────────────────────
## Mirrors Go's runtime: if every worker is idle, at least one goroutine is
## still alive, and nothing armed anywhere (no timer, no registered fd)
## could ever wake any of them, the program can never make progress again.
## Report it once and terminate rather than hanging silently forever.
##
## A single instant where this looks true is NOT sufficient to report,
## though: a goroutine can be marked Runnable (via CAS) slightly before it
## is actually visible in a run queue -- the lock-free global run queue's
## push can transiently fail and retry under contention (see
## cspSchedulerEnqueue). During that narrow window every worker can
## legitimately find "no work, no timer, no I/O" even though the program
## is about to make progress. Require the condition to persist across a
## debounce window (comfortably longer than that retry loop, and longer
## than one idle-poll cycle) before concluding it's real.
const DeadlockConfirmNs = 50_000_000 # 50ms

proc cspSchedulerReportDeadlock*() {.stackTrace: off.} =
  if cspGlobalScheduler.deadlockReported.exchange(true, moSequentiallyConsistent):
    return # another worker already reported this; don't double-print/exit
  let n = cspGlobalScheduler.numProcs.load(moSequentiallyConsistent)
  let msg = "fatal error: all goroutines are asleep - deadlock!\n" &
            "  " & $n & " goroutine(s) still alive, none runnable, " &
            "no timers armed, no I/O pending.\n"
  discard posix.write(2, msg.cstring, msg.len)
  quit(2)

proc cspSchedulerCheckDeadlock*() {.stackTrace: off.} =
  let looksDeadlocked =
    cspGlobalScheduler.idleWorkers.load(moRelaxed) >= cspGlobalScheduler.numWorkers.load(moRelaxed) and
    cspGlobalScheduler.numProcs.load(moSequentiallyConsistent) > 0 and
    cspTimerPendingCount() == 0 and
    cspNetpollPendingCount() == 0
  if not looksDeadlocked:
    cspGlobalScheduler.deadlockSuspectedSinceNs.store(0, moRelaxed)
    return
  let now = cspTimerNow()
  let since = cspGlobalScheduler.deadlockSuspectedSinceNs.load(moRelaxed)
  if since == 0:
    cspGlobalScheduler.deadlockSuspectedSinceNs.store(now, moRelaxed)
  elif now - since >= DeadlockConfirmNs:
    cspSchedulerReportDeadlock()

proc cspSchedulerGetWork*(thisCore: ptr CspCore): ptr CspProc {.
    stackTrace: off, exportc: "csp_scheduler_get_work".} =
  var mask, oldmask: Sigset
  discard sigemptyset(mask)
  discard sigaddset(mask, SIGALRM)
  discard pthread_sigmask(SIG_BLOCK, mask, oldmask)

  var p: ptr CspProc = nil
  let tick = cspGlobalScheduler.schedTick.fetchAdd(1, moRelaxed)

  block workSearch:
    if tick mod 61 == 0:
      if cspGlobalScheduler.globalRunq.tryPop(p):
        break workSearch

    if thisCore.lrunq.tryPopFront(p) == LRunqOk:
      break workSearch

    if cspGlobalScheduler.globalRunq.tryPop(p):
      break workSearch

    var startT, finishT: ptr CspProc
    if cspTimerPoll(startT, finishT) > 0:
      p = startT
      var curr = startT.next
      while curr != nil:
        let next = curr.next
        curr.next = nil
        cspSchedulerSubmitRunnable(curr)
        curr = next
      p.next = nil
      break workSearch

    var startN, finishN: ptr CspProc
    if cspNetpollPoll(startN, finishN, 0) > 0:
      p = startN
      var curr = startN.next
      while curr != nil:
        let next = curr.next
        curr.next = nil
        cspSchedulerSubmitRunnable(curr)
        curr = next
      p.next = nil
      break workSearch

    let nw = cspGlobalScheduler.numWorkers.load(moRelaxed)
    for i in 0 ..< nw:
      let target = (int(thisCore.pid) + i + 1) mod nw
      let tw = workerGet(target)
      if tw != nil and tw.core != nil and tw.core.lrunq != nil:
        if tw.core.lrunq.tryPopFront(p) == LRunqOk:
          break workSearch

    discard pthread_mutex_lock(addr cspGlobalScheduler.lock)
    discard cspGlobalScheduler.idleWorkers.fetchAdd(1)

    if cspGlobalScheduler.globalRunq.tryPop(p):
      discard
    else:
      var sN, fN: ptr CspProc
      if cspNetpollPoll(sN, fN, 10) > 0:
        p = sN
        var curr = sN.next
        while curr != nil:
          let next = curr.next
          curr.next = nil
          cspSchedulerSubmitRunnable(curr)
          curr = next
        p.next = nil
      else:
        # We are, right now, the last worker with nothing left to do:
        # global queue empty, this fd-poll pass found nothing ready, and
        # every other core's local queue and the timer heaps were already
        # found empty on the way in here. If on top of that no timer is
        # armed anywhere and no fd is registered with the poller, then
        # nothing -- not a wakeup, not an I/O event, not a deadline --
        # could ever make any of the still-live goroutines runnable again.
        # That's not "idle", that's a deadlock (mirrors Go's runtime
        # "fatal error: all goroutines are asleep - deadlock!").
        cspSchedulerCheckDeadlock()
        var ts: Timespec
        discard clock_gettime(CLOCK_REALTIME, ts)
        let ns = ts.tv_nsec + 10_000_000
        ts.tv_sec = cast[Time](cast[int](ts.tv_sec) + cast[int](ns div 1_000_000_000))
        ts.tv_nsec = ns mod 1_000_000_000
        discard pthread_cond_timedwait(addr cspGlobalScheduler.cond, addr cspGlobalScheduler.lock, addr ts)

    discard cspGlobalScheduler.idleWorkers.fetchSub(1)
    discard pthread_mutex_unlock(addr cspGlobalScheduler.lock)

  var expected = CspProcStatRunnable
  if p != nil:
    if not p.statCas(expected, CspProcStatRunning):
      p = nil
    else:
      # Found a proc! Definitive proof this wasn't a real deadlock -- clear
      # any in-progress suspicion immediately rather than waiting for the
      # next idle pass to notice.
      cspGlobalScheduler.deadlockSuspectedSinceNs.store(0, moRelaxed)
      # Central choke point for the native -> goroutine TSan fiber switch
      # (see csp_tsan.nim): every restore path -- new proc, resumed
      # yield, resumed timer/netpoll wait -- reaches here before the
      # caller's asm loop physically restores this proc's stack, so
      # announcing the switch here covers all of them without needing to
      # touch the asm itself. No-op unless built with -d:cspTsanFibers.
      if p.extra != nil:
        cspTsanSwitchToFiber(cast[ptr CspProcExtra](p.extra).tsanFiber)

  var dummy: Sigset; discard pthread_sigmask(SIG_SETMASK, oldmask, dummy)
  return p
