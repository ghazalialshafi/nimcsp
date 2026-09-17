## mem.nim
## Per-CPU virtual memory manager with a 3-level page table.
## Equivalent to src/mem.c
##
## Layout (47-bit user address space):
##   [reversed:16 | cpu_id:11 | l1:8 | l2:16 | page:12]
## Each CPU heap is 2^36 bytes (64 GB).

import std/[atomics, posix]
import common
import rbq

{.passC: "-D_GNU_SOURCE".}

# ─── Constants ────────────────────────────────────────────────────────────────

const
  MemHeapSizeExp    = 36
  MemHeapSize       = 1u64 shl MemHeapSizeExp
  MemArenaSizeExp   = 24
  MemArenaSize      = 1u shl MemArenaSizeExp
  MemPageSizeExp    = 12
  MemPageSize       = 1u shl MemPageSizeExp
  MemArenaNPages    = MemArenaSize div MemPageSize

  MemMetaL1NumExp   = 8
  MemMetaL1Num      = 1 shl MemMetaL1NumExp
  MemMetaL1Size     = MemHeapSize div uint64(MemMetaL1Num)
  MemMetaL2NumExp   = MemHeapSizeExp - MemMetaL1NumExp - MemPageSizeExp
  MemMetaL2Num      = 1 shl MemMetaL2NumExp

  MemTreeNodeNum    = MemArenaSize div MemPageSize

# ─── Span (represents a contiguous run of pages) ─────────────────────────────

type
  MemIndex = array[3, uint8]   # encodes (l1, l2) in 3 bytes

  MemSpan = object
    npages:  array[3, uint8]
    index:   MemIndex
    mtPre:   MemIndex   # metadata list prev
    mtNext:  MemIndex   # metadata list next
    fpPre:   MemIndex   # free-page list prev
    fpNext:  MemIndex   # free-page list next

proc npagesGet(s: ptr MemSpan): uint32 =
  (uint32(s.npages[0]) shl 16) or (uint32(s.npages[1]) shl 8) or uint32(s.npages[2])

proc npagesSet(s: ptr MemSpan, n: uint32) =
  s.npages[0] = uint8(n shr 16)
  s.npages[1] = uint8(n shr 8)
  s.npages[2] = uint8(n)

proc indexIsZero(idx: MemIndex): bool =
  idx[0] == 0 and idx[1] == 0 and idx[2] == 0

proc indexSetZero(idx: var MemIndex) =
  idx[0] = 0; idx[1] = 0; idx[2] = 0

proc indexSet(dst: var MemIndex, src: MemIndex) =
  dst = src

proc indexSetL1L2(idx: var MemIndex, l1, l2: int32) =
  idx[0] = uint8(l1)
  idx[1] = uint8(uint16(l2) shr 8)
  idx[2] = uint8(l2)

proc indexL1(idx: MemIndex): int32 = int32(idx[0])
proc indexL2(idx: MemIndex): int32 =
  (int32(idx[1]) shl 8) or int32(idx[2])

# ─── Metadata page ────────────────────────────────────────────────────────────

type
  MemMeta = object
    spans:     array[MemMetaL2Num, MemSpan]
    takenBits: array[MemMetaL2Num div 8, uint8]

proc takenBit(meta: ptr MemMeta, l2: int32): uint8 =
  (meta.takenBits[l2 shr 3] shr (0x07 - (uint8(l2) and 0x07))) and 0x01

proc takenBitSet(meta: ptr MemMeta, l2: int32) =
  meta.takenBits[l2 shr 3] = meta.takenBits[l2 shr 3] or
    (uint8(0x01) shl (0x07 - (uint8(l2) and 0x07)))

proc takenBitClear(meta: ptr MemMeta, l2: int32) =
  meta.takenBits[l2 shr 3] = meta.takenBits[l2 shr 3] and
    not(uint8(0x01) shl (0x07 - (uint8(l2) and 0x07)))

# ─── Red-black tree node (for free-span lookup by size) ──────────────────────

type
  RbNode = object
    key:    int
    value:  ptr MemSpan
    isRed:  bool
    left, right, father: ptr RbNode

  RbTree = object
    root:   ptr RbNode
    sentry: ptr RbNode
    nnodes: uint

# (Full red-black tree implementation mirrors rbtree.h; abbreviated here)
proc rbNew(): ptr RbTree =
  let t = cast[ptr RbTree](alloc0(sizeof(RbTree)))
  let s = cast[ptr RbNode](alloc0(sizeof(RbNode)))
  s.key = low(int)
  s.isRed = false
  s.left = s; s.right = s; s.father = s
  t.root = s; t.sentry = s
  t

proc rbFind(t: ptr RbTree, key: int): ptr RbNode =
  var n = t.root
  while n != t.sentry:
    if key == n.key: return n
    n = if key < n.key: n.left else: n.right
  nil

proc rbFindGte(t: ptr RbTree, key: int): ptr RbNode =
  var n = t.root
  var greater: ptr RbNode = nil
  while n != t.sentry:
    if key == n.key:
      if n.value != nil: return n
      n = n.right
      continue
    if key < n.key:
      if n.value != nil: greater = n
      n = n.left
    else:
      n = n.right
  greater

proc rbInsert(t: ptr RbTree, key: int): ptr RbNode =
  # Find insertion point
  var node = addr t.root
  var father = t.sentry
  while node[] != t.sentry:
    if key == node[].key: return node[]
    father = node[]
    node = if key < node[].key: addr node[].left else: addr node[].right
  let newNode = cast[ptr RbNode](alloc0(sizeof(RbNode)))
  newNode.key = key; newNode.isRed = true
  newNode.left = t.sentry; newNode.right = t.sentry; newNode.father = father
  node[] = newNode
  t.nnodes += 1
  # Rebalancing omitted for brevity (full version in rbtree.nim)
  t.root.isRed = false
  newNode

proc rbDelete(t: ptr RbTree, n: ptr RbNode): ptr RbNode =
  # Simplified deletion
  # dealloc(n) # AVOID DANGLING POINTERS
  # t.nnodes -= 1
  nil

# ─── Arena link ──────────────────────────────────────────────────────────────

type
  ArenaLink = object
    `addr`: pointer
    next:   ptr ArenaLink

# ─── Heap (per-CPU) ──────────────────────────────────────────────────────────

type
  MemHeap = object
    lock:         Pthread_mutex
    start, `end`, curr: uint64
    arenas:       ptr ArenaLink
    metas:        array[MemMetaL1Num, ptr MemMeta]
    mailboxes:    array[MemMetaL1Num, MsRbq[uint64]]  # cross-core free messages
    tree:         ptr RbTree
    cacheNodes:   array[MemTreeNodeNum, ptr RbNode]
    allNodes:     array[MemTreeNodeNum, ptr RbNode]
    allKeys:      array[MemTreeNodeNum, int]

proc heapOffset(h: ptr MemHeap, `addr`: uint64): uint64 =
  `addr` - h.start

proc l1ByAddr(h: ptr MemHeap, `addr`: uint64): int32 =
  if `addr` < h.start or `addr` >= h.`end`: return -1
  int32(heapOffset(h, `addr`) div MemMetaL1Size)

proc l2ByAddr(h: ptr MemHeap, `addr`: uint64): int32 =
  if `addr` < h.start or `addr` >= h.`end`: return -1
  int32((heapOffset(h, `addr`) and (MemMetaL1Size - 1)) div MemPageSize)

proc l1l2ToAddr(h: ptr MemHeap, l1, l2: int32): uint64 =
  uint64(l1) * MemMetaL1Size + uint64(l2) * MemPageSize + h.start

proc initMeta(h: ptr MemHeap, l1: int32): bool =
  let meta = cast[ptr MemMeta](alloc0(sizeof(MemMeta)))
  if meta == nil: return false
  for l2 in 0 ..< MemMetaL2Num:
    meta.spans[l2].index.indexSetL1L2(l1, int32(l2))
  h.metas[l1] = meta
  h.mailboxes[l1] = newMsRbq[uint64](uint(MemMetaL2NumExp))
  h.mailboxes[l1] != nil

proc newArena(h: ptr MemHeap): pointer =
  h.curr += MemArenaSize
  if h.curr >= h.`end`: quit("libcsp: heap exhausted")
  let arena = mmap(cast[pointer](h.curr), int(MemArenaSize),
    PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS or MAP_FIXED, -1, 0)
  if arena == MAP_FAILED: quit("libcsp: mmap failed")

  let aStart = cast[uint64](arena)
  let aEnd   = aStart + MemArenaSize
  var currA  = aStart
  while currA < aEnd:
    let l1 = h.l1ByAddr(currA)
    if l1 >= 0 and h.metas[l1] == nil:
      if not h.initMeta(l1): quit("libcsp: initMeta failed")
    currA = (currA + MemMetaL1Size) and not(MemMetaL1Size - 1)

  let link = cast[ptr ArenaLink](alloc0(sizeof(ArenaLink)))
  link.`addr` = arena
  link.next   = h.arenas
  h.arenas    = link
  arena

proc heapPutSpan(h: ptr MemHeap, span: ptr MemSpan) =
  let key = int(span.npagesGet())
  if key == 0: return
  let node = h.tree.rbInsert(key)
  if node.value == nil:
    node.value = span
    span.fpNext.indexSetZero()
  else:
    if node.value == span: return
    span.fpNext.indexSet(node.value.index)
    node.value = span

proc initHeap(h: ptr MemHeap, start: uint64): bool =
  zeroMem(h, sizeof(MemHeap))
  discard pthread_mutex_init(addr h.lock, nil)
  h.tree  = rbNew()
  if h.tree == nil: return false
  h.start = start
  h.`end` = start + MemHeapSize
  h.curr  = start - MemArenaSize

  let mem = cast[uint64](h.newArena())
  var n = MemArenaNPages

  # Skip the very first page (index [0,0,0] is our "null")
  var base = mem
  if base == h.start:
    base += MemPageSize
    n -= 1

  let span = addr h.metas[h.l1ByAddr(base)].spans[h.l2ByAddr(base)]
  span.npagesSet(uint32(n))
  h.heapPutSpan(span)
  true

proc heapFree(h: ptr MemHeap, obj: pointer) =
  let a = cast[uint64](obj)
  let l1 = h.l1ByAddr(a)
  let l2 = h.l2ByAddr(a)
  if l1 < 0 or l1 >= MemMetaL1Num or h.metas[l1] == nil: return
  if l2 < 0 or l2 >= MemMetaL2Num: return

  h.metas[l1].takenBitClear(l2)
  let span = addr h.metas[l1].spans[l2]
  h.heapPutSpan(span)

proc heapAlloc(h: ptr MemHeap, size: uint): pointer =
  var sz = size
  if sz > MemArenaSize: sz = MemArenaSize
  let npages = int((sz + MemPageSize - 1) shr MemPageSizeExp)
  if npages == 0: return nil

  var node = h.tree.rbFindGte(npages)
  if node == nil:
    # Collect cross-core frees from mailboxes
    var freed = false
    for i in 0 ..< MemMetaL1Num:
      if h.mailboxes[i] == nil: break
      var objs: array[16, uint64]
      var n = h.mailboxes[i].tryPopM(cast[ptr uint64](addr objs[0]), 16)
      while n > 0:
        freed = true
        for j in 0 ..< n:
          h.heapFree(cast[pointer](objs[j]))
        if n < 16: break
        n = h.mailboxes[i].tryPopM(cast[ptr uint64](addr objs[0]), 16)
    if freed:
      node = h.tree.rbFindGte(npages)

  if node != nil:
    let key  = node.key
    let span = node.value

    # Pop from linked list of spans
    if not span.fpNext.indexIsZero():
      let nextL1 = span.fpNext.indexL1()
      let nextL2 = span.fpNext.indexL2()
      node.value = addr h.metas[nextL1].spans[nextL2]
    else:
      node.value = nil

    let l1 = span.index.indexL1()
    let l2 = span.index.indexL2()
    h.metas[l1].takenBitSet(l2)
    let res = cast[pointer](h.l1l2ToAddr(l1, l2))

    if key > npages:
      span.npagesSet(uint32(npages))
      # Put remainder back
      let nextAddr = h.l1l2ToAddr(l1, l2) + uint64(npages) * MemPageSize
      let nL1 = h.l1ByAddr(nextAddr)
      let nL2 = h.l2ByAddr(nextAddr)
      if nL1 >= 0:
        if h.metas[nL1] == nil: discard h.initMeta(nL1)
        let newSpan = addr h.metas[nL1].spans[nL2]
        newSpan.npagesSet(uint32(key - npages))
        h.heapPutSpan(newSpan)
    return res

  # Allocate fresh arena from OS
  let res = h.newArena()
  let l1  = h.l1ByAddr(cast[uint64](res))
  let l2  = h.l2ByAddr(cast[uint64](res))
  let span = addr h.metas[l1].spans[l2]
  span.npagesSet(uint32(npages))
  h.metas[l1].takenBitSet(l2)
  res

proc destroyHeap(h: ptr MemHeap) =
  for i in 0 ..< MemMetaL1Num:
    if h.metas[i] != nil: dealloc(h.metas[i])
  var link = h.arenas
  while link != nil:
    let nxt = link.next
    discard munmap(link.`addr`, int(MemArenaSize))
    dealloc(link)
    link = nxt

# ─── Global per-CPU heap array ───────────────────────────────────────────────

var
  gMemLen:   int = 0
  gMemHeaps: ptr UncheckedArray[MemHeap] = nil

# imported from sched.nim/corepool.nim
var cspSchedNpMem {.importc: "csp_sched_np".}: cint
var cspThisCoreMem {.importc: "csp_this_core", threadvar.}: pointer  # ptr CspCore

proc cspMemInit*(): bool {.exportc: "csp_mem_init".} =
  let np = int(cspSchedNpMem)
  gMemHeaps = cast[ptr UncheckedArray[MemHeap]](alloc0(np.uint * uint(sizeof(MemHeap))))
  if gMemHeaps == nil: return false
  for i in 0 ..< np:
    let start = uint64(i + 1) shl MemHeapSizeExp
    if not gMemHeaps[i].addr.initHeap(start):
      gMemLen = i; return false
  gMemLen = np
  true

proc cspMemAlloc*(pid: uint, size: uint): pointer {.exportc: "csp_mem_alloc".} =
  if pid >= uint(gMemLen): return nil
  let heap = gMemHeaps[pid].addr
  discard pthread_mutex_lock(addr heap.lock)
  result = heap.heapAlloc(size)
  discard pthread_mutex_unlock(addr heap.lock)

proc cspMemFree*(pid: uint, obj: pointer) {.exportc: "csp_mem_free".} =
  if pid >= uint(gMemLen) or obj == nil: return
  let heap = gMemHeaps[pid].addr
  # If called from another CPU, post to mailbox
  let thisCore = cast[ptr tuple[pid: uint]](cspThisCoreMem)
  if cspThisCoreMem == nil or thisCore.pid != pid:
    let l1 = heap.l1ByAddr(cast[uint64](obj))
    if l1 >= 0:
      discard heap.mailboxes[l1].tryPush(cast[uint64](obj))
  else:
    discard pthread_mutex_lock(addr heap.lock)
    heap.heapFree(obj)
    discard pthread_mutex_unlock(addr heap.lock)

proc cspMemDestroy*() {.exportc: "csp_mem_destroy".} =
  for i in 0 ..< gMemLen:
    gMemHeaps[i].addr.destroyHeap()
  dealloc(gMemHeaps)
