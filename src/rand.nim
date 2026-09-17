## rand.nim
## xoshiro256** pseudo-random number generator (thread-safe via spinlock).
## Equivalent to src/rand.h + src/rand.c

import std/times
import std/random
import mutex

type
  CspRand* = object
    state: array[4, uint64]
    mutex: CspMutex

proc rotl64(x: uint64, k: int): uint64 {.inline.} =
  (x shl k) or (x shr (64 - k))

proc init*(r: var CspRand) =
  randomize(int(epochTime() * 1e9))
  for i in 0 ..< 4:
    r.state[i] = uint64(rand(high(int)))
  r.mutex.init()

proc next*(r: var CspRand): uint64 =
  let s = r.state
  let t = s[1] shl 17
  let ret = rotl64(s[1] * 5, 7) * 9

  r.state[2] = r.state[2] xor r.state[0]
  r.state[3] = r.state[3] xor r.state[1]
  r.state[1] = r.state[1] xor r.state[2]
  r.state[0] = r.state[0] xor r.state[3]
  r.state[2] = r.state[2] xor t
  r.state[3] = rotl64(r.state[3], 45)
  ret

