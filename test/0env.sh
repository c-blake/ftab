# This file is meant for sourcing via POSIX shell `.` to establish env-vars.
: ${ft:="$HOME/pkg/cb/ft/ftab.out"} # := lets caller over-ride tested program
: ${td:="/tmp/ft"}                  # ..and also test data location
d60="abcdefghijklmnopqrstuvwxyz123456ABCDEFGHIJKLMNOPQRSTUVWXYZ,."
d240="$d60$d60$d60$d60"             # quad-up to get to near, but no over 256
n=/dev/null
set -e                              # halt at first non-zero exit aka error
