## timer.nim
## Timer subsystem – min-heap of timed processes.

import std/[times, atomics, os]
import csp_proc_types
import mutex
import common

# ─── Time constants ───────────────────────────────────────────────────────────

const
  CspTimerNanosecond*  = int64(1)
  CspTimerMicrosecond* = CspTimerNanosecond * 1_000
  CspTimerMillisecond* = CspTimerMicrosecond * 1_000
  CspTimerSecond*      = CspTimerMillisecond * 1_000
  CspTimerMinute*      = CspTimerSecond * 60
  CspTimerHour*        = CspTimerMinute * 60

type
  CspTimerTime*     = int64
  CspTimerDuration* = int64

  CspTimer* = object
    ctx*:   ptr CspProc
    token*: int64

# ─── Clock ────────────────────────────────────────────────────────────────────

proc cspTimerNow*(): CspTimerTime =
  let ts = getTime()
  ts.toUnix() * 1_000_000_000 + ts.nanosecond

# ─── Timer Heap ───────────────────────────────────────────────────────────────

const DefaultHeapCap = 64

type
  CspTimerHeap = object
    cap:   uint
    len:   uint
    procs: ptr UncheckedArray[ptr CspProc]
    time:  CspTimerTime
    token: int64
    mutex: CspMutex

proc initHeap(h: var CspTimerHeap, pid: uint): bool =
  h.cap   = DefaultHeapCap
  h.len   = 0
  h.time  = cspTimerNow()
  h.token = int64(pid shl 53)
  h.procs = cast[ptr UncheckedArray[ptr CspProc]](alloc0(DefaultHeapCap.uint * uint(sizeof(ptr CspProc))))
  h.mutex.init()
  h.procs != nil

proc lte(h: var CspTimerHeap, i, j: uint): bool =
  h.procs[i].timer.when_ns <= h.procs[j].timer.when_ns

proc shiftUp(h: var CspTimerHeap, idx: uint) =
  var i = idx
  while i > 0:
    let father = (i - 1) shr 1
    if h.lte(father, i): return
    swap(h.procs[i], h.procs[father])
    swap(h.procs[i].timer.idx, h.procs[father].timer.idx)
    i = father

proc put(h: var CspTimerHeap, p: ptr CspProc) =
  h.mutex.lock()
  if cspUnlikely(h.len == h.cap):
    let newCap = h.cap * 2
    h.procs = cast[ptr UncheckedArray[ptr CspProc]](
      realloc(h.procs, newCap.uint * uint(sizeof(ptr CspProc))))
    if h.procs == nil: quit(1)
    h.cap = newCap
  p.timer.token.store(h.token, moSequentiallyConsistent)
  h.token += 1
  h.procs[h.len] = p
  p.timer.idx = int64(h.len)
  h.len += 1
  h.shiftUp(h.len - 1)
  h.mutex.unlock()

proc del(h: var CspTimerHeap, p: ptr CspProc) =
  var idx = uint(p.timer.idx)
  h.len -= 1
  if idx == h.len:
    return
  h.procs[idx] = h.procs[h.len]
  h.procs[idx].timer.idx = int64(idx)
  if idx > 0 and h.lte(idx, (idx - 1) shr 1):
    h.shiftUp(idx)
    return
  while true:
    var son = (idx shl 1) + 1
    if son >= h.len: break
    if son + 1 < h.len and h.lte(son + 1, son): inc son
    if h.lte(idx, son): break
    swap(h.procs[idx], h.procs[son])
    swap(h.procs[idx].timer.idx, h.procs[son].timer.idx)
    idx = son

proc poll(h: var CspTimerHeap, start, `end`: var ptr CspProc): int =
  h.mutex.lock()
  if h.len == 0:
    h.mutex.unlock()
    return 0
  let now = cspTimerNow()
  var n = 0
  var head: ptr CspProc = nil
  var tail: ptr CspProc = nil
  while h.len > 0 and h.procs[0].timer.when_ns <= now:
    let top = h.procs[0]
    h.del(top)
    top.timer.token.store(-1, moSequentiallyConsistent)

    # Transition to Runnable
    var oval = top.statGet()
    if not top.statCas(oval, CspProcStatRunnable):
      continue

    top.pre  = nil
    top.next = nil
    if tail == nil:
      head = top; tail = top
    else:
      tail.next = top
      tail = top
    inc n
  if n > 0:
    start = head
    `end`  = tail
  h.mutex.unlock()
  n

# ─── Global timer heap pool ───────────────────────────────────────────────────

var
  gTimerHeapLen: int = 0
  gTimerHeaps:   ptr UncheckedArray[CspTimerHeap] = nil

proc cspTimerHeapsInit*(np: int): bool =
  gTimerHeaps = cast[ptr UncheckedArray[CspTimerHeap]](
    alloc0(np.uint * uint(sizeof(CspTimerHeap))))
  if gTimerHeaps == nil: return false
  for i in 0 ..< np:
    if not gTimerHeaps[i].initHeap(uint(i)):
      gTimerHeapLen = i
      return false
  gTimerHeapLen = np
  true

proc cspTimerHeapsDestroy*() =
  for i in 0 ..< gTimerHeapLen:
    dealloc(gTimerHeaps[i].procs)
  dealloc(gTimerHeaps)

proc cspTimerPut*(pid: uint, p: ptr CspProc) =
  gTimerHeaps[pid mod uint(gTimerHeapLen)].put(p)

## Total number of timers currently armed across every heap -- used by the
## scheduler's deadlock detector to distinguish "nothing to do right now"
## from "nothing will EVER be ready again" (a pending, not-yet-expired timer
## means the latter is false: something will happen on its own).
proc cspTimerPendingCount*(): int =
  if gTimerHeaps == nil: return 0
  result = 0
  for i in 0 ..< gTimerHeapLen:
    gTimerHeaps[i].mutex.lock()
    result += int(gTimerHeaps[i].len)
    gTimerHeaps[i].mutex.unlock()

proc cspTimerPoll*(start, `end`: var ptr CspProc): int =
  var total = 0
  var s, e: ptr CspProc
  for i in 0 ..< gTimerHeapLen:
    let n = gTimerHeaps[i].poll(s, e)
    if n > 0:
      if total != 0:
        `end`.next = s
        `end`      = e
      else:
        start = s
        `end`  = e
      total += n
  total

proc cspTimerCancel*(timer: CspTimer): bool =
  let heap = addr gTimerHeaps[timer.ctx.bornedPid mod uint(gTimerHeapLen)]
  heap[].mutex.lock()
  var tok = timer.token
  if not timer.ctx.timer.token.compareExchange(tok, -1, moSequentiallyConsistent, moSequentiallyConsistent):
    heap[].mutex.unlock()
    return false
  heap[].del(timer.ctx)
  heap[].mutex.unlock()
  true
