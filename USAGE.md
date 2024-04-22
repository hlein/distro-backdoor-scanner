## Usage

### Unpack and Scan Distro Sources

Typical use:
1. Run `package_unpack_all.sh`
2. Run `package_scan_all.sh`.

#### package_unpack_all.sh

No command-line args or knobs; edit the script to add support for
another distribution (PR please!), or to set `PACKAGE_DIR` and/or
`UNPACK_DIR` to override per-distro defaults, or `JOBS` to change the
level of parallelization.

#### package_scan_all.sh

No command-line args or knobs; same `PACKAGE_DIR`, `UNPACK_DIR`,
`JOBS` as `package_unpack_all.sh`. Also add/update patterns in the
perl script embedded in the `do_dirs()` function (again, PR please!).

### Compare Decompressor Implementations

Typical use:
1. Run `package_unpack_all.sh`.
2. Run `package_decompcheck_all.sh`.

#### package_decompcheck_all.sh

No command-line args or knobs; edit the script to change the
distro-determined `OBJ_DIR` path or to change the name &amp; args to
the alternate decompressor.

### Identify Modified `.m4` Macro Files

Typical use:
1. Run `populate_m4_db.sh` to create a reference database.
2. Run `package_unpack_all.sh` to collect
3. Run `MODE=1 find_m4.sh` compare unpacked packages' `.m4` files to the known references.

#### populate_m4_db.sh

Has some variables which can be overriden on the command line:

* `GNU_REPOS_TOPDIR`: path to where "known good" Git repos are checked
out.
* `GNU_REPOS_TOPURL`: common URL prefix for "known good" repos.
* `NO_NET`: set to non-zero to prevent any outbound network connections
(requires that you have already cloned the needed repos).
* `TMPDIR`: _lots_ of tempdirs will be created under here during
repo-spelunking; should properly clean up after itself.

And one which you must edit the script to cahnge:
* `GNU_REPOS`: list of "known good" repos to check out.

This script calls `MODE=0 find_m4.sh ...` to process the `.m4` files
it finds.

#### find_m4.sh

##### `MODE=0 find_m4.sh ...`

Called with `MODE=0` set, create a DB of known `.m4` files, their
names, serial numbers, and checksums. (This is typically not done
directly, but called by `populate_m4_db.sh`.)

##### `MODE=1 find_m4.sh ...`

Called with `MODE=1` set, find `.m4` files in source trees (set
`M4_DIR` to specify the topdir; otherwise it is set to `UNPACK_DIR`
using the same per-distro handling as `package_unpack_all.sh`).

At the end of the run, outputs lists of not-seen-before `.m4` files, and `git
diff` commands macros that have been seen before but do not match.

Set `VERBOSE=1` for more immediate runtime output (expected vs found
hash values, `git diff` commands, etc.) rather than only wait for the
end.

Set `DEBUG=1` to spam your console.
