# Current TODOs


* `package_unpack_all.sh` &amp; `package_scan_all.sh`:

  - Add Arch distro family
    https://github.com/hlein/distro-backdoor-scanner/issues/20

  - Investigate packages that do not unpack successfully (per-distro)

  - Better annotation/attribution of existing patterns

  - More search patterns

  - Add example output, triaging of false-positives

  - Smartly (re)scan different phases - after fresh unpack, then after
    applying distro patches; this will differ by distro

* Add command-line knobs
  https://github.com/hlein/distro-backdoor-scanner/issues/19

* Add fuzzy matching for m4 files
  https://github.com/hlein/distro-backdoor-scanner/issues/18

* Compare git-tagged versions to Release assets
  See https://github.com/hlein/distro-backdoor-scanner/issues/17

* Analyze `pkgconf` files?
  See https://github.com/hlein/distro-backdoor-scanner/issues/7

* Analyze `IFUNC` use?
  See https://github.com/hlein/distro-backdoor-scanner/issues/16

