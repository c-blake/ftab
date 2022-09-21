#!/bin/bash
# Test at/near 100% disk usage; ./test/4full.sh {1..300}

. ${0%4full.sh}0env.sh                  # Mirror user call with .../test/x.sh

cd $td || {                             # work in test data directory
  echo 1>&2 "Run ${0%4full.sh}1gen.sh first"
  exit 1
}
rm -f foo.*                             # Clean up data file

export recz=256 dat0=2000

# At least on Linux, the nice test here is mkfs, user mount, fill to 100% & run
# things like 2basic.sh, possibly w/a competing `dd if=/dev/zero>junk`.  This
# test logically pairs with the fallocate work item.
