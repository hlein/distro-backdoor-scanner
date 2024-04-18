# Current TODOs

- Add more distro families (ironically tracked in [README](README.md)
  instead of here)

- Better annotation/attribution of existing patterns

- More search patterns

- Better (any) usage documentation

- Add example output, triaging of false-positives

- Add command-line knobs

- Investigate packages that do not unpack successfully (per-distro)

- Smartly (re)scan different phases - after fresh unpack, then after
  applying distro patches; this will differ by distro

- Analyze `.m4` files bundled with individual packages looking for
  ones that are copies from some upstream (autoconf, automake, etc.)
  _and_ which have been modified, with or without updating the
  serial number; look into those mods. Work ongoing in
  [this branch](https://github.com/hlein/distro-backdoor-scanner/compare/master...thesamesam:m4)

- Compare &amp; explore the differences between git-tagged versions
  (retrievable as generated archives from e.g. GitHub) and Release
  assets. The "Asset" tarball for a given version can differ from what
  was tagged for that release, for what are perceived as good reasons.
  That discrepancy was what allwed `xz-utils` Release assets to have
  parts of the backdoor embedded that did not match what was in the
  Git repo. So: how common is that? Can we bring some extra scrutiny
  to the differences?

- Analyze pkgconf files?
  See https://github.com/hlein/distro-backdoor-scanner/issues/7

- Convert this list to GH issues... maybe
