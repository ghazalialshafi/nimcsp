## runtime.nim
## Runtime statistics and introspection.

import std/[atomics, strformat]
import scheduler

proc runtimeNumGoroutines*(): int {.exportc: "runtime_num_goroutines".} =
  if cspGlobalScheduler != nil:
    cspGlobalScheduler.numProcs.load(moSequentiallyConsistent)
  else: 0

proc runtimeNumWorkers*(): int {.exportc: "runtime_num_workers".} =
  if cspGlobalScheduler != nil:
    cspGlobalScheduler.numWorkers.load(moSequentiallyConsistent)
  else: 0

proc runtimeDump*() {.exportc: "runtime_dump".} =
  echo "Runtime Stats:"
  echo &"  Goroutines: {runtimeNumGoroutines()}"
  echo &"  Workers:    {runtimeNumWorkers()}"

proc runtimeTraceEnable*(enable: bool) {.exportc: "runtime_trace_enable".} =
  discard
