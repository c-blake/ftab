# Usage: ./test/basic [foo [300 [256 [0 [ReOrder]]]]]
#                      BASE NUM RECZ LIMIT ANYARG=>ReOrder(needs space)
# A good way to look at the index is: nio pr -fL%x foo.NL | nl -v -2 | less
#   dd if=foo.Lo ibs=24 skip=1 | nio pr .N256C | less
# is not bad for the data but the binary nature of the free list + non-printable
# filtering can make the latter less useful than simply "vim".
# With other defaults, expect 2 different failure modes at limit=65536 & 71720.
# In some sense this one program, run w/diff args replaces test/[0-4]*.

import ../ftab, std/[os, strutils], system/ansi_c
let base = if paramCount() >= 1: paramStr(1) else: "foo"
let num  = if paramCount() >= 2: parseInt(paramStr(2)) else: 300
let recz = if paramCount() >= 3: parseInt(paramStr(3)) else: 256
let lim  = if paramCount() >= 4: parseInt(paramStr(4)) else: 0
let log = base & ".Lo"
let idx = base & ".NL"

try:                                    # 0) Clean up any stale data files
  if log.fileExists: log.removeFile
  if idx.fileExists: idx.removeFile
except: quit "could not remove an old ftab file", 1

proc genKVs(recz: int): seq[(string, string)] =
  const d60 = "abcdefghijklmnopqrstuvwxyz123456ABCDEFGHIJKLMNOPQRSTUVWXYZ,."
  var pad = d60
  while pad.len + d60.len < recz - 16: pad.add d60
  for i in 1..num: result.add ("k" & $i, $i & pad)
let kVs = genKVs(recz)

template withFTab(tX, exCode, theOpen, body) =
  var tX = theOpen
  if not tX.isOpen: quit exCode
  body
  discard tX.close

echo "Testing put"                      # 1) Populate with 3 distinct opens
template putK(tX, test) {.dirty.} =
  withFTab(tX, 2, fTabOpen(log, idx, fmReadWrite, recz, dat0=2000, lim=lim)):
    for (k, v) in kVs:
      if test:
        if tX.put(k, v) < 0: quit 1
putK t1, (k.startsWith("k1"))
putK t2, (k.startsWith("k2"))
putK t3, (not k.startsWith("k1") and not k.startsWith("k2"))

proc count(log: string): int = # TODO cross check with value stored in .NL file
  withFTab(t, 3, fTabOpen(log, "", dat0 = -1)):
    for k, nK in t.keys: inc result

echo "Counting objects"                 # 2) Check we find the correct number 
if log.count != num: quit "wrong number of objects after put", 4

template fchk(tX, test, msg, exCode) {.dirty.} =
  withFTab(tX, exCode, fTabOpen(log, idx)):
    for (k, v) in kVs:                  # Check contents
      if test:
        let (fv, nV) = tX.getPtr(k)
        if cmemcmp(v[0].unsafeAddr, fv, min(v.len, nV).csize_t) != 0:
          echo msg, " at ", k, "\nput: ", v, "\ngot: "
          discard stdout.writeBuffer(fv, nV); echo ""; quit msg, exCode

echo "Testing get after put"            # 3) Check contents
fchk t5, true, "mismatch1", 5

echo "Testing del after put"            # 4) delete some keys across a few opens
template delK(tX, cnt, test) {.dirty.} =
  withFTab(tX, 6, fTabOpen(log, idx, fmReadWrite, lim=lim)):
    for (k, v) in kVs:
      if test: (discard tX.del(k); inc cnt)

var deleted = 0
delK t6, deleted, (k.startsWith("k1"))
delK t7, deleted, (k.startsWith("k2"))

if log.count != num - deleted:          # Check we find the correct number
  quit "wrong number of objects after del", 7

echo "Testing get after del"
fchk t8, not(k.startsWith("k1") or k.startsWith("k2")), "mismatch2", 8
echo "Testing del all"                  # 5) delete the rest
delK t9, deleted, (not k.startsWith("k1") and not k.startsWith("k2"))

if log.count != 0:                      # 6) check that final result is empty
  quit "should be empty", 9

echo "Testing re-populate"              # 7) Re-populate
withFTab(tA, 10, fTabOpen(log, idx, fmReadWrite, lim=lim)):
  for (k, v) in kVs: discard tA.put(k, v)

fchk tB, true, "mismatch3", 11          # 8) Check again

if paramCount() < 5: quit 0 # A full file system cannot support re-ordering

echo "Testing order/pack"

if fTabOrder(log, idx) < 0:             # 9) Order/optimize/pack
  quit "re-order failed", 12

echo "Testing get after order/pack"
fchk tC, true, "mismatch4", 13          #10) Check everything is still there

echo "Testing put after order/pack"

withFTab(tD, 14, fTabOpen(log, idx, fmReadWrite, lim=lim)):
  discard tD.put("K0","helloooo,there") #11) Add new key; K* does NOT match k*

echo "Testing get after put after order/pack"
fchk tE, true, "mismatch5", 15          #12) Check everything is still there
withFTab(tF, 16, fTabOpen(log, idx)):
  if tF.get("K0") != "helloooo,there": echo "K0 mismatch"
