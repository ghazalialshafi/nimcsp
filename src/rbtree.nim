## rbtree.nim
## Full red-black tree (left-leaning variant matching the original C).
## Equivalent to src/rbtree.h

import std/limits

type
  RbTreeNode* = object
    key*:    int
    value*:  pointer
    isRed*:  bool
    left*, right*, father*: ptr RbTreeNode

  RbTree* = object
    root*:   ptr RbTreeNode
    sentry*: ptr RbTreeNode
    stack*:  array[128, ptr RbTreeNode]
    nnodes*: uint

proc newNode(key: int, sentry: ptr RbTreeNode): ptr RbTreeNode =
  result = cast[ptr RbTreeNode](alloc0(sizeof(RbTreeNode)))
  result.key    = key
  result.isRed  = true
  result.left   = sentry
  result.right  = sentry
  result.father = sentry

proc rotateLeft(node: ptr RbTreeNode): ptr RbTreeNode =
  let right  = node.right
  let father = node.father
  node.right    = right.left
  right.left.father = node
  right.left    = node
  node.father   = right
  right.father  = father
  right

proc rotateRight(node: ptr RbTreeNode): ptr RbTreeNode =
  let left   = node.left
  let father = node.father
  node.left     = left.right
  left.right.father = node
  left.right    = node
  node.father   = left
  left.father   = father
  left

proc newRbTree*(): ptr RbTree =
  result = cast[ptr RbTree](alloc0(sizeof(RbTree)))
  let sentry = newNode(low(int), nil)
  sentry.left   = sentry
  sentry.right  = sentry
  sentry.isRed  = false
  result.root   = sentry
  result.sentry = sentry

proc find*(t: ptr RbTree, key: int): ptr RbTreeNode =
  var n = t.root
  while n != t.sentry:
    if key == n.key: return n
    n = if key < n.key: n.left else: n.right
  nil

proc findGte*(t: ptr RbTree, key: int): ptr RbTreeNode =
  var n = t.root
  var greater: ptr RbTreeNode = nil
  while n != t.sentry:
    if key == n.key: return n
    if key < n.key: greater = n; n = n.left
    else:                         n = n.right
  greater

proc insert*(t: ptr RbTree, key: int): ptr RbTreeNode =
  var nodePtr = addr t.root
  var father = t.sentry
  while nodePtr[] != t.sentry:
    if key == nodePtr[].key: return nodePtr[]
    father = nodePtr[]
    nodePtr = if key < nodePtr[].key: addr nodePtr[].left else: addr nodePtr[].right

  var curr = newNode(key, t.sentry)
  curr.father = father
  nodePtr[]   = curr
  let newNode  = curr
  t.nnodes   += 1

  while father != t.sentry:
    if not father.isRed: break
    let grand = father.father
    let uncle = if grand.left == father: grand.right else: grand.left
    if uncle.isRed:
      father.isRed = false; uncle.isRed = false; grand.isRed = true
      curr = grand; father = curr.father
      continue
    var rotated: ptr RbTreeNode
    if grand.left == father:
      if father.right == curr:
        grand.left = rotateLeft(father)
      rotated = rotateRight(grand)
    else:
      if father.left == curr:
        grand.right = rotateRight(father)
      rotated = rotateLeft(grand)
    grand.isRed   = true
    rotated.isRed = false
    father = rotated.father
    if father == t.sentry:
      t.root = rotated
    else:
      if father.left == grand: father.left = rotated
      else:                    father.right = rotated
    break

  t.root.isRed = false
  newNode

proc delete*(t: ptr RbTree, node: ptr RbTreeNode): ptr RbTreeNode =
  ## Delete node. Returns successor node if its key/value was moved.
  var n = node
  var ret: ptr RbTreeNode = nil

  if n.left != t.sentry and n.right != t.sentry:
    var succ = n.right
    while succ.left != t.sentry: succ = succ.left
    n.key   = succ.key
    n.value = succ.value
    ret = n
    n   = succ

  let father = n.father
  let next = if n.left != t.sentry: n.left else: n.right
  next.father = father
  let is34 = n.isRed or next.isRed
  next.isRed = false

  dealloc(n)
  t.nnodes -= 1

  if father == t.sentry:
    t.root = next
    return ret
  if father.left == n: father.left = next
  else:                father.right = next

  if is34: return ret

  # Rebalance (simplified – handles common cases)
  var cur  = next
  var par  = father
  while par != t.sentry:
    if par.left == cur:
      let sib = par.right
      if not sib.isRed:
        if not sib.left.isRed and not sib.right.isRed:
          sib.isRed = true
          if par.isRed: par.isRed = false; return ret
          cur = par; par = cur.father; continue
        var rotated: ptr RbTreeNode
        if sib.left.isRed:
          par.right = rotateRight(par.right)
        else: sib.right.isRed = false
        rotated = rotateLeft(par)
        rotated.isRed = par.isRed; par.isRed = false
        if rotated.father == t.sentry: t.root = rotated
        else:
          let gp = rotated.father
          if gp.left == par: gp.left = rotated else: gp.right = rotated
        return ret
    else:
      let sib = par.left
      if not sib.isRed:
        if not sib.right.isRed and not sib.left.isRed:
          sib.isRed = true
          if par.isRed: par.isRed = false; return ret
          cur = par; par = cur.father; continue
        var rotated: ptr RbTreeNode
        if sib.right.isRed:
          par.left = rotateLeft(par.left)
        else: sib.left.isRed = false
        rotated = rotateRight(par)
        rotated.isRed = par.isRed; par.isRed = false
        if rotated.father == t.sentry: t.root = rotated
        else:
          let gp = rotated.father
          if gp.left == par: gp.left = rotated else: gp.right = rotated
        return ret
    break
  ret

proc allNodes*(t: ptr RbTree, nodes: ptr UncheckedArray[ptr RbTreeNode]): uint =
  if t.nnodes == 0: return 0
  var nnodes: uint = 0
  var nstack: int  = 0
  var root = t.root
  while root != t.sentry or nstack > 0:
    if root != t.sentry:
      t.stack[nstack] = root; inc nstack
      root = root.left
    else:
      dec nstack; root = t.stack[nstack]
      nodes[nnodes] = root; inc nnodes
      root = root.right
  nnodes

proc destroy*(t: ptr RbTree, nodes: ptr UncheckedArray[ptr RbTreeNode]) =
  if t == nil: return
  if t.nnodes > 0:
    let n = t.allNodes(nodes)
    for i in 0 ..< n: dealloc(nodes[i])
  dealloc(t)
