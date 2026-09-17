## core.nim
## Per-OS-thread execution core.

import std/[atomics, posix]
import csp_proc_types
import csp_proc_extra
import runq
import rbq
import cond
import context_switch
import csp_tsan

# ─── Core state ───────────────────────────────────────────────────────────────

type
  CspCoreState* {.pure.} = enum
    Inited  = 0
    Running = 1
    Stopped = 2

  CspCore* = object
    anchor*:  CspAnchor           # 0x00
    running*: ptr CspProc         # 0x40
    tid*:     Pthread             # 0x48
    pid*:     uint                # 0x50
    state*:   Atomic[CspCoreState]# 0x58
    lrunq*:   LRunq               # 0x60
    grunq*:   GRunq               # 0x68
    mutex*:   Pthread_mutex       # 0x70
    cond*:    Pthread_cond
    pcond*:   CspCond             ## process-level condition
    worker*:  pointer
    padding*: array[64, byte]

var cspThisCore* {.threadvar, exportc: "csp_this_core".}: ptr CspCore

# See the layout-guard comment in csp_proc_types.nim. `state` is a
# {.pure.} enum with 3 values, so Nim packs it into a single byte — the
# hand-written asm in cspCoreRun below MUST use a byte-width instruction
# (cmpb) against it, not a 32-bit cmpl, or it reads 3 bytes of adjacent
# uninitialized padding as part of the comparison (this was an actual bug,
# fixed alongside these asserts: an optimization-level-dependent segfault
# caused by exactly this mismatch).
static:
  doAssert offsetof(CspCore, running) == 0x40
  doAssert offsetof(CspCore, tid)     == 0x48
  doAssert offsetof(CspCore, pid)     == 0x50
  doAssert offsetof(CspCore, state)   == 0x58
  doAssert sizeof(CspCore.state) == 1

# ─── Forward declarations ───────────────────────────────────────────────────

proc cspSchedGet(core: ptr CspCore): ptr CspProc {.importc: "csp_sched_get".}
proc cspCorePoolsPut(core: ptr CspCore) {.importc: "csp_core_pools_put".}
proc cspCorePoolsGet(pid: uint, core: var ptr CspCore): bool {.importc: "csp_core_pools_get".}
proc cspProcDestroy(p: ptr CspProc) {.importc: "csp_proc_destroy".}
proc cspSchedulerSubmit(p: ptr CspProc) {.importc: "csp_scheduler_submit".}
proc cspSchedulerMaybeSpawnWorker() {.importc: "csp_scheduler_maybe_spawn_worker".}

# ─── Core creation / destruction ─────────────────────────────────────────────

proc newCore*(pid: uint, lrunq: LRunq, grunq: GRunq): ptr CspCore =
  result = cast[ptr CspCore](alloc0(sizeof(CspCore)))
  if result == nil: return nil
  result.pid   = pid
  result.lrunq = lrunq
  result.grunq = grunq
  result.running = nil
  result.state.store(CspCoreState.Inited)
  discard pthread_mutex_init(addr result.mutex, nil)
  discard pthread_cond_init(addr result.cond, nil)
  result.pcond.init()

proc destroyCore*(core: ptr CspCore) =
  if core != nil:
    core.state.store(CspCoreState.Stopped)
    if core.lrunq != nil:
      destroyLRunq(core.lrunq)
    discard pthread_mutex_destroy(addr core.mutex)
    discard pthread_cond_destroy(addr core.cond)
    dealloc(core)

# ─── Core wakeup ─────────────────────────────────────────────────────────────

proc wakeup*(core: ptr CspCore) =
  discard pthread_mutex_lock(addr core.mutex)
  discard pthread_cond_signal(addr core.cond)
  discard pthread_mutex_unlock(addr core.mutex)

# ─── Block Prologue/Epilogue ──────────────────────────────────────────────────

proc cspCoreBlockPrologue*(core: ptr CspCore): bool {.
    exportc: "csp_core_block_prologue".} =
  if core == nil: return false
  cspCorePoolsPut(core)
  cspSchedulerMaybeSpawnWorker()
  true

proc cspCoreBlockEpilogueInner(p: ptr CspProc, pidHint: uint) {.
    used, exportc: "csp_core_block_epilogue_inner".} =
  var newCore: ptr CspCore = nil
  while not cspCorePoolsGet(pidHint, newCore):
    discard usleep(100)

  cspThisCore = newCore
  newCore.running = p

proc cspCoreBlockEpilogue*(p: ptr CspProc, pidHint: uint) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_block_epilogue".} =
  {.emit: """
    __asm__ __volatile__(
      "push %%rdi\n"
      "push %%rsi\n"
      "push %%rdx\n"
      "push %%rcx\n"
      "push %%r8\n"
      "push %%r9\n"
      "push %%r11\n"
      "call csp_core_block_epilogue_inner@plt\n"
      "pop %%r11\n"
      "pop %%r9\n"
      "pop %%r8\n"
      "pop %%rcx\n"
      "pop %%rdx\n"
      "pop %%rsi\n"
      "pop %%rdi\n"
      "retq\n"
      ::: "memory"
    );
  """.}

# ─── Proc exit ────────────────────────────────────────────────────────────────

proc cspCoreProcExitInner*(p: ptr CspProc, anchor: ptr CspAnchor) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_proc_exit_inner".} =
  {.emit: """
    __asm__ __volatile__(
      /* anchor.rsp is already call-site-aligned (see the comment on
         cspCoreAnchorSave) -- no extra alignment adjustment needed before
         calling csp_proc_destroy. */
      "push %%r12\n"
      "mov %%rsi, %%r12\n"
      "mov 0x00(%%rsi), %%rbp\n"
      "mov 0x08(%%rsi), %%rsp\n"
      "call csp_proc_destroy@plt\n"
      "mov %%r12, %%rdi\n"
      "call csp_core_anchor_restore@plt\n"
      "pop %%r12\n"
      "retq\n"
      ::: "memory"
    );
  """.}

proc cspCoreProcExit*() {.stackTrace: off, exportc: "csp_core_proc_exit".} =
  let core = cspThisCore
  if core == nil: return
  let running = core.running
  if running == nil: return
  let parent = running.parent
  if parent != nil and parent.nchildDecr() == 1:
    cspSchedulerSubmit(parent)
  core.running = nil
  cspTsanSwitchToNative()
  cspCoreProcExitInner(running, addr core.anchor)

# ─── Main scheduler loop (per OS thread) ─────────────────────────────────────

proc cspCoreRun*(data: pointer): pointer {.noconv, exportc: "csp_core_run".} =
  let core = cast[ptr CspCore](data)
  if core == nil: return nil
  core.state.store(CspCoreState.Running)
  cspThisCore = core

  {.emit: """
    __asm__ __volatile__(
      "push %%rbp\n"
      "push %%rbx\n"
      "push %%r12\n"
      "push %%r13\n"
      "push %%r14\n"
      "push %%r15\n"
      "mov %[core_ptr], %%r12\n"
      "1:\n"
      "cmpb $1, 0x58(%%r12)\n"
      "jne 2f\n"
      "mov %%r12, %%rdi\n"
      "call csp_core_anchor_save@plt\n"
      "mov %%r12, %%rdi\n"
      "call csp_sched_get@plt\n"
      "test %%rax, %%rax\n"
      "jz 3f\n"
      "mov %%rax, 0x40(%%r12)\n"
      "mov %%rax, %%rdi\n"
      "call csp_proc_restore@plt\n"
      "jmp 1b\n"
      "3:\n"
      "mov $0, %%rdi\n"
      "sub $16, %%rsp\n"
      "movq $0, (%%rsp)\n"
      "movq $1000000, 8(%%rsp)\n"
      "mov %%rsp, %%rdi\n"
      "xor %%rsi, %%rsi\n"
      "call nanosleep@plt\n"
      "add $16, %%rsp\n"
      "jmp 1b\n"
      "2:\n"
      "pop %%r15\n"
      "pop %%r14\n"
      "pop %%r13\n"
      "pop %%r12\n"
      "pop %%rbx\n"
      "pop %%rbp\n"
      :
      : [core_ptr] "r"(`core`)
      : "rax", "rdi", "rsi", "rdx", "rcx", "r8", "r9", "r10", "r11", "memory"
    );
  """.}
  nil

proc cspCoreInitMain*(core: ptr CspCore) {.exportc: "csp_core_init_main".} =
  core.tid = pthread_self()
  cspThisCore = core
  {.emit: """
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(0, &cpuset);
    pthread_setaffinity_np(`core`->tid, sizeof(cpu_set_t), &cpuset);
  """.}

proc cspCoreStart*(core: ptr CspCore): bool {.exportc: "csp_core_start".} =
  var attr: Pthread_attr
  if pthread_attr_init(addr attr) != 0: return false
  if pthread_attr_setdetachstate(addr attr, PTHREAD_CREATE_DETACHED) != 0: return false
  var tid: Pthread
  if pthread_create(addr tid, addr attr, cspCoreRun, core) != 0: return false
  discard pthread_attr_destroy(addr attr)
  true

# ─── Preemption helper ────────────────────────────────────────────────────────

proc cspPreemptHelper*(sp: uint) {.exportc: "csp_preempt_helper".} =
  let core = cspThisCore
  if core == nil: return
  let p    = core.running
  if p == nil: return
  p.rsp    = sp
  p.isNew  = CspProcIsPreempt
  {.emit: """__asm__ __volatile__("stmxcsr %0" : "=m"(`p`->mxcsr));""".}
  {.emit: """__asm__ __volatile__("fstcw %0"   : "=m"(`p`->x87cw));""".}
  core.running = nil
  proc cspPreemptSwitchAndSubmit(rsp, rbp: uint, p: ptr CspProc, anchor: ptr CspAnchor) {.
      stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", importc: "csp_preempt_switch_and_submit".}
  cspPreemptSwitchAndSubmit(uint(core.anchor.rsp), uint(core.anchor.rbp), p, addr core.anchor)

proc cspPreemptSwitchAndSubmit*(rsp, rbp: uint, p: ptr CspProc, anchor: ptr CspAnchor) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_preempt_switch_and_submit".} =
  {.emit: """
    __asm__ __volatile__(
      "mov %%rdi, %%rsp\n"
      "mov %%rsi, %%rbp\n"
      "sub $16, %%rsp\n"
      "/* Set yielded = 1 */\n"
      "movq $1, 0x68(%%rdx)\n"
      "push %%rcx\n"
      "mov %%rdx, %%rdi\n"
      "call csp_scheduler_submit@plt\n"
      "pop %%rdi\n"
      "call csp_core_anchor_restore@plt\n"
      "retq\n"
      ::: "memory"
    );
  """.}

proc cspCoreProcExitAndRunInner*(toRun: ptr CspProc, running: ptr CspProc, rbp: uint64, rsp: uint64) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_proc_exit_and_run_inner".} =
  {.emit: """
    __asm__ __volatile__(
      "mov %%rdx, %%rbp\n"
      "mov %%rcx, %%rsp\n"
      "push %%rdi\n" /* save toRun on stack */
      "mov %%rsi, %%rdi\n" /* rdi = running */
      "sub $8, %%rsp\n" /* alignment */
      "call csp_proc_destroy@plt\n"
      "add $8, %%rsp\n"
      "pop %%rdi\n" /* restore toRun to rdi */
      "call csp_proc_restore@plt\n"
      "retq\n"
      ::: "memory"
    );
  """.}

proc cspCoreProcExitAndRun*(toRun: ptr CspProc) {.exportc: "csp_core_proc_exit_and_run".} =
  let core    = cspThisCore
  if core == nil: return
  let running = core.running
  core.running = toRun
  cspCoreProcExitAndRunInner(toRun, running, uint64(core.anchor.rbp), uint64(core.anchor.rsp))
