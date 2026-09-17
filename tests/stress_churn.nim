## stress_churn.nim
## Two adversarial scenarios in one binary:
##
## 1. Channel-close race: many senders and many receivers hammer a single
##    buffered channel concurrently while a closer goroutine closes it
##    partway through. Go's contract: sends after close panic (we count
##    them instead of panicking to keep this a stress test, not a crash
##    test), receives after close/drain return immediately with ok=false,
##    and -- critically -- no goroutine should ever hang waiting on a
##    channel that is already closed and drained.
##
## 2. Rapid churn: thousands of short-lived goroutines are created and
##    exit in quick succession, hammering proc allocation/destruction
##    (the custom per-core stack allocator in mem.nim) and the scheduler's
##    run-queue churn simultaneously.

import ../src/csp
import ../src/core
import std/posix
import std/atomics

# ── Scenario 1: channel close race ──────────────────────────────────────────

const
  NumSenders = 50
  NumReceivers = 50
  SendsPerSender = 200

var
  wgSenders: WaitGroupT
  wgReceivers: WaitGroupT
  raceChan: ptr CspGoChan
  totalSendAttempts: Atomic[int64]
  totalSendOk: Atomic[int64]
  totalRecvOk: Atomic[int64]
  totalRecvClosed: Atomic[int64]
  sentLedger: array[NumSenders * SendsPerSender, Atomic[int32]]
  recvLedger: array[NumSenders * SendsPerSender, Atomic[int32]]

proc raceSender(arg: pointer) {.cdecl.} =
  let id = cast[int](arg)
  for i in 0 ..< SendsPerSender:
    discard totalSendAttempts.fetchAdd(1, moRelaxed)
    let v = id * SendsPerSender + i
    if chanSend(raceChan, cast[pointer](v)):
      discard totalSendOk.fetchAdd(1, moRelaxed)
      discard sentLedger[v].fetchAdd(1, moRelaxed)
    # If the channel is closed, chanSend returns false; either way we must
    # not block forever, which is exactly what a close-race bug would do.
  wgDone(wgSenders)

proc raceReceiver(arg: pointer) {.cdecl.} =
  while true:
    var ok: bool
    let v = chanRecv(raceChan, addr ok)
    if ok:
      discard totalRecvOk.fetchAdd(1, moRelaxed)
      discard recvLedger[cast[int](v)].fetchAdd(1, moRelaxed)
    else:
      discard totalRecvClosed.fetchAdd(1, moRelaxed)
      break
  wgDone(wgReceivers)

proc raceCloser(arg: pointer) {.cdecl.} =
  # Close after only *some* sends have landed, so senders and receivers are
  # genuinely racing against the close rather than being serialized before
  # it -- close-after-drain (the old wgWait(wgSenders)) barely exercises
  # the race at all. Yield a handful of times first so some sends/recvs
  # get scheduled before we pull the rug out.
  for i in 0 ..< 20:
    cspYield()
  chanClose(raceChan)

# ── Scenario 2: rapid churn ──────────────────────────────────────────────────

const NumChurn = 5000

var
  wgChurn: WaitGroupT
  churnCounter: Atomic[int64]

proc churnTask(arg: pointer) {.cdecl.} =
  discard churnCounter.fetchAdd(1, moRelaxed)
  wgDone(wgChurn)

proc churnSpawner(arg: pointer) {.cdecl.} =
  for i in 0 ..< NumChurn:
    discard cspProcCreate(0, churnTask, nil)
  wgWait(wgChurn)
  let msg = "churn: spawned=" & $NumChurn & " completed=" & $churnCounter.load(moRelaxed) & "\n"
  discard write(1, msg.cstring, msg.len)
  if churnCounter.load(moRelaxed) != int64(NumChurn):
    discard write(1, "FAIL: churn count mismatch (proc lifecycle bug)\n".cstring, 50)
    quit(1)
  discard write(1, "PASS churn\n".cstring, 11)
  quit(0)

proc finalReport(arg: pointer) {.cdecl.} =
  wgWait(wgSenders)   # every sender's own post-send bookkeeping is done
  wgWait(wgReceivers) # every receiver has seen the closed signal and exited
  let sa = totalSendAttempts.load(moRelaxed)
  let so = totalSendOk.load(moRelaxed)
  let ro = totalRecvOk.load(moRelaxed)
  let rc = totalRecvClosed.load(moRelaxed)
  let msg = "close-race: send_attempts=" & $sa & " send_ok=" & $so &
            " recv_ok=" & $ro & " recv_closed=" & $rc & "\n"
  discard write(1, msg.cstring, msg.len)
  # Every successful send must correspond to exactly one successful receive
  # (buffered channel, no data loss) -- this is the real correctness check.
  if so != ro:
    discard write(1, "FAIL: send_ok != recv_ok (message lost or duplicated across close)\n".cstring, 68)
    quit(1)
  var dupCount = 0
  for i in 0 ..< NumSenders * SendsPerSender:
    let s = sentLedger[i].load(moRelaxed)
    let r = recvLedger[i].load(moRelaxed)
    if r > s: dupCount.inc
  if dupCount > 0:
    let dm = "FAIL: " & $dupCount & " values received more times than sent (real duplicate delivery)\n"
    discard write(1, dm.cstring, dm.len)
    quit(1)
  # Every receiver must have observed exactly one closed-and-drained signal.
  if rc != NumReceivers:
    discard write(1, "FAIL: not every receiver observed channel close\n".cstring, 50)
    quit(1)
  discard write(1, "PASS close-race\n".cstring, 16)

  discard cspProcCreate(0, churnSpawner, nil)

proc main() =
  cspInit(4)

  wgInit(wgSenders)
  wgInit(wgReceivers)
  wgInit(wgChurn)
  wgAdd(wgSenders, NumSenders)
  wgAdd(wgReceivers, NumReceivers)
  wgAdd(wgChurn, NumChurn)

  raceChan = chanNew(16)

  discard cspProcCreate(0, finalReport, nil)
  discard cspProcCreate(0, raceCloser, nil)
  for i in 0 ..< NumReceivers:
    discard cspProcCreate(0, raceReceiver, nil)
  for i in 0 ..< NumSenders:
    discard cspProcCreate(0, raceSender, nil)

  discard cspCoreRun(cspThisCore)

main()
