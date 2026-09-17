## chan.nim
## Go-style channels: buffered & unbuffered, with select, close, try variants.
## Equivalent to src/chan.h + src/chan.c

import std/[atomics, posix, algorithm, times]
import csp_proc_types
import csp_proc_extra
import core
import context_switch

# Forward declarations (implemented in sched.nim / scheduler.nim)
proc cspSchedYield() {.importc: "csp_sched_yield".}
proc cspSchedulerSubmit(p: ptr CspProc) {.importc: "csp_scheduler_submit".}

# ─── Channel type ─────────────────────────────────────────────────────────────

type
  CspSelectOp* {.pure.} = enum
    Recv, Send, Default

  CspSelectNode* = object
    ch*:        ptr CspGoChan
    p*:         ptr CspProc
    index*:     int
    val*:       ptr pointer
    op*:        CspSelectOp
    next*:      ptr CspSelectNode
    satisfied*: ptr Atomic[bool]

  CspGoChan* = object
    capacity*: uint
    size*:     uint
    head*:     uint      # write index (circular)
    tail*:     uint      # read  index (circular)
    buffer*:   ptr UncheckedArray[pointer]
    closed*:   bool
    lock*:     Pthread_mutex
    sendQ*:    ptr CspProc
    recvQ*:    ptr CspProc
    selectQ*:  ptr CspSelectNode

proc newGoChan*(capacity: uint): ptr CspGoChan =
  result = cast[ptr CspGoChan](allocShared0(sizeof(CspGoChan)))
  result.capacity = capacity
  if capacity > 0:
    result.buffer = cast[ptr UncheckedArray[pointer]](allocShared0(capacity.uint * uint(sizeof(pointer))))
  discard pthread_mutex_init(addr result.lock, nil)

proc closeGoChan*(ch: ptr CspGoChan) =
  let core = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr ch.lock)
  if ch.closed:
    discard pthread_mutex_unlock(addr ch.lock)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return

  ch.closed = true

  # Wake all blocked receivers
  while ch.recvQ != nil:
    let p = ch.recvQ
    ch.recvQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    if ex != nil:
      ex.chanOk  = false
      ex.chanVal = nil
    cspSchedulerSubmit(p)

  # Wake all blocked select waiters
  while ch.selectQ != nil:
    let curr = ch.selectQ
    ch.selectQ = curr.next
    if not curr.satisfied[].exchange(true, moAcquireRelease):
      let p = curr.p
      let ex = cast[ptr CspProcExtra](p.extra)
      if ex != nil:
        ex.chanOk = false
        ex.chanVal = nil
        ex.selectIdx = curr.index
      cspSchedulerSubmit(p)

  # Wake all blocked senders. A send that was blocked waiting for buffer
  # space (or a receiver) when the channel closed must fail, not silently
  # report success while the value is dropped -- mirror the receiver/
  # select-waiter wake loops above, which correctly set chanOk = false.
  while ch.sendQ != nil:
    let p = ch.sendQ
    ch.sendQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    if ex != nil:
      ex.chanOk = false
    cspSchedulerSubmit(p)

  discard pthread_mutex_unlock(addr ch.lock)
  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)

proc sendGoChan*(ch: ptr CspGoChan, val: pointer): bool =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr ch.lock)
  if ch.closed:
    discard pthread_mutex_unlock(addr ch.lock)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return false

  # Waiting receiver?
  if ch.recvQ != nil:
    let p = ch.recvQ
    ch.recvQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    if ex != nil:
      ex.chanOk  = true
      ex.chanVal = val
    discard pthread_mutex_unlock(addr ch.lock)
    cspSchedulerSubmit(p)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true

  # Waiting select receiver?
  var prevS: ptr CspSelectNode = nil
  var currS = ch.selectQ
  while currS != nil:
    if currS.op == CspSelectOp.Recv:
      if not currS.satisfied[].exchange(true, moAcquireRelease):
        let p = currS.p
        let ex = cast[ptr CspProcExtra](p.extra)
        if ex != nil:
          ex.chanOk  = true
          ex.chanVal = val
          ex.selectIdx = currS.index
        if prevS != nil: prevS.next = currS.next
        else: ch.selectQ = currS.next
        discard pthread_mutex_unlock(addr ch.lock)
        cspSchedulerSubmit(p)
        if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
        return true
    prevS = currS
    currS = currS.next

  # Buffered space?
  if ch.capacity > 0 and ch.size < ch.capacity:
    ch.buffer[ch.head] = val
    ch.head = (ch.head + 1) mod ch.capacity
    ch.size += 1
    discard pthread_mutex_unlock(addr ch.lock)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true

  # Block
  let self = core.running
  self.statSet(CspProcStatBlocked)
  self.next = ch.sendQ
  ch.sendQ  = self
  let selfEx = cast[ptr CspProcExtra](self.extra)
  if selfEx != nil:
    selfEx.chanVal = val
    selfEx.chanOk  = true # overwritten to false if woken due to close
  discard pthread_mutex_unlock(addr ch.lock)
  cspCoreYield(self, addr core.anchor)
  let sendOk = if selfEx != nil: selfEx.chanOk else: true
  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  sendOk

proc recvGoChan*(ch: ptr CspGoChan, ok: ptr bool): pointer =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)

  discard pthread_mutex_lock(addr ch.lock)

  # Buffered data available?
  if ch.size > 0:
    let val = ch.buffer[ch.tail]
    ch.tail = (ch.tail + 1) mod ch.capacity
    ch.size -= 1
    # Wake a blocked sender if any
    if ch.sendQ != nil:
      let p = ch.sendQ
      ch.sendQ = p.next
      let ex = cast[ptr CspProcExtra](p.extra)
      let sval = if ex != nil: ex.chanVal else: nil
      if ex != nil: ex.chanOk = true
      ch.buffer[ch.head] = sval
      ch.head = (ch.head + 1) mod ch.capacity
      ch.size += 1
      cspSchedulerSubmit(p)
    discard pthread_mutex_unlock(addr ch.lock)
    if ok != nil: ok[] = true
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return val

  if ch.closed:
    discard pthread_mutex_unlock(addr ch.lock)
    if ok != nil: ok[] = false
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return nil

  # Unbuffered: waiting sender?
  if ch.sendQ != nil and ch.capacity == 0:
    let p = ch.sendQ
    ch.sendQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    let val = if ex != nil: ex.chanVal else: nil
    discard pthread_mutex_unlock(addr ch.lock)
    cspSchedulerSubmit(p)
    if ok != nil: ok[] = true
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return val

  # Waiting select sender?
  var prevS: ptr CspSelectNode = nil
  var currS = ch.selectQ
  while currS != nil:
    if currS.op == CspSelectOp.Send:
      if not currS.satisfied[].exchange(true, moAcquireRelease):
        let p = currS.p
        let ex = cast[ptr CspProcExtra](p.extra)
        let val = if currS.val != nil: currS.val[] else: nil
        if ex != nil:
          ex.chanOk  = true
          ex.chanVal = val
          ex.selectIdx = currS.index
        if prevS != nil: prevS.next = currS.next
        else: ch.selectQ = currS.next
        discard pthread_mutex_unlock(addr ch.lock)
        cspSchedulerSubmit(p)
        if ok != nil: ok[] = true
        if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
        return val
    prevS = currS
    currS = currS.next

  # Block
  let self = core.running
  self.statSet(CspProcStatBlocked)
  self.next = ch.recvQ
  ch.recvQ  = self
  discard pthread_mutex_unlock(addr ch.lock)
  cspCoreYield(self, addr core.anchor)

  let selfEx = cast[ptr CspProcExtra](self.extra)
  let val  = if selfEx != nil: selfEx.chanVal else: nil
  if ok != nil: ok[] = if selfEx != nil: selfEx.chanOk else: false
  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  val

proc trySendGoChan*(ch: ptr CspGoChan, val: pointer): bool =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)
  discard pthread_mutex_lock(addr ch.lock)
  if ch.closed:
    discard pthread_mutex_unlock(addr ch.lock)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return false
  if ch.recvQ != nil:
    let p = ch.recvQ
    ch.recvQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    if ex != nil: ex.chanOk = true; ex.chanVal = val
    discard pthread_mutex_unlock(addr ch.lock)
    cspSchedulerSubmit(p)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true

  # Try wake select receiver
  var prevS: ptr CspSelectNode = nil
  var currS = ch.selectQ
  while currS != nil:
    if currS.op == CspSelectOp.Recv:
      if not currS.satisfied[].exchange(true, moAcquireRelease):
        let p = currS.p
        let ex = cast[ptr CspProcExtra](p.extra)
        if ex != nil:
          ex.chanOk = true
          ex.chanVal = val
          ex.selectIdx = currS.index
        if prevS != nil: prevS.next = currS.next
        else: ch.selectQ = currS.next
        discard pthread_mutex_unlock(addr ch.lock)
        cspSchedulerSubmit(p)
        if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
        return true
    prevS = currS
    currS = currS.next

  if ch.capacity > 0 and ch.size < ch.capacity:
    ch.buffer[ch.head] = val
    ch.head = (ch.head + 1) mod ch.capacity
    ch.size += 1
    discard pthread_mutex_unlock(addr ch.lock)
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true
  discard pthread_mutex_unlock(addr ch.lock)
  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  false

proc tryRecvGoChan*(ch: ptr CspGoChan, val: ptr pointer, ok: ptr bool): bool =
  let core  = cspThisCore
  let extra = if core != nil and core.running != nil: cast[ptr CspProcExtra](core.running.extra) else: nil
  if extra != nil: discard extra.inCriticalSection.fetchAdd(1, moRelaxed)
  discard pthread_mutex_lock(addr ch.lock)
  if ch.size > 0:
    let v = ch.buffer[ch.tail]
    ch.tail = (ch.tail + 1) mod ch.capacity
    ch.size -= 1
    if ch.sendQ != nil:
      let p = ch.sendQ
      ch.sendQ = p.next
      let ex = cast[ptr CspProcExtra](p.extra)
      let sval = if ex != nil: ex.chanVal else: nil
      if ex != nil: ex.chanOk = true
      ch.buffer[ch.head] = sval
      ch.head = (ch.head + 1) mod ch.capacity
      ch.size += 1
      cspSchedulerSubmit(p)
    discard pthread_mutex_unlock(addr ch.lock)
    if val != nil: val[] = v
    if ok  != nil: ok[]  = true
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true
  if ch.closed:
    discard pthread_mutex_unlock(addr ch.lock)
    if val != nil: val[] = nil
    if ok  != nil: ok[]  = false
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true
  if ch.sendQ != nil and ch.capacity == 0:
    let p = ch.sendQ
    ch.sendQ = p.next
    let ex = cast[ptr CspProcExtra](p.extra)
    let v = if ex != nil: ex.chanVal else: nil
    discard pthread_mutex_unlock(addr ch.lock)
    cspSchedulerSubmit(p)
    if val != nil: val[] = v
    if ok  != nil: ok[]  = true
    if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
    return true

  # Try wake select sender
  var prevS: ptr CspSelectNode = nil
  var currS = ch.selectQ
  while currS != nil:
    if currS.op == CspSelectOp.Send:
      if not currS.satisfied[].exchange(true, moAcquireRelease):
        let p = currS.p
        let ex = cast[ptr CspProcExtra](p.extra)
        let v = if currS.val != nil: currS.val[] else: nil
        if ex != nil:
          ex.chanOk = true
          ex.chanVal = v
          ex.selectIdx = currS.index
        if prevS != nil: prevS.next = currS.next
        else: ch.selectQ = currS.next
        discard pthread_mutex_unlock(addr ch.lock)
        cspSchedulerSubmit(p)
        if val != nil: val[] = v
        if ok  != nil: ok[]  = true
        if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
        return true
    prevS = currS
    currS = currS.next

  discard pthread_mutex_unlock(addr ch.lock)
  if extra != nil: discard extra.inCriticalSection.fetchSub(1, moRelaxed)
  false

# ─── Select ───────────────────────────────────────────────────────────────────

type
  CspSelectCase* = object
    ch*:  ptr CspGoChan
    op*:  CspSelectOp
    val*: ptr pointer  # RECV: output; SEND: input value

proc cspSelect*(casesPtr: ptr CspSelectCase, n: int): int =
  if n == 0:
    cspSchedYield()
    return -1

  let cases = cast[ptr UncheckedArray[CspSelectCase]](casesPtr)

  # 1. Shuffle for fairness (using non-global random if possible, or just simple xorshift)
  var order = newSeq[int](n)
  for i in 0 ..< n: order[i] = i
  # Simple xorshift for shuffle to avoid std/random thread-safety issues
  var seed = cast[uint64](casesPtr) xor uint64(getTime().toUnix())
  proc nextRand(s: var uint64): int =
    s = s xor (s shl 13)
    s = s xor (s shr 7)
    s = s xor (s shl 17)
    int(s mod uint64(high(int)))

  for i in countdown(n - 1, 1):
    let j = nextRand(seed) mod (i + 1)
    swap(order[i], order[j])

  var defaultIdx = -1
  for i in 0 ..< n:
    if cases[i].op == CspSelectOp.Default:
      defaultIdx = i

  # 2. Poll all channels
  for i in 0 ..< n:
    let idx = order[i]
    if cases[idx].op == CspSelectOp.Default: continue

    if cases[idx].op == CspSelectOp.Recv:
      var v: pointer
      var ok: bool
      if tryRecvGoChan(cases[idx].ch, addr v, addr ok):
        if cases[idx].val != nil: cases[idx].val[] = v
        return idx
    else: # Send
      let sendVal = if cases[idx].val != nil: cases[idx].val[] else: nil
      if trySendGoChan(cases[idx].ch, sendVal):
        return idx

  # 3. If default case exists, return it
  if defaultIdx >= 0:
    return defaultIdx

  # 4. No channel ready; block.
  # De-duplicate and sort channels by address to avoid deadlock during locking
  var uniqueChans: seq[ptr CspGoChan] = @[]
  for i in 0 ..< n:
    if cases[i].op == CspSelectOp.Default: continue
    var found = false
    for uch in uniqueChans:
      if uch == cases[i].ch:
        found = true; break
    if not found:
      uniqueChans.add(cases[i].ch)

  uniqueChans.sort(proc(a, b: ptr CspGoChan): int =
    cmp(cast[uint](a), cast[uint](b))
  )

  let core = cspThisCore
  let self = core.running
  let ex   = cast[ptr CspProcExtra](self.extra)

  var satisfied = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
  satisfied[].store(false)

  # Allocate nodes on heap because we yield
  var nodes = cast[ptr UncheckedArray[CspSelectNode]](allocShared0(n.uint * uint(sizeof(CspSelectNode))))

  # Lock all unique channels
  for ch in uniqueChans:
    discard pthread_mutex_lock(addr ch.lock)

  # Double check readiness while locked
  for i in 0 ..< n:
    let idx = order[i]
    if cases[idx].op == CspSelectOp.Default: continue
    let ch = cases[idx].ch
    if cases[idx].op == CspSelectOp.Recv:
      if ch.size > 0 or (ch.sendQ != nil and ch.capacity == 0) or ch.closed:
        # Something became ready while we were locking
        for uch in uniqueChans: discard pthread_mutex_unlock(addr uch.lock)
        # Cleanup
        deallocShared(satisfied)
        deallocShared(nodes)
        # Try again via tryRecvGoChan
        var v: pointer
        var ok: bool
        if tryRecvGoChan(ch, addr v, addr ok):
          if cases[idx].val != nil: cases[idx].val[] = v
          return idx
        return cspSelect(casesPtr, n) # Should not really happen but for safety
    else: # Send
      if (ch.capacity > 0 and ch.size < ch.capacity) or (ch.recvQ != nil) or ch.closed:
        for uch in uniqueChans: discard pthread_mutex_unlock(addr uch.lock)
        # Cleanup
        deallocShared(satisfied)
        deallocShared(nodes)
        let sendVal = if cases[idx].val != nil: cases[idx].val[] else: nil
        if trySendGoChan(ch, sendVal):
          return idx
        return cspSelect(casesPtr, n)

  # Truly not ready, enqueue everywhere while holding locks
  for i in 0 ..< n:
    let idx = i
    if cases[idx].op == CspSelectOp.Default: continue
    nodes[idx].ch = cases[idx].ch
    nodes[idx].p  = self
    nodes[idx].index = idx
    nodes[idx].op    = cases[idx].op
    nodes[idx].val   = cases[idx].val
    nodes[idx].satisfied = satisfied
    nodes[idx].next  = cases[idx].ch.selectQ
    cases[idx].ch.selectQ = addr nodes[idx]

  # Set state to blocked BEFORE unlocking
  self.statSet(CspProcStatBlocked)

  for uch in uniqueChans:
    discard pthread_mutex_unlock(addr uch.lock)

  # Yield
  cspCoreYield(self, addr core.anchor)

  # After wake up, we were satisfied by someone.
  # We MUST remove all nodes from all channels to avoid dangling pointers.
  # Use the same sorted order to avoid deadlock
  for ch in uniqueChans:
    discard pthread_mutex_lock(addr ch.lock)

  for i in 0 ..< n:
    if cases[i].op == CspSelectOp.Default: continue
    let ch = cases[i].ch
    var prev: ptr CspSelectNode = nil
    var curr = ch.selectQ
    while curr != nil:
      if curr == addr nodes[i]:
        if prev != nil: prev.next = curr.next
        else: ch.selectQ = curr.next
        break
      prev = curr
      curr = curr.next

  for ch in uniqueChans:
    discard pthread_mutex_unlock(addr ch.lock)

  let res = ex.selectIdx
  deallocShared(satisfied)
  deallocShared(nodes)
  return res
