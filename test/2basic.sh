#!/bin/bash
# Test basic functionality; Usage: ./test/2basic.sh {1..300}

. ${0%2basic.sh}0env.sh                 # Mirror user call with .../test/x.sh

cd $td || {                             # work in test data directory
  echo 1>&2 "Run ${0%2basic.sh}1gen.sh first"
  exit 1
}
rm -f foo.*                             # Clean up data file

export recz=256 # Makes recz 0x100 & offsets from header 0x18 round-ish hex nums
                # (i.e. not so hard to read in any endian-ness).
export dat0=2000
# A good way to look at the index is: nio pr -fL%x foo.NL|nl -v -1 |less
#   dd if=foo.N256C ibs=24 skip=1 | nio pr .N256C | less
# is not so bad but the binary nature of the free list + non-printable
# filtering can make the latter less useful than simply "vim".
$ft p foo k1*                           # 1) Populate with 3 distinct opens
unset recz dat0
$ft p foo k2*
$ft p foo k[3-9]*
# echo k* | tr ' ' \\n | nl -v 0          # to correlate alloc slot w/idx

[ $($ft l foo | wc -l) = $# ] || {      # 2) Check we list the correct number
  echo 1>&2 "wrong number of objects after put"
  exit 2
}

for i in $*; do                         # 3) Check contents
  cmp <($ft g foo k$i) <(echo $i$d240) >$n 2>&1 || echo mismatch1 at k$i
done

# 4) delete some things across a few opens
$ft d foo k1*
$ft d foo k2*
deleted=$(echo k[12]*|wc -w)
remain=$(($#-deleted))
[ $($ft l foo | wc -l) = $remain ] || { # Check we list the correct number
  echo 1>&2 "wrong number of objects after del"
  exit 3
}

for i in $*; do                         # Check contents
  case k$i in k[12]*) continue;; esac
  cmp <($ft g foo k$i) <(echo $i$d240) >$n 2>&1 || echo mismatch2 at k$i
done

$ft d foo k[3-9]*                       # 5) delete the rest

[ $($ft l foo | wc -l) = 0 ] || {       # 6) check that final result is empty
  echo 1>&2 "should be empty"
  exit 4
}

$ft p foo k*                            # 7) Re-populate

for i in $*; do                         # 8) Check again
  cmp <($ft g foo k$i) <(echo $i$d240) >$n 2>&1 || echo mismatch3 at k$i
done

ls -l foo.*
$ft o foo                               # 9) Order/optimize/pack
ls -l foo.*

for i in $*; do                         #10) Check everything is still there
  cmp <($ft g foo k$i) <(echo $i$d240) >$n 2>&1 || echo mismatch4 at k$i
done

echo hellooooooooooo,there > K0         #11) Add something new; Do NOT match k*
$ft p foo K0

for i in $*; do                         #12) Check EVERYthing is still there
  cmp <($ft g foo k$i) <(echo $i$d240) >$n 2>&1 || echo mismatch5 at k$i
done
cmp <($ft g foo K0) <(echo hellooooooooooo,there) >$n 2>&1 || echo K0 mismatch
