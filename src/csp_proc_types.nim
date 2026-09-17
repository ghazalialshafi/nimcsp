## proc_types.nim
## Process (goroutine) type definitions.

import std/atomics

const
  CspProcStatNone*            = 0u64
  CspProcStatNetpollWaiting*  = 1u64
  CspProcStatNetpollAvail*    = 2u64
  CspProcStatNetpollTimeout*  = 3u64
  CspProcStatRunnable*        = 4u64
  CspProcStatRunning*         = 5u64
  CspProcStatBlocked*         = 6u64

  CspProcIsNormal*   = 0u64
  CspProcIsNew*      = 1u64
  CspProcIsPreempt*  = 2u64

type
  CspProcTimerInfo* = object
    when_ns*: int64
    idx*:     int64
    token*:   Atomic[int64]

  CspProcRegisters* {.union.} = object
    calleeSaved*: tuple[rbx, r12, r13, r14, r15: uint64]
    callerSaved*: tuple[rdi, rsi, rdx, rcx, r8, r9: uint64]

  ## Offsets:
  ## 0x00: base
  ## 0x08: bornedPid
  ## 0x10: isNew
  ## 0x18: stat
  ## 0x20: mxcsr
  ## 0x24: x87cw
  ## 0x28: rsp
  ## 0x30: rbp
  ## 0x38: registers (union, size 48)
  ## 0x68: yielded
  CspProc* = object
    base*:       uint64           # 0x00
    bornedPid*:  uint             # 0x08
    isNew*:      uint64           # 0x10
    stat*:       Atomic[uint64]   # 0x18
    mxcsr*:      uint32           # 0x20
    x87cw*:      uint32           # 0x24
    rsp*:        uint64           # 0x28
    rbp*:        uint64           # 0x30
    registers*:  CspProcRegisters # 0x38
    yielded*:    Atomic[uint64]   # 0x68
    timer*:      CspProcTimerInfo
    parent*:     ptr CspProc
    pre*, next*: ptr CspProc
    nchild*:     Atomic[uint64]
    extra*:      pointer
    padding*:    array[56, byte]

# ─── Layout guards ────────────────────────────────────────────────────────────
# The hand-written x86-64 asm in context_switch.nim/core.nim hardcodes these
# byte offsets and access widths. If the struct layout ever drifts (field
# reordering, a new field, a change in an enum's packed size, etc.) these
# static asserts turn what would otherwise be an intermittent, optimization-
# level-dependent segfault into a compile error. Do not remove without
# updating the corresponding {.emit.} blocks.
static:
  doAssert offsetof(CspProc, base)      == 0x00
  doAssert offsetof(CspProc, bornedPid) == 0x08
  doAssert offsetof(CspProc, isNew)     == 0x10
  doAssert offsetof(CspProc, stat)      == 0x18
  doAssert offsetof(CspProc, mxcsr)     == 0x20
  doAssert offsetof(CspProc, x87cw)     == 0x24
  doAssert offsetof(CspProc, rsp)       == 0x28
  doAssert offsetof(CspProc, rbp)       == 0x30
  doAssert offsetof(CspProc, registers) == 0x38
  doAssert offsetof(CspProc, yielded)   == 0x68
  doAssert sizeof(CspProc.isNew)   == 8  # read/written via mov (64-bit)
  doAssert sizeof(CspProc.yielded) == 8  # read/written via cmpq/movq
  doAssert sizeof(CspProc.mxcsr)   == 4  # stmxcsr writes 4 bytes

proc statGet*(p: ptr CspProc): uint64 =
  p.stat.load(moAcquire)

proc statSet*(p: ptr CspProc, v: uint64) =
  p.stat.store(v, moRelease)

proc statCas*(p: ptr CspProc, oval: var uint64, nval: uint64): bool =
  p.stat.compareExchange(oval, nval, moAcquireRelease, moAcquire)

proc nchildGet*(p: ptr CspProc): uint64 =
  p.nchild.load(moSequentiallyConsistent)

proc nchildIncr*(p: ptr CspProc): uint64 =
  p.nchild.fetchAdd(1)

proc nchildDecr*(p: ptr CspProc): uint64 =
  p.nchild.fetchSub(1)
