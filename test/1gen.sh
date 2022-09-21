#!/bin/bash
# Usage: ./test/1gen.sh {1..300} (up to 999 as written)

. ${0%1gen.sh}0env.sh               # Mirror user call with .../test/x.sh
# Generate some data files with distinct contents & names
rm -rf $td                          # clear out old
mkdir $td                           # make new
cd $td                              # work in junk/

# Len of $i is 1..3 which happens twice in a record - once in the name & once in
# the value+'k'. So, 2..6+241+8 = 251..255 byte entries up to k999 files anyway.
for i in $*; do                     # 300 files tests 2 tab grows up from 64
  echo "$i$d240" > $td/k$i          # \n from echo may help debug readability
done
