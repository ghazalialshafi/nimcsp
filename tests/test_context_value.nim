## test_context_value.nim
## Correctness checks for Context.WithValue/Value:
## - a value set on a context is visible to that context and its children
## - a closer ancestor's value shadows a farther one with the same key
## - unrelated keys return nil
## - WithValue doesn't create a new cancellation scope: Done()/Err() on a
##   value-only descendant reflect the nearest real ancestor scope

import ../src/csp
import ../src/core
import std/posix

var failures = 0

proc fail(msg: string) =
  discard write(1, ("FAIL: " & msg & "\n").cstring, msg.len + 7)
  failures.inc

proc testBasicLookup() =
  let root = cspContextBackground()
  let withA = cspContextWithValue(root, "a", cast[pointer](111))
  let withAB = cspContextWithValue(withA, "b", cast[pointer](222))

  if cast[int](cspContextValue(withAB, "a")) != 111:
    fail("value from grandparent not visible to child")
  if cast[int](cspContextValue(withAB, "b")) != 222:
    fail("value from immediate parent not visible")
  if cspContextValue(withAB, "nonexistent") != nil:
    fail("lookup of missing key did not return nil")
  if cspContextValue(root, "a") != nil:
    fail("value leaked upward to an ancestor that never set it")
  discard write(1, "PASS basic_lookup\n".cstring, "PASS basic_lookup\n".len)

proc testShadowing() =
  let root = cspContextBackground()
  let outer = cspContextWithValue(root, "k", cast[pointer](1))
  let inner = cspContextWithValue(outer, "k", cast[pointer](2))
  if cast[int](cspContextValue(inner, "k")) != 2:
    fail("closer context's value did not shadow the farther one")
  if cast[int](cspContextValue(outer, "k")) != 1:
    fail("outer context's own value was corrupted by shadowing")
  discard write(1, "PASS shadowing\n".cstring, "PASS shadowing\n".len)

proc testValueIndependentOfCancellation(arg: pointer) {.cdecl.} =
  let root = cspContextBackground()
  let cancelable = cspContextWithCancel(root)
  let withVal = cspContextWithValue(cancelable, "k", cast[pointer](42))

  cspContextCancel(cancelable)
  var ok: bool
  discard recvGoChan(cspContextDone(withVal), addr ok)

  if cspContextErr(withVal) != CspContextErr.Canceled:
    fail("value-only child did not see ancestor's cancellation via Err()")
  if cast[int](cspContextValue(withVal, "k")) != 42:
    fail("value was lost after the ancestor scope was canceled")
  discard write(1, "PASS value_independent_of_cancel\n".cstring, "PASS value_independent_of_cancel\n".len)

  if failures == 0:
    discard write(1, "PASS all\n".cstring, "PASS all\n".len)
    quit(0)
  else:
    quit(1)

proc main() =
  cspInit(2)
  testBasicLookup()
  testShadowing()
  discard cspProcCreate(0, testValueIndependentOfCancellation, nil)
  discard cspCoreRun(cspThisCore)

main()
