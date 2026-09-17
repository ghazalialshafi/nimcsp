## common.nim
## Common macros and utilities.
## Equivalent to src/common.h

template cspLikely*(x: bool): bool =
  ## Hint to the compiler that x is likely true
  x

template cspUnlikely*(x: bool): bool =
  ## Hint to the compiler that x is unlikely true
  x

template cspSoftMbarr*() =
  ## Soft memory barrier (compiler fence)
  {.emit: """asm volatile("" ::: "memory");""".}

template cspSwap*[T](a, b: var T) =
  let tmp = a
  a = b
  b = tmp

proc cspExp*(num: uint): uint =
  ## Compute the exponent such that 2^exp >= num
  if num == 0:
    return 0
  var exp: uint = 0
  var tmp = num
  while tmp != 1:
    inc exp
    tmp = tmp shr 1
  if (1u shl exp) != num:
    inc exp
  return exp
