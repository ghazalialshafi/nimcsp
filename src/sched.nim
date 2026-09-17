## sched.nim
## Public CSP scheduler API.

import std/[atomics, posix, os]
import csp_proc_types
import csp_proc_extra
import runq
import rbq
import core
import corepool
import cond
import timer
import rand
import common
import scheduler
import netpoll
import monitor
import context_switch
import mem

# ─── Config ──────────────────────────────────────────────────────────────────

var cspCpuCores*   {.exportc: "csp_cpu_cores"  .}: csize_t = 0
var cspMaxThreads* {.exportc: "csp_max_threads" .}: uint = 1024
var cspMaxProcsHint* {.exportc: "csp_max_procs_hint".}: uint = 100_000

var cspSchedNp* {.exportc: "csp_sched_np".}: int = 1

var cspSchedStarvingThreads*: MmRbq[ptr CspCore]
var cspSchedStarvingProcs*:   MmRbq[ptr CspCore]

var cspInited = false

# ─── Scheduler start ─────────────────────────────────────────────────────────

proc cspSchedStart*() {.stackTrace: off, exportc: "csp_sched_start".} =
  if cspInited: return
  cspInited = true

  var np = 0
  if cspCpuCores > 0:
    np = int(cspCpuCores)
  else:
    np = int(sysconf(SC_NPROCESSORS_ONLN))
  if np <= 0: np = 1
  cspSchedNp = np

  corepool.cspSchedNp = np
  corepool.cspMaxThreads = uint(cspMaxThreads)
  corepool.cspMaxProcsHint = uint(cspMaxProcsHint)

  discard cspCorePoolsInit()
  discard cspTimerHeapsInit(np)
  discard cspNetpollInit()
  discard cspMemInit()
  discard cspMonitorInit()

  cspSchedStarvingThreads = newMmRbq[ptr CspCore](cspExp(uint(np)))
  cspSchedStarvingProcs   = newMmRbq[ptr CspCore](cspExp(uint(np)))

  cspSchedulerInit(np)

proc cspInit*(ncores: int = 0) {.stackTrace: off, exportc: "csp_init".} =
  if cspInited: return
  if ncores > 0:
    cspCpuCores = csize_t(ncores)
  cspSchedStart()

# ─── Scheduler API ────────────────────────────────────────────────────────────

proc cspSchedPutProc*(p: ptr CspProc) {.stackTrace: off, exportc: "csp_sched_put_proc".} =
  if cspGlobalScheduler != nil:
    cspSchedulerSubmit(p)
  elif cspThisCore != nil:
    cspThisCore.lrunq.pushFront(p)

proc cspSchedPutTimer*(p: ptr CspProc): ptr CspProc {.stackTrace: off, exportc: "csp_sched_put_timer".} =
  cspTimerPut(cspThisCore.pid, p)
  p

proc cspSchedGet*(thisCore: ptr CspCore): ptr CspProc {.stackTrace: off, exportc: "csp_sched_get".} =
  if thisCore == nil: return nil
  if cspGlobalScheduler != nil:
    return cspSchedulerGetWork(thisCore)
  return nil

proc cspSchedYield*() {.stackTrace: off, exportc: "csp_sched_yield".} =
  let core = cspThisCore
  if core != nil and core.running != nil:
    let p = core.running
    # Unlike cspSchedHangup (registers with the timer heap) or the
    # mutex/channel blocking paths (enqueue onto a wait list), a plain
    # yield has no other data structure holding a reference to this proc.
    # It must be explicitly re-submitted to a run queue before we give up
    # this OS thread via cspCoreYield, or the proc is simply lost forever
    # once we jump back to the anchor -- a real, previously-confirmed hang
    # (nothing calling cspYield()/cspSchedYield() mid-execution, e.g. while
    # holding a mutex, ever got scheduled again).
    p.statSet(CspProcStatRunnable)
    core.running = nil
    cspSchedulerEnqueue(p)
    cspCoreYield(p, addr core.anchor)
  else:
    discard usleep(100)

proc cspSchedHangup*(nanoseconds: uint64) {.stackTrace: off, exportc: "csp_sched_hangup".} =
  if nanoseconds == 0: return
  let core    = cspThisCore
  if core == nil: return
  let running = core.running
  if running == nil: return
  running.statSet(CspProcStatBlocked)
  running.timer.when_ns = cspTimerNow() + int64(nanoseconds)
  cspTimerPut(core.pid, running)
  core.running = nil
  cspCoreYield(running, addr core.anchor)

proc cspSchedProcAnchor*(needSync: bool) {.
    stackTrace: off, noInline, exportc: "csp_sched_proc_anchor".} = discard

proc cspSchedAtomicIncr*(cnt: ptr Atomic[uint64]) {.
    stackTrace: off, noInline, exportc: "csp_sched_atomic_incr".} = discard
