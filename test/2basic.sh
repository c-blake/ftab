#!/bin/bash
# Test basic functionality; Usage: ./test/2basic.sh {1..300}

. ${0%2basic.sh}0env.sh                 # Mirror user call with .../test/x.sh

cd $gd || {                             # work in generated data directory
  echo 1>&2 "Run ${0%2basic.sh}1gen.sh first"
  exit 1
}
t=$td/foo
rm -f $t.*                              # Clean up data files

# A good way to look at the index is: nio pr -fL%x foo.NL | nl -v -2 | less
#   dd if=foo.Lo ibs=24 skip=1 | nio pr .N256C | less
# is not bad for the data but the binary nature of the free list + non-printable
# filtering can make the latter less useful than simply "vim".
echo "Testing put"
$ft p $t k1*                            # 1) Populate with 3 distinct opens
unset recz dat0
$ft p $t k2*
$ft p $t k[3-9]*
# echo k* | tr ' ' \\n | nl -v 0        # to correlate alloc slot w/idx

[ $($ft l $t | wc -l) = $# ] || {       # 2) Check we list the correct number
  echo 1>&2 "wrong number of objects after put"
  exit 2
}

echo "Testing get after put"
for i in $*; do                         # 3) Check contents
  cmp <($ft g $t k$i) <(echo $i$d) >$n 2>&1 || echo mismatch1 at k$i
done

# 4) delete some things across a few opens
echo "Testing del after put"
$ft d $t k1*
$ft d $t k2*
deleted=$(echo k[12]*|wc -w)
remain=$(($#-deleted))
[ $($ft l $t | wc -l) = $remain ] || {  # Check we list the correct number
  echo 1>&2 "wrong number of objects after del"
  exit 3
}

echo "Testing get after del"
for i in $*; do                         # Check contents
  case k$i in k[12]*) continue;; esac
  cmp <($ft g $t k$i) <(echo $i$d) >$n 2>&1 || echo mismatch2 at k$i
done

echo "Testing del all"
$ft d $t k[3-9]*                        # 5) delete the rest

[ $($ft l $t | wc -l) = 0 ] || {        # 6) check that final result is empty
  echo 1>&2 "should be empty"
  exit 4
}

echo "Testing re-populate"
$ft p $t k*                             # 7) Re-populate

for i in $*; do                         # 8) Check again
  cmp <($ft g $t k$i) <(echo $i$d) >$n 2>&1 || echo mismatch3 at k$i
done
