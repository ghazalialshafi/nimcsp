## corepool.nim
## Pool of per-CPU execution cores.
## Equivalent to src/corepool.h + src/corepool.c

import std/atomics
import csp_proc_types
import runq
import core
import mutex
import common

# ─── Globals from sched.nim (forward) ─────────────────────────────────────────

var cspSchedNp*:         int = 1
var cspMaxThreads*:      uint = 1024
var cspMaxProcsHint*:    uint = 100_000

# ─── Pool of cores for one CPU ───────────────────────────────────────────────

type
  CspCorePool* = object
    cap*:   uint
    top*:   uint
    cores*: ptr UncheckedArray[ptr CspCore]
    grunq*: GRunq
    mutex*: CspMutex

  CspCorePools* = object
    len*:   uint
    pools*: ptr UncheckedArray[ptr CspCorePool]

var cspCorePools* {.exportc: "csp_core_pools".}: CspCorePools

proc newCorePool(pid: int, grunqCapExp: uint, coresPerCpu: uint): ptr CspCorePool =
  let pool = cast[ptr CspCorePool](alloc0(sizeof(CspCorePool)))
  if pool == nil: return nil

  pool.grunq = newGRunq(grunqCapExp)
  pool.cores = cast[ptr UncheckedArray[ptr CspCore]](
    alloc0(coresPerCpu.uint * uint(sizeof(ptr CspCore))))

  if pool.grunq == nil or pool.cores == nil:
    dealloc(pool)
    return nil

  for i in 0 ..< coresPerCpu:
    # Each core gets its own LRunq
    pool.cores[i] = newCore(uint(pid), newLRunq(), pool.grunq)
    if pool.cores[i] == nil:
      pool.cap = uint(i)
      return nil

  pool.cap = coresPerCpu
  pool.top = coresPerCpu
  pool.mutex.init()
  pool

proc poolPush(pool: ptr CspCorePool, core: ptr CspCore) =
  pool.mutex.lock()
  pool.cores[pool.top] = core
  pool.top += 1
  pool.mutex.unlock()

proc poolPop(pool: ptr CspCorePool, core: var ptr CspCore): bool =
  pool.mutex.lock()
  if pool.top == 0:
    pool.mutex.unlock()
    return false
  pool.top -= 1
  core = pool.cores[pool.top]
  pool.mutex.unlock()
  true

proc cspCorePoolsInit*(): bool {.exportc: "csp_core_pools_init".} =
  cspCorePools.pools = cast[ptr UncheckedArray[ptr CspCorePool]](
    alloc0(uint(cspSchedNp) * uint(sizeof(ptr CspCorePool))))
  if cspCorePools.pools == nil: return false

  let grunqCapExp   = cspExp(cspMaxProcsHint div uint(cspSchedNp))
  let coresPerCpu   = (cspMaxThreads div uint(cspSchedNp)) +
                      (if cspMaxThreads mod uint(cspSchedNp) != 0: 1u else: 0u)

  for i in 0 ..< cspSchedNp:
    cspCorePools.pools[i] = newCorePool(i, grunqCapExp, coresPerCpu)
    if cspCorePools.pools[i] == nil:
      cspCorePools.len = uint(i)
      return false

  cspCorePools.len = uint(cspSchedNp)
  true

proc cspCorePoolsGet*(pid: uint, core: var ptr CspCore): bool {.
    exportc: "csp_core_pools_get".} =
  poolPop(cspCorePools.pools[pid mod cspCorePools.len], core)

proc cspCorePoolsPut*(core: ptr CspCore) {.exportc: "csp_core_pools_put".} =
  poolPush(cspCorePools.pools[core.pid mod cspCorePools.len], core)

proc cspCorePoolGet*(pid: uint): ptr CspCore {.exportc: "csp_core_pool_get".} =
  var c: ptr CspCore
  discard cspCorePoolsGet(pid, c)
  c

proc cspCorePoolsDestroy*() {.exportc: "csp_core_pools_destroy".} =
  if cspCorePools.pools == nil: return
  for i in 0 ..< cspCorePools.len:
    let pool = cspCorePools.pools[i]
    for j in 0 ..< pool.cap:
      if pool.cores[j] != nil:
        destroyCore(pool.cores[j])
    dealloc(pool.cores)
    dealloc(pool)
  dealloc(cspCorePools.pools)
