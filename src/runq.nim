## runq.nim
## Local (per-core) and global (shared) run queues.
## Equivalent to src/runq.h + src/runq.c

import csp_proc_types
import rbq
import common

# ─── Global run queue (multiple-writer multiple-reader) ───────────────────────

type
  GRunq* = MmRbq[ptr CspProc]

proc newGRunq*(capExp: uint): GRunq =
  newMmRbq[ptr CspProc](capExp)

# ─── Local run queue (Single-writer Multiple-reader lock-free) ───────────────

const
  LRunqOk*     = 0
  LRunqFailed* = -1
  LRunqMissed* = 1

type
  LRunq* = SmRbq[ptr CspProc]

proc newLRunq*(): LRunq =
  newSmRbq[ptr CspProc](8) # 256 items

proc push*(lrunq: LRunq, p: ptr CspProc) =
  while not tryPush(lrunq, p):
    cpuRelax()

proc pushFront*(lrunq: LRunq, p: ptr CspProc) =
  while not tryPush(lrunq, p):
    cpuRelax()

proc tryPopFront*(lrunq: LRunq, p: var ptr CspProc): int =
  if tryPop(lrunq, p):
    LRunqOk
  else:
    LRunqFailed

proc popmFront*(lrunq: LRunq, n: uint, start, `end`: var ptr CspProc) =
  if n == 0: return
  let procs = cast[ptr UncheckedArray[ptr CspProc]](alloc(n * uint(sizeof(ptr CspProc))))
  let count = tryPopM(lrunq, cast[ptr ptr CspProc](procs), n)
  if count == 0:
    start = nil; `end` = nil
    dealloc(procs)
    return
  for i in 0 ..< count - 1:
    procs[i.int].next = procs[(i+1).int]
  procs[(count-1).int].next = nil
  start = procs[0]
  `end` = procs[(count-1).int]
  dealloc(procs)

proc set*(lrunq: LRunq, n: uint, start, `end`: ptr CspProc) =
  var curr = start
  while curr != nil:
    let nxt = curr.next
    push(lrunq, curr)
    curr = nxt

proc destroyLRunq*(lrunq: LRunq) =
  if lrunq != nil:
    destroy(lrunq)
    dealloc(lrunq)
