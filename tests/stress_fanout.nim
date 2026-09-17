## stress_fanout.nim
## Adversarial stress test: many goroutines hammering the global run queue
## (work-stealing), buffered and unbuffered channels, and WaitGroup, all at
## once. Designed to exercise paths the small correctness tests don't:
## the lock-free MPMC ring buffer behind the global run queue under heavy
## concurrent push/pop, and channel send/recv under many-to-many contention.
##
## Verifies a correctness invariant (sum of all produced values received
## exactly once) rather than just "didn't crash" -- a lost or duplicated
## message would silently corrupt the sum.

import ../src/csp
import ../src/core
import std/posix

const
  NumProducers = 200
  ItemsPerProducer = 500
  NumWorkers = 32

var
  wgProducers: WaitGroupT
  wgWorkers: WaitGroupT
  work: ptr CspGoChan     # buffered, producers -> workers
  results: ptr CspGoChan  # unbuffered, workers -> collector
  totalSent: int64 = 0

type
  WorkItem = object
    value: int64

proc producer(arg: pointer) {.cdecl.} =
  let id = cast[int](arg)
  for i in 0 ..< ItemsPerProducer:
    var item = cast[ptr WorkItem](allocShared0(sizeof(WorkItem)))
    item.value = int64(id * ItemsPerProducer + i)
    discard chanSend(work, cast[pointer](item))
  wgDone(wgProducers)

proc worker(arg: pointer) {.cdecl.} =
  var ok: bool
  while true:
    let raw = chanRecv(work, addr ok)
    if not ok:
      break
    let item = cast[ptr WorkItem](raw)
    var res = cast[ptr WorkItem](allocShared0(sizeof(WorkItem)))
    res.value = item.value
    deallocShared(item)
    discard chanSend(results, cast[pointer](res))
  wgDone(wgWorkers)

proc collector(arg: pointer) {.cdecl.} =
  var expectedTotal: int64 = 0
  for i in 0 ..< (NumProducers * ItemsPerProducer):
    expectedTotal += int64(i)

  var got: int64 = 0
  var count = 0
  var ok: bool
  while count < NumProducers * ItemsPerProducer:
    let raw = chanRecv(results, addr ok)
    if not ok: break
    let item = cast[ptr WorkItem](raw)
    got += item.value
    deallocShared(item)
    count.inc

  let msg = "collected=" & $count & " expected_count=" & $(NumProducers * ItemsPerProducer) &
            " sum=" & $got & " expected_sum=" & $expectedTotal & "\n"
  discard write(1, msg.cstring, msg.len)

  if count != NumProducers * ItemsPerProducer:
    discard write(1, "FAIL: item count mismatch (lost or duplicated messages)\n".cstring, 57)
    quit(1)
  if got != expectedTotal:
    discard write(1, "FAIL: sum mismatch (data corruption)\n".cstring, 38)
    quit(1)

  discard write(1, "PASS\n".cstring, 5)
  quit(0)

proc closer(arg: pointer) {.cdecl.} =
  wgWait(wgProducers)
  chanClose(work)
  wgWait(wgWorkers)
  chanClose(results)

proc main() =
  cspInit(4)

  wgInit(wgProducers)
  wgInit(wgWorkers)
  wgAdd(wgProducers, NumProducers)
  wgAdd(wgWorkers, NumWorkers)

  work = chanNew(64)
  results = chanNew(0)

  discard cspProcCreate(0, collector, nil)
  for i in 0 ..< NumWorkers:
    discard cspProcCreate(0, worker, nil)
  for i in 0 ..< NumProducers:
    discard cspProcCreate(0, producer, cast[pointer](i))
  discard cspProcCreate(0, closer, nil)

  discard cspCoreRun(cspThisCore)

main()
