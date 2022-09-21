BACKGROUND
==========

Nim is a systems programming language.  Part of systems culture is efficiency
which often entails saving answers rather than re-computing them.  A simple key
value store is often adequate.  Consequently, some variation of file-based KV
stores of some kind are already present in 5 of my current repos.  To answer a
why-so-many question begged, here's a quick list:

|Module                                                            |Notes               |
|------------------------------------------------------------------|:-------------------|
|[ndup/setFile](github.com/c-blake/ndup/blob/main/ndup/setFile.nim)|small,RH,NoSatellite|
|[suggest](github.com/c-blake/suggest)                             |~tightly integrated |
|[adix/lptabz](github.com/c-blake/adix/blob/master/adix/lptabz.nim)|RH,save,load,mmapRO |
|[pack](github.com/c-blake/nimsearch/blob/main/pack.nim)           |strict append only  |
|[thes](github.com/c-blake/thes)                                   |mostly pedagogical  |

Of these, only `lptabz` supports deletes, but not against "live files".  All of
the above cases are just "embedded use" within a wider package.  [The DBM
family](https://en.wikipedia.org/wiki/DBM_(computing)) also has many members.

String orientation makes `FTab` "weakly typed" in the prog.lang. sense.  This is
typical in the key-value/blob store space.  `lptabz` above comes closes to an
escape, but really only works on files with value types.  Other approaches for
strongly typed data are at https://github.com/c-blake/nio and
https://github.com/Vindaar/nimhdf5 and probably elsewhere.

BASICS
======

So, to fill a gap needed by some Nim use cases, enter this 6th variant - `FTab`,
a file table.  The goal here is the simplest possible reasonably safe and
efficient native Nim persistent KV store that supports delete & space limits
with unsorted string keys & values of fixed (total) size.

This is implemented with 2 files - a ground truth data file & an index. { `FTab`
is most similar to (and began life as a hard fork of) the indexed log `Pack`. }
With no deletion, a data file is much like a log - back-to-back (kLen, key,
vLen, val) records after a tiny header.  An index is an open-addressed hash
array with high latency-friendly linear probing.  Keys can optionally be
embedded (with their own bound) in the index for efficient iteration (with a
trade off of a bigger index adding more chance for 2-disk latency lookups).

The allocator is kept simple here with a constraint of fixed (K+V total) size
records (in both over-time & over-objects senses) and single-writer access.
Such constraints can be relaxed, perhaps suboptimally, on top/outside of `ftab`.
{ E.g., for diverse value sizes, users can set up many power-of-2 FTabs, naming
keys to "route" lookups.  For dynamic value sizes, users can del old & put new.
A server front-end/locking can mediate concurrent access at some expense. }
One reason I called it simply `FTab` is so a more full featured wrapper could be
`FileTab`.

DETAILS
=======

Space Limits
------------

A space checking calculation might|might not include the transient space for a
new index.  It is tricky which is best - limiting *enduring* space use or an
electric fence to never cross.  Multiple readers can also keep old index space
live if they do not refresh.  Only the OS may know if such space is live.  Only
client code knows if there are multiple readers.  In light of all this, for now
transient space is not included in the limit calculation.  Things should work ok
to expand the space limit from open-to-open.  Shrinking it is likely bad, but
may work if you do not shrink beyond how big the files have already grown.

Need To Flush
-------------

This code uses memory mapped writes.  Stable storage throughput can be more slow
than RAM is large.  So, client code adding data quickly (on the relevant scale)
should periodically synchronously wait for a `flush` to finish.  This gives the
OS a chance to un-dirty enough memory pages.  This is a necessary byproduct of
the OS taking ownership of flushing dirty memory pages to disk which adds a lot
of resilience to process crashes (but not OS crashes).

Concurrent Safety
-----------------

On its own, this is lone-writer/multi-reader safe only in limited ways.  New
tables are always renamed into place atomically and there is a serial number to
make parallel reader `refresh` calls fast (to get a new view on the index and
data file as it grows).  It is still possible for the lone writer to delete &
replace a record with new data after a reader-`refresh`, but before a reader
finishes access.  There is a whole-file serial number a reader can check (say,
saved before lookup and verified unchanged after copying out the data).

The serial number is mostly helpful for point queries.  Even with it, a reader
iterating over all records just on the data file could still see partial updates
and only know from a changed serial number that "something changed somewhere
during a very long scan".  Adding a per record checksum to the end of each
record is future work.

Crash Recovery
--------------

Crash recovery is also future work relating to adding an end of record checksum.
Recovery can consist of rebuilding the index excluding all mismatching records.
It is likely best for right now to not think of it as very crash recoverable.
