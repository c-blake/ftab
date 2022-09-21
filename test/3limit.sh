#!/bin/bash
# Test space limits; Usage: "./test/3limit.sh {1..300}"

. ${0%3limit.sh}0env.sh                 # Mirror user call with .../test/x.sh

cd $td || {                             # work in test data directory
  echo 1>&2 "Run ${0%3limit.sh}1gen.sh first"
  exit 1
}

rm -f foo.*                             # Clean up data files
export lim=65536
recz=256 $ft p foo k* || {              # 1) Hit limit first with data
    echo 1>&2 "got expected error"
}

rm -f foo.*                             # Clean up data files
export lim=71704
recz=256 $ft p foo k* || {              # 2) Hit limit first with index
    echo 1>&2 "got expected error"
}
