# distro-backdoor-scanner

Tools to scan OS distributions for backdoor indicators.

See [USAGE](USAGE.md) for a rundown of how to use each script.

The toolkit used for the `xz-utils` backdoor is far too sophisticated
to be a first draft. Were there earlier iterations of this, that
shared some things in common but were slightly simpler, injected into
other projects? Can we detect the style/"fist" of the author
elsewhere? Moreso the delivery mechanics - backdooring codebases -
than the contents of the extracted+injected malicious `.so`.

There need to be more search patterns, among other things; see
[TODO](TODO.md).

Distros supported:
- Gentoo Linux: Works
- Rocky/RHEL/CentOS Linux: Works
- Debian/Devuan/Ubuntu Linux: Works
- EndeavourOS/Arch: Todo, PRs welcome

## Checking distfiles

Tools:
* `package_unpack_all.sh`
* `package_scan_all.sh`

These scripts unpack the source packages for all of a distro repo's
current packages, then scan them for content similar to the malware
that was added to `xz-utils`.

Running over the unpacked source trees of ~19k Gentoo packages and
~40k Debian packages gives a manageable amount of results (~hundreds
of hits), digestable by a human. So far the only confirmed malicious
results are... from the backdoored `xz-utils` versions.

## Checking M4 macros

Tools:
* `populate_m4_db.sh`
* `find_m4.sh`

These scripts harvest every iteration of every `.m4` macro file ever
committed to some specific repos considered "known good" (if, say, GNU
`automake` upstream has already been trojaned, then the preppers were
right, civilization is ending). Build an SQLite database of files,
their embedded `serial` numbers (if any), their plain `sha256`
checksum plus a checksum of the file contents with comments and
whitespace-only lines removed.

Then, for a given tree of sources (such as unpacked by
`package_unpack_all.sh`), bash every `.m4` file found against the
known-good database. Alert on `.m4` files that differ from any known
upstream, and emit cut-and-paste-able `git diff` commands for human
review (maybe the package customized it for good reason...  or maybe
to hide a trojan). Also warn about new `.m4` files (nothing inherently
wrong with a package shipping its own, but noteworthy). Generate a
database of unknowns, so that package A's `new.m4` and package B's
`nouveau.m4` can be recognized to be the same, suggesting a shared
upstream and/or developer.

Running over the source trees of ~19k Gentoo packages containing 50k
`.m4` files finds about 8k that are unrecognized (new, or modified).
That number should shrink if more popular upstreams are added to the
"known good" corpus.

## Comparing decompression output

Tools:
* `package_decompcheck_all.sh`

Compare the output of the backdoored `xz-utils` decompressing
a large corpus of `.xz` files vs the output of an independent
implementation, just in case of some fancy
[injection](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf)
of malware into the output stream whenever a recognized block of
tarred-up code is decompressed. Verrry unlikely to catch something,
but easy to look for so why not. So far this has only caught minor
bugs in other decompressors (upstream bugs will be filed, but not
urgent).
