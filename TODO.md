# Current TODOs

- Add more distro families (ironically tracked in [README](README.md)
  instead of here)

- Better annotation/attribution of existing patterns

- More search patterns

- Add example output, triaging of false-positives

- Add command-line knobs

- Investigate packages that do not unpack successfully (per-distro)

- Smartly (re)scan different phases - after fresh unpack, then after
  applying distro patches; this will differ by distro

- Add fuzzy matching
  ([ssdeep](https://ssdeep-project.github.io/ssdeep/index.html) or
  similar) in `.m4` processing to find the best/closest reference
  match for new or modified `.m4` files.

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
