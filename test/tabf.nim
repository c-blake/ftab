import std/[os, strutils], ftab # Simple, self-contained CLI prog for tests/etc.
template match(s): untyped = paramStr(1).startsWith(s)
let u = """Usage:
  ftab p)ut    FTAB FILE_A [..] put files FILE_A .. into FTAB.Lo, FTAB.NL
  ftab d)elete FTAB FILE_A [..] del files FILE_A .. from FTAB.Lo, FTAB.NL
  ftab g)et    FTAB KEY_A [..]  dump vals for KEY_A ..; c)at does the same
  ftab l)ist   FTAB             list keys, one per line
  ftab r)epair FTAB             repair data file
  ftab i)ndex  FTAB             rebuild index from data
  ftab o)rder  FTAB             order data like the index hash order"""
if paramCount() < 1 or paramCount() == 1 and match("h"):
  quit u, 0
let lim  = parseInt(getEnv("lim", "0"))
let dat0 = parseInt(getEnv("dat0", "4096"))
let recS = parseInt(getEnv("recz", "-1"))
let base = paramStr(2)
if   match("p"): # Put
  var t = fTabOpen(base&".Lo", base&".NL", fmReadWrite,
                   recz=recS, dat0=dat0, lim=lim)
  if not t.isOpen: quit(1)
  for i in 3..paramCount():
    if t.put(paramStr(i), paramStr(i).readFile) < 0:
      quit "put failed for: " & paramStr(i), 2
  if t.close < 0: discard
elif match("d"): # Delete
  var t = fTabOpen(base&".Lo", base&".NL", fmReadWrite)
  if not t.isOpen: quit(1)
  for i in 3..paramCount():
    if t.del(paramStr(i)) < 0:
      quit "key not found: " & paramStr(i), 3
  if t.close < 0: discard
elif match("g") or match("c"): # Get|Cat
  var t = fTabOpen(base&".Lo", base&".NL")
  if not t.isOpen: quit(1)
  for i in 3..paramCount():
    let (v, nV) = t.getPtr(paramStr(i))
    if not v.isNil:
      discard stdout.writeBuffer(v, nV)
    else: quit "key not found: " & paramStr(i), 4
  if t.close < 0: discard
elif match("l"): # List; No need for table index
  var t = fTabOpen(base&".Lo", "", dat0 = -1)
  if not t.isOpen: quit(1)
  for (k, nK) in t.keys:
    discard stdout.writeBuffer(k, nK); echo ""
  if t.close < 0: discard
elif match("r"): # Repair
  if fTabRepair(base&".Lo") < 0: quit "failed", 5
elif match("i"): # Index
  if fTabIndex(base&".Lo", base&".NL", lim=lim) < 0: quit "failed", 6
elif match("o"): # Order
  if fTabOrder(base&".Lo", base&".NL") < 0: quit "failed", 7
else:
  quit "Bad use; Run with no args or with \"help\" for help", 1
