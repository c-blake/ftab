## A file table (FTab) puts (kLen,key,vLen,val) unique-key fixed & bounded size
## 4-tuples in a data file & an online, rebuildable index in another.  The data
## is ground truth & always updated first.  When grown, new index files are made
## & moved into place atomically for single-writer-multi-reader access.  Bytes
## 0..7 of a data file fixes record size (>=8) covering length prefixes.  Bytes
## 8..15 are a serial number.  Bytes 16..23 are the head of the free list.  Free
## list pointers are flipped (bitwise `not`) offsets with -1|nil-termination.

when (NimMajor,NimMinor,NimPatch) >= (1,4,0): {.push raises: [].} # [Defect]
else: {.push raises: [].}                       # Earlier Nim have no Defect
when not declared(csize_t):                     # Works back to Nim-0.20.2
  type csize_t = csize

import std/[hashes, os, options, math], memfiles as mf, system/ansi_c

template tryImport(module) =    # if `chronicles` is installed, use it unless
  import module                 # `-d:chronicles_enabled=off` is also given.

template errFallback {.used.} = # define fallback not requiring 10 pkgs to log.
  proc inf(s: string) = (try: stderr.write(s, "\n") except: discard)
  proc err(s: string) = (try: stderr.write(s, "\n") except: discard)

when compiles(tryImport pkg/chronicles):
  import pkg/chronicles/../chronicles
  when loggingEnabled:      # Cannot just do nim-result if C callers want msgs.
    proc inf(s: string) = info("ftab behavior", s)
    proc err(s: string) = error("ftab oserror", s)
  else: errFallback()
else: errFallback()

func roundUp(toRound: int; multiple: int): int = # round up to nearest multiple
  if multiple <= 0: return toRound               # std/math should grow this,IMO
  var remainder = toRound mod multiple
  if remainder == 0: return toRound
  toRound + multiple - remainder

type # The real beginning of this module with main types
  U8     = uint64                     # The 8-bit byte is a done deal..
  TabEnt = distinct uint64            # Hash-prefixed pointer from index->data
  TEs    = ptr UncheckedArray[TabEnt] # Hash table-structured array of those
  FTab* = object        ## A File Table With Deletable, Fixed-Size Entries
    mode: FileMode      # fmRead, fmReadWrite, fmRWExisting; No fmWrite,fmAppend
    datN, tabN: string  # Path names
    datF, tabF: MemFile # Memory mapped files
    lim: int            # Limit to total space used (sum of 2 `*F.size` fields)
    serial: U8          # serial number at open
  Region* = (pointer, int)  ## Simple memory region type

# Region helpers

const NilRegion* = (nil, 0)               ## The Undefined Region
proc mem*(r: Region): pointer = r[0]      ## Get its [0].addr
func len*(r: Region): int = r[1]          ## Get its length
func isNil*(r: Region): bool = r[0].isNil ## Test for being defined
func hash*(r: Region): Hash =             ## Hash its data
  hash(toOpenArray[byte](cast[ptr UncheckedArray[byte]](r[0]), 0, r[1] - 1))
proc mem(q: string): pointer = q[0].unsafeAddr # make string compatible w/Region
proc toRegion(s: string): Region =
  result[0] = s[0].unsafeAddr; result[1] = s.len

# Accessors for .off and .hsh in the table

const hBits  = 16       # Could ->12|*off by blkSize if 256TiB is not enough
const hMaskH = Hash((1 shl hBits) - 1)                  # get hash sfx from full
func hsh(te: TabEnt): Hash = Hash(te.U8 shr (64-hBits)) # hash(key) suffix '>>>'
const offMsk = U8((1 shl (64 - hBits)) - 1)
func off(te: TabEnt): U8 = U8(te) and offMsk            # Get data offset

# Accessors for keys & values from a table entry

func at(f: MemFile, off: U8): pointer = cast[pointer](cast[U8](f.mem) + off.U8)

func kLen(t: FTab, te: TabEnt): int32 =                 # key length
  cast[ptr int32](t.datF.at te.off)[]
func key(t: FTab, te: TabEnt): pointer =                # key offset
  t.datF.at(te.off + 4)

func vN(t: FTab, te: TabEnt): int =                     # val length
  int(cast[ptr uint32](cast[U8](t.key(te)) + t.kLen(te).abs.U8)[])
func val(t: FTab, te: TabEnt): pointer =                # val offset
  cast[pointer](cast[U8](t.key(te)) + t.kLen(te).abs.U8 + 4)

# Accessors for file header metadata

func occu(t: FTab): ptr U8 = cast[ptr U8](t.tabF.at 0)  # occupancy
func tab(t: FTab): TEs     = cast[TEs](t.tabF.at 8)     # for .tab[]
func recz*(t: FTab): U8   = cast[ptr U8](t.datF.at 0)[] # entry size
func serN(t: FTab): ptr U8 = cast[ptr U8](t.datF.at 8)  # serial number
func head(t: FTab): ptr U8 = cast[ptr U8](t.datF.at 16) # free list

# Table size helper code/accessor

func slots(c: int): int = 1 + nextPowerOfTwo(c * 16 div 13 + 16)  # Target size
func slots(t: FTab): int = t.tabF.size div 8 - 1                  # Present size
func tooFull(c, s: int): bool = (c * 16 > s * 13) or (s < c + 16) # Should grow

# More helper code to search|grow the table or to iterate the data

func hash(t: FTab, te: TabEnt): Hash =  # Cache this after len(key)?
  hash (t.key(te), t.kLen(te).int)      # .int critical to match `Region`

# TODO Some workloads frequently iterate over just keys w/kLen << 4096B => want
# an option to embed (well bounded?) key data in hash file.  Also due to such
# workloads, should make checksummed record: kLen, key, kChk, vLen, val, totChk.

func find(t: FTab, q: string|Region|TabEnt, h: Hash): int =
  let mask = t.slots - 1                # Basic linear-probe finder of the index
  var i = h and mask                    #..where `q` either is or should be.
  while (let te = t.tab[i]; U8(te) != 0):
    when q isnot TabEnt:
      if (h and hMaskH) == te.hsh and q.len == t.kLen(te) and
        c_memcmp(t.key(te), q.mem, q.len.csize_t) == 0:
          return i
    # else: growTab TabEnt branch always finds a novel key
    i = (i + 1) and mask
  -i - 1                                # Missing insert @ -(result)-1

proc growTab(t: var FTab): int =        # Grow table by making new & renaming
  var mold = t.tabF                     # Old M)emFile & its table `tOld`
  let tOld = cast[TEs](cast[uint](mold.at 8))
  let nOld = t.slots                    # Old number of slots
  let tmp  = t.tabN & ".tmp"            # New file path
  if t.lim > 0 and (2*t.slots + 1)*8 + t.datF.size > t.lim:
    inf "FTab.growTab " & t.tabN & " OVER " & $t.lim
    return -1                           # Enforce limit/quota
  try:
    t.tabF = mf.open(tmp, fmReadWrite, -1, 0, (2*t.slots + 1)*8, true)
  except:
    err "FTab.growTab cannot open & size \"" & tmp & "\""
    return -2
  for i in 0 ..< nOld:
    if (let te = tOld[i]; te.U8 != 0):
      let h = t.hash(te)
      t.tab[-t.find(te, h) - 1] = te
  t.occu[] = (cast[ptr U8](mold.at 0))[]
  try:
    mold.close
  except:
    err "FTab.growTab cannot close old FTab index \"" & t.tabN & "\""
    return -3
  try:
    moveFile tmp, t.tabN                # Atomic replace
  except:
    err "FTab.growTab cannot replace old FTab index \"" & t.tabN & "\""
    return -4

################ SIMPLE FREE LIST BLOCK ALLOCATION SYSTEM ################
# Byte offs are stored in data as the bitwise-nots; distinct int for safety?

proc threadFree(t: var FTab, off0: U8) = # thread new space into free list
  t.head[] = not off0                   # head = oldEOF, thread rest
  for ix in countup(off0, t.datF.size.U8 - t.recz - 1, t.recz):
    cast[ptr U8](t.datF.at ix)[] = not (ix + t.recz.U8)
  cast[ptr U8](t.datF.at t.datF.size.U8 - t.recz)[] = not 0u64

proc growDat(t: var FTab): int =        # Grow file,thread free list w/new space
  let off0 = t.datF.size.U8             # Old size
  var off1 = off0 + 64 * t.recz         # New size
  if t.lim > 0 and off1 + t.tabF.size.U8 > t.lim.U8:
    let left = U8(t.lim - t.tabF.size - off0.int)
    if left >= t.recz:                  # Round to nearest for best fit can do
      off1 = off0 + U8(left div t.recz) * t.recz
      inf "FTab.growDat NEAR LIMIT " & $t.lim & " ON \"" & t.datN & "\" " & $left
    else:                               # Enforce limit/quota
      inf "FTab.growDat OVER LIMIT " & $t.lim & " ON \"" & t.datN & "\""
      return -1
  try:
    t.datF.resize off1.int              # Grow & remap # TODO fallocate|fallback
  except:
    err "FTab.growDat cannot grow old FTab \"" & t.datN & "\""
    return -2
  t.threadFree off0

proc alloc(t: var FTab, grew: var bool): U8 = # Unlink head of free list
  result = not t.head[]
  if result == 0:                       # Out of space in free list `head`
    if t.growDat < 0:
      return 0
    result = not t.head[]
    grew = true
  t.head[] = cast[ptr U8](t.datF.at(not t.head[]))[]

func free(t: FTab, off: U8) =           # Link block @off to head of free list
  cast[ptr U8](t.datF.at off)[] = t.head[] # .head is already an xptr
  #NOTE: A process crash here can make the free list mis-linked. See `Repair`.
  t.head[] = not off            # (Can repair by mapping out all kLen<0 recs.)

################ MORE USER-VISIBLE/PUBLIC API CALLS ################

template iterate(doYield) {.dirty.} =   # Logic to iterate data, skipping free
  for off in countup(24u64, t.datF.size.U8, t.recz):
    if (let nK = cast[ptr int32](t.datF.at off)[]; nK > 0):
      let nV {.used.} = cast[ptr uint32](t.datF.at off + 4 + nK.U8)[]
      doYield

iterator keys*(t: FTab): Region =
  ## Iterate over just the keys in an open FTab file.
  iterate: yield (t.datF.at(off + 4), nK.int)

iterator kVals*(t: FTab): (Region, Region) =    # Q: items?
  ## Iterate over just the vals in an open FTab file.
  iterate: yield ((t.datF.at(off + 4), nK.int),
                  (t.datF.at(off + 4 + nK.U8 + 4), nV.int))

func getRaw*(t: FTab; key: Region): Region =
  ## Get value buffer for given `key` of length `nK` or `(nil,0)` if missing.
  let i = t.find(key, key.hash)
  if i < 0: NilRegion else: (t.val(t.tab[i]), t.vN(t.tab[i]))

func getPtr*(t: FTab; key: string): Region =
  ## Like `getRaw`, but take a Nim string parameter.
  let i = t.find(key, key.hash)
  if i < 0: NilRegion else: (t.val(t.tab[i]), t.vN(t.tab[i]))

func `$`*(reg: Region): string =
  if not reg.isNil:
    result.setLen reg[1]
    copyMem result[0].addr, reg[0], reg[1]

func get*(t: FTab; key: string): string = $t.getPtr(key)
  ## Alloc-copying call making a string to hold the result; "" if missing.

proc putRaw*(t: var FTab; key, val: Region): int =
  let recz = U8(key.len + val.len + 8)  # Data + k,vLen fields
  if recz > t.recz:
    err $recz & " bytes > \"" & t.datN & "\".recz=" & $ t.recz; return -2
  let h = key.hash
  var i = t.find(key, h)
  if i >= 0:
    err "key \"" & $key & "\" present in \"" & t.datN & "\""
    return -3
  var grew = false      # Flag saying either data|index file grew
  let off = t.alloc(grew)
  if off == 0:
    return -1
  var keyLen = key.len.int32
  var valLen = val.len.uint32
  copyMem t.datF.at(off                     ), keyLen.addr, 4
  copyMem t.datF.at(off + 4                 ), key.mem    , key.len
  copyMem t.datF.at(off + 4 + key.len.U8    ), valLen.addr, 4
  copyMem t.datF.at(off + 4 + key.len.U8 + 4), val.mem    , val.len
  if tooFull(int(t.occu[]) + 1, t.slots):
    if t.growTab < 0:
      t.free off; return -1
    i = t.find(key, h)
    grew = true
  i = -i - 1
  t.tab[i] = TabEnt(U8((h and hMaskH) shl (64 - hBits)) or off)
  t.occu[].inc
  if grew: t.serN[].inc # Updating serial number should always be the last step

proc put*(t: var FTab; key, val: string): int = t.putRaw(key.toRegion, val.toRegion)
  ## Add (`key`, `val`) pair to an open, writable `FTab`. We use "put" to avoid
  ## confusion with Nim's `add` which adds duplicate keys (disallowed here).

func delRaw*(t: FTab; key: Region): int =
  let h = key.hash              # 1) look up in index
  var i = t.find(key, h)
  if i < 0: return -1           # MISSING
  t.free t.tab[i].off           # 2) free in data file
  let mask = t.slots - 1        # 3) free in hash table
  t.occu[].dec
# TODO: Replace aging-friendly backshift delete w/tombstones to make lone-writer
# multi-reader ~ok.  Costs tab rebuild even in steady state to clear out tombs.
  block outer:                  # KnuthV3 Algo6.4R adapted for i=i+1, not i=i-1.
    while true:                 # See: NIM/lib/pure/collections/tableimpl.nim
      var j = i
      var r = j
      t.tab[i] = 0.TabEnt               # mark current EMPTY
      while true:
        i = (i + 1) and mask            # increment mod table size
        if t.tab[i].int == 0:           # end of collision cluster; So all done
          break outer
        r = t.hash(t.tab[i]) and mask   # initial probe index for key@slot i
        if not ((i >= r and r > j) or (r > j and j > i) or (j > i and i >= r)):
          break
      t.tab[j] = t.tab[i]               # [j] will be marked EMPTY next loop

func del*(t: FTab; key: string): int = t.delRaw(key.toRegion)
  ## Delete entry named by key.  Returns -1 if missing.

proc close*(t: var FTab, pad=false): int = ## Release OS resources for open FTab.
  try:
    t.datF.close
    t.datF.mem = nil
  except:
    err "FTab.del cannot close \"" & t.datN & "\""; result -= 1
  if t.tabF.mem != nil:
    try   : t.tabF.close
    except: err "FTab.del cannot close \"" & t.tabN & "\""; result -= 1

func isOpen*(t: FTab): bool = ## Test if successfully opened & still open
  t.datF.mem != nil

proc flush*(t: var FTab, index=false): int =
  ## Flush data to stable storage or return < 0.  Index is optional & off by
  ## default to avoid long pauses from big table writes.  Instead, rely on
  ## service management & post-crash index rebuild ability for that reliability.
  try   : t.datF.flush  # Should be as incremental as new record puts is.
  except: result -= 1
  if index:
    try   : t.tabF.flush
    except: result -= 1

proc fTabRepair*(datNm: string): int =
  ## Recover post-unclean .close by studying unused `kLen<0` space in data.  To
  ## know if this is needed, client code can pre-open check "foo.ok", pre-close
  ## `.flush`, post-close make "foo.ok" (sync may depend on FS).  This checking
  ## logic is not here due to many ways to do/integrate service watchdogs.
  discard # TODO repair; tricky-ish & not on critical path

proc fTabOpen*(datNm: string, tabNm="", mode=fmRead, recz = -1,
               dat0=0, tab0=24, lim=0): FTab

proc fTabIndex*(datNm, tabNm: string, tab0=24, lim=0): int =
  ## Rebuild a hash index from the data file.
  if tabNm.fileExists:
    err "fTabIndex path=\"" & tabNm & "\" exists"
    return -1
  var t = fTabOpen(datNm, tabNm, fmReadWrite, dat0 = -1, lim=lim)
  if not t.isOpen: return -2
  try:
    t.tabF = mf.open(tabNm, fmReadWrite, -1, 0, tab0.slots*8, true)
  except:
    err "fTabIndex cannot open | size \"" & tabNm & "\""
    return -2
  for (n, k) in t.keys:
    let h  = hash((k, n))
    let te = TabEnt((h shl (64 - hBits) or (cast[Hash](k) - 4)))
    var i  = t.find(te, h)
    if i >= 0:          # Should not happen unless things are badly corrupted
      err "fTabIndex duplicate key in \"" & t.datN & "\""
      return -3
    if tooFull(int(t.occu[]) + 1, t.slots):
      if t.growTab < 0: return -3
      i = t.find(te, h)
    i = -i - 1
    t.tab[i] = te
    t.occu[].inc
  t.close

proc fTabOpen*(datNm: string, tabNm="", mode=fmRead, recz = -1,
               dat0=0, tab0=24, lim=0): FTab =
  ## Open|make `FTab` file & its index.  `recz` is the fixed data record limit,
  ## only cross-checked for existing files (<0 => accept any).  For pre-sizing,
  ## `dat0` is an initial data size in bytes or if `<0` a flag saying to not
  ## open the index.  `tab0` is an initial number of keys or if `<0` => rebuild
  ## the index.  `lim>0`, limits the total size of the file pair to be `<= lim`.
  template checkEndian =        # Heuristic to check byte order of CPU vs. data
    if (cast[ptr U8](result.datF.at 0))[] > (1u64 shl 32):
      err "fTabOpen endian-ness of CPU reversed from data file " & datNm

  template closeDat =           # Clean up data file part
    try:
      result.datF.close
    except:
      err "fTabOpen cannot close just opened \"" & datNm & "\""
    result.datF.mem = nil

  template openTab(mode) =      # Open index file part, closing data on failure
    if tab0 < 0 and fTabIndex(datNm, tabNm, lim=lim) < 0:
      err "fTabOpen cannot rebuild index for \"" & datNm & "\""
      closeDat()
      return
    if dat0 >= 0:
      try:
        result.tabF = mf.open(tabNm, mode)
      except:
        err "fTabOpen cannot open " & tabNm
        closeDat()
        return

  result.mode = mode ; result.lim  = lim
  result.tabN = tabNm; result.datN = datNm
  if mode == fmRead:                    # 1) OPEN EXISTING READ-ONLY
    try:
      result.datF = mf.open(datNm); checkEndian()
    except:
      err "fTabOpen cannot open " & datNm & " read-only"
      result.datF.mem = nil             # Just in case; Probably already nil
      return
    openTab(fmRead)
  elif fileExists datNm:                # 2) OPEN EXISTING READ-WRITE
    try:
      result.datF = mf.open(datNm, fmReadWrite, allowRemap=true); checkEndian()
    except:
      err "fTabOpen cannot open " & datNm & " read-write"
      result.datF.mem = nil
      return
    openTab(fmReadWrite)
  else:                                 # 3) MAKE NEW READ-WRITE
    if recz <= 0:
      err "fTabOpen must provide `recz` to make the new " & datNm
      return
    try:
      let dat0 = if dat0 >= 0: 24 + roundUp(dat0 - 24, recz) else: recz + 24
      result.datF = mf.open(datNm, fmReadWrite, -1, 0, dat0, true)
      (cast[ptr U8](result.datF.at 0))[] = recz.U8
      result.threadFree 24              # thread free space from offset 16
      result.tabF = mf.open(tabNm, fmReadWrite, -1, 0, tab0.slots*8, true)
    except: discard
  if recz > 0 and result.recz != recz.U8:
    err "recz=" & $result.recz&" in "&datNm&" does not match open " & $recz.U8
    if result.close < 0:
      err "fTabOpen cannot close just opened \"" & datNm & "\""

proc refresh*(t: var FTab): int =
  ## Re-open a read-only FTab only if needed; Fast if unneeded.
  if t.mode == fmRead and t.serN[] != t.serial:
    if t.close < 0:
      err "FTab.refresh cannot close \"" & t.datN & "\""
      return -1
    t = fTabOpen(t.tabN, t.datN)

proc fTabOrder*(datNm, tabNm: string): int =
  ## Re-write data file to be in the same order as the hash index (to optimize
  ## certain streaming workloads).  This is not safe with other FTab accessors.
  ## This also packs/trims any excess space allocated in the data file, but you
  ## can open it to put more things after if you like.
  var t0 = fTabOpen(datNm, tabNm)
  let datTmp = datNm & ".new"
  let tabTmp = tabNm & ".new"
  var minus1 = not 0u64
  try:
    let d = system.open(datTmp, fmWrite)
    let t = system.open(tabTmp, fmWrite)
    if d.writeBuffer(t0.datF.mem, 8) < 8: return -1 # Copy data header
    if d.writeBuffer(t0.datF.at(8),8) < 8: return -2 # Result has no extra
    if d.writeBuffer(minus1.addr, 8) < 8: return -3 # Result has no extra
    if t.writeBuffer(t0.tabF.mem, 8) < 8: return -4 # Copy index header
    var off = 24u64                                 # data header
    for teO in countup(8u64, t0.tabF.size.U8 - 1, 8u64): #Copy recs in tab order
      let te = cast[ptr U8](t0.tabF.at teO)[]   # Load TabEnt from offset
      if te != 0:                               #TODO and !TOMB
        let off0 = te and offMsk                # old data offset
        if d.writeBuffer(t0.datF.at(off0), t0.recz) < t0.recz.int: return -5
        var te1 = (te and not offMsk) or off    # old hash sfx, new data offset
        if t.writeBuffer(te1.addr, te1.sizeof) < te1.sizeof: return -6
        off += t0.recz
      else:
        if t.writeBuffer(te.unsafeAddr, te.sizeof) < te.sizeof: return -7
    d.close
    t.close
    if t0.close < 0: err "fTabOrder cannot close \"" & datNm & "\""; return -8
    moveFile datTmp, datNm
    moveFile tabTmp, tabNm
  except:
    err "fTabOrder cannot make|populate \"" & datTmp & "\" | \"" & tabTmp & "\""
    return -9

when isMainModule: # Simple, self-contained driver CLI program for testing/etc.
  import std/strutils
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
