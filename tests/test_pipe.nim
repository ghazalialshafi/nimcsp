import ../src/csp
import ../src/core
import std/[posix, os]

var wg: WaitGroupT

proc reader(arg: pointer) {.cdecl.} =
  let fd = cast[cint](arg)
  discard posix.write(1, "Reader: waiting for data\n".cstring, 25)

  var buf: array[1024, char]
  let n = cspRead(fd, addr buf[0], 1024)
  if n > 0:
    discard posix.write(1, "Reader: got data\n".cstring, 17)
  else:
    discard posix.write(1, "Reader: error or no data\n".cstring, 25)

  discard posix.write(1, "Reader: done\n".cstring, 13)
  wgDone(wg)

proc writer(arg: pointer) {.cdecl.} =
  let fd = cast[cint](arg)
  discard posix.write(1, "Writer: sleeping\n".cstring, 17)
  cspHangup(100 * 1_000_000)

  discard posix.write(1, "Writer: sending data\n".cstring, 21)
  let msg = "Hello from pipe"
  let w = cspWrite(fd, msg.cstring, msg.len.uint)
  discard posix.write(1, "Writer: done\n".cstring, 13)
  wgDone(wg)

proc waiterProc(arg: pointer) {.cdecl.} =
  wgWait(wg)
  discard posix.write(1, "All done, exiting\n".cstring, 18)
  os.sleep(100)
  quit(0)

proc main() =
  cspInit(2)

  wgInit(wg)
  wgAdd(wg, 2)

  var fds: array[2, cint]
  if pipe(fds) == -1: quit(1)

  discard cspNetpollRegister(fds[0])
  discard cspNetpollRegister(fds[1])

  discard cspProcCreate(0, reader, cast[pointer](fds[0]))
  discard cspProcCreate(0, writer, cast[pointer](fds[1]))
  discard cspProcCreate(0, waiterProc, nil)

  discard cspCoreRun(cspThisCore)

main()
