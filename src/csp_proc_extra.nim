## proc_extra.nim
## Per-process extra state for channels, preemption guards, etc.
## Equivalent to src/proc_extra.h

import std/atomics
import csp_proc_types
import csp_tsan

type
  CspProcExtra* = object
    preemptible*:       bool
    inCriticalSection*: Atomic[int]
    chanVal*:           pointer   ## used to pass values through blocking channel ops
    chanOk*:            bool      ## whether channel recv succeeded / channel open
    selectIdx*:         int       ## winning index of a select call
    tsanFiber*:         pointer   ## nil unless built with -d:cspTsanFibers

proc newProcExtra*(): ptr CspProcExtra =
  # Allocated by whichever OS thread spawns this goroutine, but freed by
  # whichever OS thread happens to be running it when it exits -- procs are
  # not pinned to a pthread in this M:N scheduler, so this must live on the
  # thread-safe shared heap (plain alloc/dealloc use a thread-local heap and
  # will corrupt allocator state if freed on a different thread than the one
  # that allocated them).
  result = cast[ptr CspProcExtra](allocShared0(sizeof(CspProcExtra)))
  result.tsanFiber = cspTsanNewProcFiber()

proc freeProcExtra*(e: ptr CspProcExtra) =
  if e != nil:
    cspTsanFreeProcFiber(e.tsanFiber)
    deallocShared(e)

# ─── Critical section guards ──────────────────────────────────────────────────
# Defined as macros in C; in Nim we use templates.
# They depend on cspThisCore, which is declared in core.nim.
# We forward-declare the dependency here and implement the templates
# so that other modules can import just proc_extra.

template cspCriticalStart*(thisCore: untyped) =
  if thisCore != nil and thisCore.running != nil:
    let p = thisCore.running
    if p.extra != nil:
      cast[ptr CspProcExtra](p.extra).inCriticalSection.fetchAdd(1, moRelaxed)

template cspCriticalEnd*(thisCore: untyped) =
  if thisCore != nil and thisCore.running != nil:
    let p = thisCore.running
    if p.extra != nil:
      cast[ptr CspProcExtra](p.extra).inCriticalSection.fetchSub(1, moRelaxed)
