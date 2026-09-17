import ../src/csp
import ../src/core
import std/[posix, nativesockets, os]

proc server(arg: pointer) {.cdecl.} =
  let listenFd = cast[SocketHandle](arg)
  discard posix.write(1, ("Server: listening on fd " & $listenFd.int & "\n").cstring, 26 + ($listenFd.int).len)

  var clientAddr: SockAddr
  var addrLen: SockLen = SockLen(sizeof(clientAddr))

  while true:
    let clientFd = posix.accept(listenFd, addr clientAddr, addr addrLen)
    if clientFd == SocketHandle(-1):
      if errno == EAGAIN or errno == EWOULDBLOCK:
        discard cspNetpollWaitRead(cint(listenFd), 0)
        continue
      discard posix.write(1, "Server: accept failed\n".cstring, 22)
      break

    discard posix.write(1, "Server: accepted client\n".cstring, 24)
    discard cspNetpollRegister(cint(clientFd))

    var buf: array[1024, char]
    let n = cspRead(cint(clientFd), addr buf[0], 1024)
    if n > 0:
      discard posix.write(1, "Server: received data, echoing back\n".cstring, 36)
      discard cspWrite(cint(clientFd), addr buf[0], n.uint)

    discard posix.close(cint(clientFd))
    break
  discard posix.write(1, "Server: done\n".cstring, 13)

proc client(arg: pointer) {.cdecl.} =
  let port = cast[int](arg)
  discard posix.write(1, "Client: connecting to port ".cstring, 27)
  let pstr = $port & "\n"
  discard posix.write(1, pstr.cstring, pstr.len)

  let fd = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0)
  discard posix.write(1, ("Client: fd " & $fd.int & "\n").cstring, 12 + ($fd.int).len)
  discard cspNetpollRegister(cint(fd))

  var name: Sockaddr_in
  name.sin_family = posix.AF_INET.uint16
  name.sin_port = posix.htons(port.uint16)
  name.sin_addr.s_addr = inet_addr("127.0.0.1")

  let res = posix.connect(fd, cast[ptr SockAddr](addr name), SockLen(sizeof(name)))
  if res == -1:
    if errno != EINPROGRESS:
      discard posix.write(1, "Client: connect failed immediately\n".cstring, 35)
      return
    discard cspNetpollWaitWrite(cint(fd), 0)

  discard posix.write(1, "Client: connected, sending data\n".cstring, 32)
  let msg = "Hello from client"
  discard cspWrite(cint(fd), msg.cstring, msg.len.uint)

  var buf: array[1024, char]
  let n = cspRead(cint(fd), addr buf[0], 1024)
  if n > 0:
    discard posix.write(1, "Client: received echo\n".cstring, 22)

  discard posix.close(cint(fd))
  discard posix.write(1, "Client: done\n".cstring, 13)

proc main() =
  cspInit(1)

  let listenFd = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0)
  var name: Sockaddr_in
  name.sin_family = posix.AF_INET.uint16
  name.sin_port = 0
  name.sin_addr.s_addr = INADDR_ANY

  if posix.bindSocket(listenFd, cast[ptr SockAddr](addr name), SockLen(sizeof(name))) == -1:
    echo "bind failed"
    quit(1)
  if posix.listen(listenFd, 5) == -1:
    echo "listen failed"
    quit(1)

  var actualAddr: Sockaddr_in
  var addrLen = SockLen(sizeof(actualAddr))
  discard posix.getsockname(listenFd, cast[ptr SockAddr](addr actualAddr), addr addrLen)
  let port = posix.ntohs(actualAddr.sin_port).int

  discard cspNetpollRegister(cint(listenFd))

  discard cspProcCreate(0, server, cast[pointer](listenFd))
  discard cspProcCreate(0, client, cast[pointer](port))

  discard cspProcCreate(0, proc(a: pointer) {.cdecl.} =
    os.sleep(2000)
    discard posix.write(1, "Timeout, quitting\n".cstring, 18)
    quit(0)
  , nil)

  discard cspCoreRun(cspThisCore)

main()
