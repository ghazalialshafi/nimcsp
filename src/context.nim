## context.nim
## Go-style cancellable contexts: WithCancel, WithDeadline, WithTimeout,
## plus Err() to distinguish why a context finished.

import std/atomics
import csp_proc_types
import chan
import csp_proc
import timer
import timer_ext

type
  CspContextErr* {.pure.} = enum
    None, Canceled, DeadlineExceeded

  CspContext* = object
    done*:      ptr CspGoChan
    parent*:    ptr CspContext
    canceled*:  Atomic[bool]
    err*:       Atomic[int]        ## CspContextErr, stored as int for atomics
    timerChan*: ptr CspGoChan      ## nil unless this context has a deadline
    isValueOnly*: bool  ## true for nodes created by cspContextWithValue --
                         ## they carry no cancellation scope of their own;
                         ## Done()/Err() walk up to the nearest ancestor
                         ## that does.
    hasValue*:  bool
    valKey*:    cstring  ## raw, not Nim `string`: this struct lives on the
                          ## shared heap outside ARC's reach, so no GC'd
                          ## field types belong in it (same reasoning as
                          ## every other cross-thread struct in this
                          ## runtime -- see mem-management notes elsewhere).
    valPtr*:    pointer

## Contexts are handed across goroutines by design (a cancel/timeout
## propagates to however many goroutines received the ctx pointer, on
## however many OS threads they end up scheduled on), so -- like every
## other cross-thread-lived object in this runtime -- they must live on
## the shared heap, not Nim's default thread-local alloc/dealloc.
proc newCspContext(): ptr CspContext =
  result = cast[ptr CspContext](allocShared0(sizeof(CspContext)))
  result.err.store(ord(CspContextErr.None))

proc cspContextBackground*(): ptr CspContext {.exportc: "csp_context_background".} =
  result = newCspContext()
  result.done = newGoChan(0)

proc cspContextErr*(ctx: ptr CspContext): CspContextErr {.exportc: "csp_context_err".} =
  var c = ctx
  while c != nil and c.isValueOnly:
    c = c.parent
  if c == nil: return CspContextErr.None
  CspContextErr(c.err.load(moAcquire))

proc finishCtx(ctx: ptr CspContext, reason: CspContextErr) =
  if not ctx.canceled.exchange(true, moSequentiallyConsistent):
    ctx.err.store(ord(reason), moRelease)
    closeGoChan(ctx.done)

proc contextPropagate(arg: pointer) {.cdecl.} =
  let ctx = cast[ptr CspContext](arg)
  var ok: bool
  discard recvGoChan(ctx.parent.done, addr ok)
  # Parent finished (canceled or timed out) -- Go reports this as Canceled
  # on the child regardless of the parent's own specific reason; the
  # parent's own ctx.Err() still carries its own DeadlineExceeded if that's
  # what actually happened up there.
  finishCtx(ctx, CspContextErr.Canceled)

proc cspContextWithCancel*(parent: ptr CspContext): ptr CspContext {.
    exportc: "csp_context_with_cancel".} =
  result = newCspContext()
  result.done   = newGoChan(0)
  result.parent = parent
  if parent != nil and parent.done != nil:
    discard cspProcCreate(0, contextPropagate, result)

proc cspContextCancel*(ctx: ptr CspContext) {.exportc: "csp_context_cancel".} =
  if ctx != nil: finishCtx(ctx, CspContextErr.Canceled)

proc cspContextDone*(ctx: ptr CspContext): ptr CspGoChan {.exportc: "csp_context_done".} =
  var c = ctx
  while c != nil and c.isValueOnly:
    c = c.parent
  if c == nil: return nil
  c.done

proc contextDeadlineWatcher(arg: pointer) {.cdecl.} =
  let ctx = cast[ptr CspContext](arg)
  var ok: bool
  discard recvGoChan(ctx.timerChan, addr ok)
  # If the context already finished for another reason (explicit cancel, or
  # racing against a parent that finished first) finishCtx is a no-op here
  # thanks to the `canceled` CAS -- whichever reason lands first wins, which
  # matches Go's ctx.Err() being fixed at the moment of first cancellation.
  finishCtx(ctx, CspContextErr.DeadlineExceeded)

proc cspContextWithDeadline*(parent: ptr CspContext, deadlineNs: int64): ptr CspContext {.
    exportc: "csp_context_with_deadline".} =
  result = newCspContext()
  result.done   = newGoChan(0)
  result.parent = parent
  let nowNs = cspTimerNow()
  let remaining = if deadlineNs > nowNs: deadlineNs - nowNs else: 0'i64
  result.timerChan = cspTimeAfter(CspTimerDuration(remaining))
  discard cspProcCreate(0, contextDeadlineWatcher, result)
  if parent != nil and parent.done != nil:
    discard cspProcCreate(0, contextPropagate, result)

proc cspContextWithTimeout*(parent: ptr CspContext, durationNs: int64): ptr CspContext {.
    exportc: "csp_context_with_timeout".} =
  cspContextWithDeadline(parent, cspTimerNow() + durationNs)

## Returns a child context carrying one key-value pair. It has no
## cancellation scope of its own: Done()/Err() on it (and on any further
## descendant) walk up to the nearest ancestor that does, matching Go's
## context.WithValue semantics (cancellation and values are independent
## axes -- WithValue never creates a new Done channel).
proc cspContextWithValue*(parent: ptr CspContext, key: cstring, val: pointer): ptr CspContext {.
    exportc: "csp_context_with_value".} =
  result = newCspContext()
  result.parent      = parent
  result.isValueOnly = true
  result.hasValue     = true
  result.valKey       = key
  result.valPtr       = val

## Walks up the context chain (through value-only nodes and cancellation
## scopes alike) and returns the value stored under `key` by the nearest
## ancestor (including `ctx` itself) that has one, or nil if none does.
proc cspContextValue*(ctx: ptr CspContext, key: cstring): pointer {.exportc: "csp_context_value".} =
  var c = ctx
  while c != nil:
    if c.hasValue and c.valKey == key:
      return c.valPtr
    c = c.parent
  nil
