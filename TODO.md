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

- Convert this list to GH issues... maybe
