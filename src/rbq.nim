## rbq.nim
## High-performance lock-free ring buffer queues.

import std/atomics
import common

# ─── Sequence types ──────────────────────────────────────────────────────────

type
  RbqSeq = object
    pad: array[56, byte]
    v:   Atomic[uint64]

proc init(s: var RbqSeq, val: uint64) =
  s.v.store(val)

proc get(s: var RbqSeq): uint64 =
  s.v.load(moAcquire)

proc set(s: var RbqSeq, val: uint64) =
  s.v.store(val, moRelease)

proc cas(s: var RbqSeq, oval: var uint64, nval: uint64): bool =
  s.v.compareExchange(oval, nval, moAcquireRelease, moAcquire)

# ─── Single pointer ───────────────────────────────────────────────────────────

type
  SPtr = object
    next:  uint64
    barr:  RbqSeq
    pad:   array[56, byte]

proc init(p: var SPtr, cap: uint64) =
  p.next = 0
  p.barr.init(0)

proc nextGet(p: var SPtr): uint64 = p.next
proc nextSet(p: var SPtr, v: uint64) = p.next = v
proc barrGet(p: var SPtr): uint64 = p.barr.get()
proc barrSet(p: var SPtr, v: uint64) = p.barr.set(v)
proc barrUpdate(p: var SPtr, mask: uint64): uint64 = p.barr.get()

proc nextRsv(p: var SPtr, curr: uint64, n: uint64): bool =
  p.next = curr + n
  true

proc markAvail(p: var SPtr, seqv: uint64, mask: uint64) =
  p.barr.set(p.next)

proc markMAvail(p: var SPtr, start, `end`, mask: uint64) =
  p.barr.set(p.next)

proc destroy(p: var SPtr) = discard

# ─── Multi pointer ──────────────────────────────────────────────────────────

type
  MPtr = object
    next:  RbqSeq
    barr:  RbqSeq
    pad:   array[56, byte]
    stats: ptr UncheckedArray[RbqSeq]

proc init(p: var MPtr, cap: uint64): bool =
  p.next.init(0)
  p.barr.init(0)
  let mem = cast[ptr UncheckedArray[RbqSeq]](alloc0((cap + 1).uint * uint(sizeof(RbqSeq))))
  if mem == nil: return false
  p.stats = mem
  for i in 0 ..< cap:
    p.stats[i].init(high(uint64))
  true

proc nextGet(p: var MPtr): uint64 = p.next.get()
proc nextSet(p: var MPtr, v: uint64) = p.next.set(v)
proc barrGet(p: var MPtr): uint64 = p.barr.get()
proc barrSet(p: var MPtr, v: uint64) = p.barr.set(v)

proc isAvail(p: var MPtr, seqv: uint64, mask: uint64): bool =
  p.stats[seqv and mask].get() == seqv

proc markAvail(p: var MPtr, seqv: uint64, mask: uint64) =
  p.stats[seqv and mask].set(seqv)

proc markMAvail(p: var MPtr, start, `end`, mask: uint64) =
  var i = start
  while i < `end`:
    p.markAvail(i, mask)
    inc i

proc nextRsv(p: var MPtr, curr: var uint64, n: uint64): bool =
  p.next.cas(curr, curr + n)

proc barrUpdate(p: var MPtr, mask: uint64): uint64 =
  while true:
    var curr = p.barrGet()
    var barr = curr
    while p.isAvail(barr, mask):
      inc barr
    if curr == barr: return curr
    var c = curr
    if p.barr.cas(c, barr):
      return barr
    # Someone else updated it, try again to get the absolute latest

proc destroy(p: var MPtr) =
  if p.stats != nil:
    dealloc(p.stats)
    p.stats = nil

# ─── Generic ring-buffer queue ────────────────────────────────────────────────

type
  RbqBase*[T; FP; SP] = object
    items: ptr UncheckedArray[T]
    cap:   uint64
    mask:  uint64
    fast:  FP
    slow:  SP

proc initRbq*[T, FP, SP](q: ptr RbqBase[T, FP, SP], capExp: uint): bool =
  q.cap  = 1u64 shl capExp
  q.mask = q.cap - 1
  q.items = cast[ptr UncheckedArray[T]](alloc0(q.cap.uint * uint(sizeof(T))))
  if q.items == nil: return false
  when SP is SPtr:
    q.slow.init(q.cap)
  else:
    if not q.slow.init(q.cap): return false
  when FP is SPtr:
    q.fast.init(q.cap)
  else:
    if not q.fast.init(q.cap): return false
  true

proc destroy*[T; FP; SP](q: ptr RbqBase[T, FP, SP]) =
  if q.items != nil: dealloc(q.items)
  q.slow.destroy()
  q.fast.destroy()

proc len*[T; FP; SP](q: ptr RbqBase[T, FP, SP]): uint =
  uint(q.fast.nextGet() - q.slow.nextGet())

proc tryPush*[T; FP; SP](q: ptr RbqBase[T, FP, SP], item: T): bool =
  var sbarr = q.slow.barrGet()
  var fnext = q.fast.nextGet()
  if cspUnlikely(sbarr + q.cap <= fnext):
    sbarr = q.slow.barrUpdate(q.mask)
    if cspUnlikely(sbarr + q.cap <= fnext):
      return false
  var fn = fnext
  when FP is MPtr:
    if not q.fast.nextRsv(fn, 1):
      return false
  else:
    discard q.fast.nextRsv(fn, 1)
  q.items[fn and q.mask] = item
  q.fast.markAvail(fn, q.mask)
  true

proc tryPop*[T; FP; SP](q: ptr RbqBase[T, FP, SP], item: var T): bool =
  var snext = q.slow.nextGet()
  var fbarr = q.fast.barrGet()
  if cspUnlikely(snext >= fbarr):
    fbarr = q.fast.barrUpdate(q.mask)
    if cspUnlikely(snext >= fbarr):
      return false
  var sn = snext
  when SP is MPtr:
    if not q.slow.nextRsv(sn, 1):
      return false
  else:
    discard q.slow.nextRsv(sn, 1)
  item = q.items[sn and q.mask]
  q.slow.markAvail(sn, q.mask)
  true

proc tryPushM*[T; FP; SP](q: ptr RbqBase[T, FP, SP], items: ptr T, n: uint): bool =
  if n == 0: return true
  if n == 1: return q.tryPush(items[])
  let nu = uint64(n)
  var sbarr = q.slow.barrGet()
  var fnext = q.fast.nextGet()
  if cspUnlikely(sbarr + q.cap < fnext + nu):
    sbarr = q.slow.barrUpdate(q.mask)
    if cspUnlikely(sbarr + q.cap < fnext + nu):
      return false
  var fn = fnext
  when FP is MPtr:
    if not q.fast.nextRsv(fn, nu):
      return false
  else:
    discard q.fast.nextRsv(fn, nu)
  let i = fn and q.mask
  if i + nu <= q.cap:
    copyMem(addr q.items[i], items, nu.uint * uint(sizeof(T)))
  else:
    let part = q.cap - i
    copyMem(addr q.items[i], items, part.uint * uint(sizeof(T)))
    copyMem(addr q.items[0], cast[ptr T](cast[uint](items) + part.uint * uint(sizeof(T))), (nu - part).uint * uint(sizeof(T)))
  q.fast.markMAvail(fn, fn + nu, q.mask)
  true

proc tryPopM*[T; FP; SP](q: ptr RbqBase[T, FP, SP], items: ptr T, n: uint): uint =
  if n == 0: return 0
  if n == 1:
    var item: T
    if q.tryPop(item):
      items[] = item
      return 1
    return 0
  var snext = q.slow.nextGet()
  var fbarr = q.fast.barrGet()
  if cspUnlikely(snext >= fbarr):
    fbarr = q.fast.barrUpdate(q.mask)
    if cspUnlikely(snext >= fbarr):
      return 0
  var len = fbarr - snext
  if uint64(n) < len: len = uint64(n)
  var sn = snext
  when SP is MPtr:
    if not q.slow.nextRsv(sn, len):
      return 0
  else:
    discard q.slow.nextRsv(sn, len)
  let i = sn and q.mask
  if i + len <= q.cap:
    copyMem(items, addr q.items[i], len.uint * uint(sizeof(T)))
  else:
    let part = q.cap - i
    copyMem(items, addr q.items[i], part.uint * uint(sizeof(T)))
    copyMem(cast[ptr T](cast[uint](items) + part.uint * uint(sizeof(T))), addr q.items[0], (len - part).uint * uint(sizeof(T)))
  q.slow.markMAvail(sn, sn + len, q.mask)
  uint(len)

# ─── Convenience type aliases (Corrected) ─────────────────────────────────────

type
  SsRbq*[T] = ptr RbqBase[T, SPtr, SPtr]   ## single-writer single-reader
  SmRbq*[T] = ptr RbqBase[T, SPtr, MPtr]   ## single-writer multi-reader (Single Fast, Multi Slow)
  MsRbq*[T] = ptr RbqBase[T, MPtr, SPtr]   ## multi-writer single-reader (Multi Fast, Single Slow)
  MmRbq*[T] = ptr RbqBase[T, MPtr, MPtr]   ## multi-writer multi-reader

proc newSsRbq*[T](capExp: uint): SsRbq[T] =
  result = cast[SsRbq[T]](alloc0(sizeof(RbqBase[T, SPtr, SPtr])))
  discard initRbq(result, capExp)

proc newSmRbq*[T](capExp: uint): SmRbq[T] =
  result = cast[SmRbq[T]](alloc0(sizeof(RbqBase[T, SPtr, MPtr])))
  discard initRbq(result, capExp)

proc newMsRbq*[T](capExp: uint): MsRbq[T] =
  result = cast[MsRbq[T]](alloc0(sizeof(RbqBase[T, MPtr, SPtr])))
  discard initRbq(result, capExp)

proc newMmRbq*[T](capExp: uint): MmRbq[T] =
  result = cast[MmRbq[T]](alloc0(sizeof(RbqBase[T, MPtr, MPtr])))
  discard initRbq(result, capExp)

# ─── Raw (non-thread-safe) ring buffer ───────────────────────────────────────

type
  RawRbq*[T] = object
    items: seq[T]
    cap:   uint
    mask:  uint
    slow:  uint64
    fast:  uint64

proc newRawRbq*[T](capExp: uint): ref RawRbq[T] =
  var q = new RawRbq[T]
  q.cap  = 1u shl capExp
  q.mask = q.cap - 1
  q.items = newSeq[T](q.cap)
  q

proc len*[T](q: ref RawRbq[T]): uint =
  uint(q.fast - q.slow)

proc tryPush*[T](q: ref RawRbq[T], item: T): bool =
  if q.len() < q.cap:
    q.items[q.fast and q.mask] = item
    inc q.fast
    return true
  false

proc tryPushFront*[T](q: ref RawRbq[T], item: T): bool =
  if q.len() < q.cap:
    dec q.slow
    q.items[q.slow and q.mask] = item
    return true
  false

proc tryPop*[T](q: ref RawRbq[T], item: var T): bool =
  if q.len() > 0:
    item = q.items[q.slow and q.mask]
    inc q.slow
    return true
  false

proc tryGrow*[T](q: ref RawRbq[T]): bool =
  let newCap = q.cap * 2
  q.items.setLen(newCap)
  q.cap  = newCap
  q.mask = newCap - 1
  true
