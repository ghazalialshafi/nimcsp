import ../src/csp
import ../src/core
import std/posix
import std/os

proc worker(arg: pointer) {.cdecl.} =
  let id = cast[int](arg)
  for i in 1..5:
    let msg = "Worker " & $id & " iter " & $i & "\n"
    discard write(1, msg.cstring, msg.len)
    cspHangup(10 * 1_000_000) # 10ms

proc blocker(arg: pointer) {.cdecl.} =
  discard write(1, "Blocker starting\n".cstring, 17)
  cspBlock:
    discard write(1, "Blocker entered cspBlock, sleeping 500ms\n".cstring, 41)
    os.sleep(500)
    discard write(1, "Blocker woke up from sleep\n".cstring, 27)
  discard write(1, "Blocker finished cspBlock\n".cstring, 26)
  quit(0)

proc main() =
  # Initialize with 1 core to force new threads to be spawned if blocker blocks
  cspInit(1)

  discard cspProcCreate(0, worker, cast[pointer](1))
  discard cspProcCreate(0, blocker, nil)
  discard cspProcCreate(0, worker, cast[pointer](2))

  discard cspCoreRun(cspThisCore)

main()
