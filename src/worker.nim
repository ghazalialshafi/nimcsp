## worker.nim
## OS worker thread that drives a CspCore.
## Equivalent to src/worker.h + src/worker.c

import std/posix
import csp_proc_types
import core
import corepool

type
  CspWorker* = object
    id*:   int
    tid*:  Pthread
    core*: ptr CspCore

proc newWorker*(id: int): ptr CspWorker {.exportc: "csp_worker_new".} =
  result = cast[ptr CspWorker](alloc0(sizeof(CspWorker)))
  result.id   = id
  result.core = cspCorePoolGet(uint(id))
  result.core.worker = result

proc workerLoop*(arg: pointer): pointer {.noconv, exportc: "csp_worker_loop".} =
  let worker = cast[ptr CspWorker](arg)
  discard cspCoreRun(worker.core)
  nil

proc startWorker*(worker: ptr CspWorker) {.exportc: "csp_worker_start".} =
  discard pthread_create(addr worker.tid, nil, workerLoop, worker)
