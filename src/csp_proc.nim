## proc.nim
## Process (goroutine) allocation, management, and destruction.

import std/[atomics, strutils]
import csp_proc_types
import csp_proc_extra
import core
import context_switch
import mem

# ─── Config ──────────────────────────────────────────────────────────────────

var cspProcsNum*  {.exportc: "csp_procs_num" .}: csize_t  = 1
var cspProcsSize* {.exportc: "csp_procs_size".}: array[4, csize_t] = [131072.csize_t, 131072, 131072, 131072]

# Forward-declared from scheduler.nim
proc cspSchedulerNumProcsAdd(delta: int) {.importc: "csp_scheduler_num_procs_add".}
proc cspSchedPutProc(p: ptr CspProc) {.importc: "csp_sched_put_proc".}

# ─── Proc creation ────────────────────────────────────────────────────────────

proc cspProcNew*(id: int, waitedByParent: bool): ptr CspProc {.
    exportc: "csp_proc_new".} =
  let size = uint(cspProcsSize[id mod cspProcsSize.len])
  let pid = if cspThisCore != nil: cspThisCore.pid else: 0

  let base = cast[uint](cspMemAlloc(pid, size))
  if base == 0:
    quit("libcsp: failed to allocate proc memory")

  let p = cast[ptr CspProc](base + size - uint(sizeof(CspProc)))
  p.base      = base
  p.isNew     = CspProcIsNew
  p.bornedPid = if cspThisCore != nil: cspThisCore.pid else: 0
  p.stat.store(CspProcStatNone)
  p.yielded.store(1)
  # SANE DEFAULT FP STATE — not zero. mxcsr/x87cw are only ever written by
  # the context-switch asm's stmxcsr/fstcw when a proc that has actually
  # RUN gets yielded (see context_switch.nim). A proc's first-ever restore
  # loads whatever happens to already be in these fields, which is
  # otherwise uninitialized allocator memory. A zeroed MXCSR unmasks every
  # floating-point exception (bits 7-12 = 0 means unmasked, not the
  # default-masked state the x86-64 ABI expects) -- including Precision,
  # which fires on almost any inexact division. A goroutine's very first
  # floating-point operation, on memory that happens to be freshly
  # allocated (zeroed) rather than reused from a previously-run proc
  # (whose real, sane saved value would otherwise mask this by luck), then
  # raises SIGFPE on completely ordinary arithmetic. Confirmed via
  # tests/bench_context_switch.nim, which crashed inside std/times'
  # epochTime() -- an entirely unrelated, entirely ordinary float division
  # -- for exactly this reason. 0x1F80 / 0x037F are the real x86-64 ABI
  # reset defaults: all FP exceptions masked, round-to-nearest.
  p.mxcsr     = 0x1F80'u32
  p.x87cw     = 0x037F'u32

  p.rbp = uint64(cast[uint](p) - (if (cast[uint](p) and 0x0f) != 0: 8u else: 0u))

  p.nchild.store(0)
  p.parent = if waitedByParent and cspThisCore != nil: cspThisCore.running else: nil
  p.extra  = newProcExtra()

  cspSchedulerNumProcsAdd(1)
  p

proc cspProcInit*(p: ptr CspProc, fn: pointer, arg: pointer) {.exportc: "csp_proc_init".} =
  p.isNew = CspProcIsNew
  p.registers.calleeSaved.rbx = cast[uint64](fn)
  p.registers.calleeSaved.r12 = cast[uint64](arg)

  # rsp points to the return address for retq in cspProcRestore
  let entryStack = cast[ptr uint64](p.rbp - 8)
  entryStack[] = cast[uint64](cspProcEntry)
  p.rsp = cast[uint64](entryStack)

proc cspProcCreate*(id: int, fn: proc(arg: pointer) {.cdecl.}, arg: pointer): ptr CspProc {.
    exportc: "csp_proc_create".} =
  let p = cspProcNew(id, false)
  cspProcInit(p, cast[pointer](fn), arg)
  cast[ptr CspProcExtra](p.extra).preemptible = true
  cspSchedPutProc(p)
  p

proc cspProcNchildSet*(nchild: csize_t) {.exportc: "csp_proc_nchild_set".} =
  if cspThisCore != nil and cspThisCore.running != nil:
    cast[ptr CspProc](cspThisCore.running).nchild.store(uint64(nchild))

proc cspProcDestroy*(p: ptr CspProc) {.exportc: "csp_proc_destroy".} =
  cspSchedulerNumProcsAdd(-1)
  if p.extra != nil:
    freeProcExtra(cast[ptr CspProcExtra](p.extra))
    p.extra = nil

  let pid = p.bornedPid
  cspMemFree(pid, cast[pointer](p.base))
