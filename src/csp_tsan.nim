## csp_tsan.nim
## Optional ThreadSanitizer fiber-switch annotations.
##
## Only compiled in under -d:cspTsanFibers (see tests/run_all.sh /
## README.md for how to build a TSan-instrumented binary). Without that
## flag every proc here is a complete no-op and the __tsan_* symbols are
## never referenced, so normal (non-TSan) builds are entirely unaffected.
##
## Why this exists: this runtime switches physical stacks by hand (see
## context_switch.nim). Vanilla ThreadSanitizer has no way to know that --
## it tracks "the current execution context" per OS thread assuming normal
## call/return control flow, and a `jmp`-based stack switch violates that
## assumption, corrupting TSan's own internal bookkeeping (observed during
## development as TSan crashing inside its own StackDepot code, not in any
## code this library owns). LLVM's compiler-rt ships a public fiber API
## (__tsan_create_fiber / __tsan_switch_to_fiber / __tsan_destroy_fiber)
## specifically for coroutine/fiber libraries like this one to announce
## switches explicitly. This module wires that up.
##
## What is annotated, deliberately, at the Nim level only (never inside the
## naked-asm context-switch primitives themselves, to keep zero risk to
## that already carefully-verified code):
##   - Each goroutine gets its own fiber, created in newProcExtra and
##     destroyed in freeProcExtra (csp_proc_extra.nim).
##   - Each OS thread's own "native" scheduler context is captured as a
##     fiber once, the first time it's needed.
##   - The goroutine -> native transition is announced right before every
##     call into the raw (asm) cspCoreYield / cspCoreProcExitInner.
##   - The native -> goroutine transition is announced once, centrally, in
##     cspSchedulerGetWork right before it hands a proc back to be
##     restored -- this is the single choke point every restore path goes
##     through, so it covers all of them without needing to touch the asm.

when defined(cspTsanFibers):
  proc tsanCreateFiber(flags: cuint): pointer {.importc: "__tsan_create_fiber", cdecl.}
  proc tsanDestroyFiber(f: pointer) {.importc: "__tsan_destroy_fiber", cdecl.}
  proc tsanSwitchToFiber(f: pointer, flags: cuint) {.importc: "__tsan_switch_to_fiber", cdecl.}
  proc tsanGetCurrentFiber(): pointer {.importc: "__tsan_get_current_fiber", cdecl.}

  var nativeFiber {.threadvar.}: pointer ## this OS thread's own context

  proc cspTsanNewProcFiber*(): pointer {.inline.} =
    tsanCreateFiber(0)

  proc cspTsanFreeProcFiber*(f: pointer) {.inline.} =
    if f != nil: tsanDestroyFiber(f)

  proc cspTsanSwitchToNative*() {.inline.} =
    if nativeFiber == nil:
      nativeFiber = tsanGetCurrentFiber()
    tsanSwitchToFiber(nativeFiber, 0)

  proc cspTsanSwitchToFiber*(f: pointer) {.inline.} =
    if f != nil: tsanSwitchToFiber(f, 0)

else:
  proc cspTsanNewProcFiber*(): pointer {.inline.} = nil
  proc cspTsanFreeProcFiber*(f: pointer) {.inline.} = discard
  proc cspTsanSwitchToNative*() {.inline.} = discard
  proc cspTsanSwitchToFiber*(f: pointer) {.inline.} = discard
