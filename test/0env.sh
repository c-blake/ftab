# This file is meant for sourcing via POSIX shell `.` to establish env-vars.
: ${ft:="$HOME/pkg/cb/ft/ftab.out"} # : ${x:=y} lets caller override tested prog
: ${gd:="/tmp/ft"}                  # ..and generated data location
: ${td:="/tmp/ft"}                  # ..and test data location & size params
: ${recz:=256}  # Makes recz 0x100 & offsets from header 0x18 round-ish hex nums
: ${dat0:=2000}
d60="abcdefghijklmnopqrstuvwxyz123456ABCDEFGHIJKLMNOPQRSTUVWXYZ,."
t=$d60
while [ ${#t} -lt $recz ]; do
  d=$t
  t=$t$d60
done
n=/dev/null
set -e                              # halt at first non-zero exit aka error
export recz dat0
