## bench_million.nim
## Goroutine CREATION + DESTRUCTION throughput.
##
## IMPORTANT — what this benchmark does NOT measure: `task` below performs
## one atomic increment and returns immediately. It never blocks, never
## yields, never calls chanSend/chanRecv/cspHangup -- so it never touches
## cspCoreYield/cspProcRestore, the hand-written asm context-switch path.
## A goroutine that starts and finishes without ever giving up the CPU can,
## in principle, be scheduled by code that gets context switching wrong in
## every possible way and this benchmark would never notice.
##
## What this DOES measure, honestly: how fast the custom stack allocator
## (mem.nim) can hand out and reclaim stacks, and how fast the scheduler's
## run queues can absorb a large creation burst -- both real, meaningful
## numbers, just a different claim than "concurrent multitasking is fast".
##
## For an honest measurement of the actual context-switch path, see
## bench_context_switch.nim, which forces a real yield/restore on every
## single channel operation via two goroutines ping-ponging over an
## UNBUFFERED channel hundreds of thousands of times.
import ../src/csp
import std/[os, times, atomics]

proc task(arg: pointer) {.cdecl.} =
  let p = cast[ptr Atomic[int]](arg)
  discard p[].fetchAdd(1)

proc main() =
  let n = 1_000_000
  var count: Atomic[int]
  count.store(0)

  cspMaxProcsHint = uint(n) # size the scheduler's run queue for this burst
                             # up front, instead of paying repeated
                             # backpressure stalls as it fills -- see the
                             # comment on cspSchedulerInit's globalRunq sizing
  cspInit()

  let start = cpuTime()
  for i in 0 ..< n:
    discard cspProcCreate(0, task, addr count)

  while count.load() < n:
    os.sleep(10)

  let elapsed = cpuTime() - start
  echo "Created and destroyed ", n, " goroutines in ", elapsed, "s"
  echo "Rate: ", n.float / elapsed, " goroutines/s (allocator + queue throughput -- see file header)"

  quit(0)

main()
