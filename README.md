# distro-backdoor-scanner

Tools to scan OS distributions for backdoor indicators.

The toolkit used for the `xz-utils` backdoor is far too sophisticated
to be a first draft. Were there earlier iterations of this, that
shared some things in common but were slightly simpler, injected into
other projects? Can we detect the style/"fist" of the author
elsewhere? Moreso the delivery mechanics than the contents of the
extracted+injected malicious `.so`.

These scripts unpack the source packages for all of a distro repo's
current packages, then scan them for content similar to the malware
that was added to `xz-utils`.

Running over the unpacked source trees of ~19k Gentoo packages and
~40k Debian packages gives a manageable amount of results (~hundreds
of hits), digestable by a human. So far the only confirmed malicious
results are... from the backdoored `xz-utils` versions.

Also, compare the output of the backdoored `xz-utils` decompressing
a large corpus of `.xz` files vs the output of an independent
implementation, just in case of some fancy
[injection](https://www.cs.cmu.edu/~rdriley/487/papers/Thompson_1984_ReflectionsonTrustingTrust.pdf)
of malware into the output stream whenever a recognized block of
tarred-up code is decompressed. Verrry unlikely to catch something,
but easy to look for so why not. So far this has only caught minor
bugs in other decompressors (upstream bugs will be filed, but not
urgent).

There need to be more search patterns, among other things; see
[TODO](TODO.md).

Distros supported:
- Gentoo Linux: Works
- Rocky/RHEL/CentOS Linux: Works
- Debian/Devuan/Ubuntu Linux: Works
- EndeavourOS/Arch: Todo, PRs welcome
