## cond.nim
## Process-level conditional variable (for scheduler sleep/wakeup).
## Equivalent to src/cond.h

import std/atomics
import timer

const
  CspCondSignalNone*      = 0
  CspCondSignalProcAvail* = 1
  CspCondSignalDeepSleep* = 2

type
  CspCond* = object
    stat*:    Atomic[int]
    waiting*: Atomic[bool]
    start*:   CspTimerTime

proc init*(c: var CspCond) =
  c.stat.store(CspCondSignalNone)
  c.waiting.store(false)
  c.start = 0

proc beforeWait*(c: var CspCond) =
  c.start = cspTimerNow()

proc wait*(c: var CspCond): int =
  var signal = c.stat.load(moSequentiallyConsistent)
  while signal == CspCondSignalNone:
    c.waiting.store(true, moSequentiallyConsistent)
    signal = c.stat.load(moSequentiallyConsistent)
  c.init()
  signal

proc signal*(c: var CspCond, sig: int) =
  while not c.waiting.load(moSequentiallyConsistent):
    cpuRelax()
  c.stat.store(sig, moSequentiallyConsistent)
