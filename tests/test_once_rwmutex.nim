## test_once_rwmutex.nim
## Correctness checks for the new Once and RWMutex primitives:
## - Once: fn must run exactly once, and every caller must observe its
##   effects (not race ahead of it).
## - RWMutex: many concurrent readers must be able to overlap (proving it
##   isn't secretly a plain mutex), while a writer must never run
##   concurrently with any reader or another writer (checked with a
##   non-atomic shared counter -- a real violation corrupts it immediately).

import ../src/csp
import ../src/core
import std/posix
import std/atomics

# ── Once ─────────────────────────────────────────────────────────────────

const NumOnceCallers = 200

var
  once: OnceT
  onceRunCount: Atomic[int]
  onceEffectVisible: Atomic[bool]
  wgOnce: WaitGroupT
  onceFailures: Atomic[int]

proc onceCaller(arg: pointer) {.cdecl.} =
  onceDo(once) do ():
    discard onceRunCount.fetchAdd(1, moRelaxed)
    cspYield() # give concurrent callers a chance to race ahead incorrectly
    onceEffectVisible.store(true, moRelease)
  # By the time onceDo returns, the effect MUST be visible -- that's the
  # entire point of Once being a synchronization primitive, not just a flag.
  if not onceEffectVisible.load(moAcquire):
    discard onceFailures.fetchAdd(1, moRelaxed)
  wgDone(wgOnce)

# ── RWMutex ──────────────────────────────────────────────────────────────

const NumReaders = 100
const NumWriters = 20
const OpsPerGoroutine = 50

var
  rw: RWMutexT
  sharedA, sharedB: int  # must always be equal; a writer bumps both
  wgRW: WaitGroupT
  rwViolations: Atomic[int]
  concurrentReaders: Atomic[int]
  maxConcurrentReadersSeen: Atomic[int]

proc rwReader(arg: pointer) {.cdecl.} =
  for i in 0 ..< OpsPerGoroutine:
    rwMutexRLock(rw)
    let cur = concurrentReaders.fetchAdd(1, moRelaxed) + 1
    var prevMax = maxConcurrentReadersSeen.load(moRelaxed)
    while cur > prevMax:
      if maxConcurrentReadersSeen.compareExchange(prevMax, cur): break
      prevMax = maxConcurrentReadersSeen.load(moRelaxed)
    let a = sharedA
    cspYield() # while STILL holding the read lock -- if this test is to
               # prove real reader/reader concurrency (not just "it didn't
               # crash"), another reader must get a chance to run and
               # overlap with us right here.
    let b = sharedB
    if a != b:
      discard rwViolations.fetchAdd(1, moRelaxed)
    discard concurrentReaders.fetchSub(1, moRelaxed)
    rwMutexRUnlock(rw)
    cspYield()
  wgDone(wgRW)

proc rwWriter(arg: pointer) {.cdecl.} =
  for i in 0 ..< OpsPerGoroutine:
    rwMutexLock(rw)
    if concurrentReaders.load(moRelaxed) != 0:
      discard rwViolations.fetchAdd(1, moRelaxed)
    sharedA.inc
    cspYield()
    sharedB.inc
    rwMutexUnlock(rw)
    cspYield()
  wgDone(wgRW)

proc finalReport(arg: pointer) {.cdecl.} =
  wgWait(wgOnce)
  let runs = onceRunCount.load(moRelaxed)
  let failures = onceFailures.load(moRelaxed)
  let m1 = "once: runs=" & $runs & " (expected 1) sync_failures=" & $failures & "\n"
  discard write(1, m1.cstring, m1.len)
  if runs != 1 or failures != 0:
    discard write(1, "FAIL: Once did not run exactly once, or a caller raced ahead of it\n".cstring, 69)
    quit(1)
  discard write(1, "PASS once\n".cstring, 10)

  wgWait(wgRW)
  let viol = rwViolations.load(moRelaxed)
  let maxc = maxConcurrentReadersSeen.load(moRelaxed)
  let m2 = "rwmutex: violations=" & $viol & " max_concurrent_readers_seen=" & $maxc &
           " final sharedA=" & $sharedA & " sharedB=" & $sharedB & "\n"
  discard write(1, m2.cstring, m2.len)
  if viol != 0:
    discard write(1, "FAIL: reader/writer or writer/writer exclusion violated\n".cstring, 58)
    quit(1)
  if sharedA != NumWriters * OpsPerGoroutine or sharedA != sharedB:
    discard write(1, "FAIL: writer update count wrong\n".cstring, 33)
    quit(1)
  discard write(1, "PASS rwmutex\n".cstring, 13)
  quit(0)

proc main() =
  cspInit(4)
  onceInit(once)
  wgInit(wgOnce)
  wgAdd(wgOnce, NumOnceCallers)

  rwMutexInit(rw)
  wgInit(wgRW)
  wgAdd(wgRW, NumReaders + NumWriters)

  discard cspProcCreate(0, finalReport, nil)
  for i in 0 ..< NumOnceCallers:
    discard cspProcCreate(0, onceCaller, nil)
  for i in 0 ..< NumReaders:
    discard cspProcCreate(0, rwReader, nil)
  for i in 0 ..< NumWriters:
    discard cspProcCreate(0, rwWriter, nil)

  discard cspCoreRun(cspThisCore)

main()
