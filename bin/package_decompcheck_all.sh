#!/bin/bash
#
# Decompress every .xz found in source dir(s) using xz and
# an alternate implementation, error if any differences.
# XXX: add .lzma as well?

warn()
{
  echo "$@" >&2
}
export -f warn

die()
{
  warn "$@"
  exit 1
}
export -f die

CHECK_LOG=~/parallel_checksum.log
PKG_LIST=~/package_list
COMMANDS="parallel xz "
BATCH_SIZE=20
BATCH_NUM=0

export ALT_XZ="gxz"
COMMANDS+="$ALT_XZ"

verbose()
{
  test "$VERBOSE" = "1" && echo "$@"
}
export -f verbose

do_compare()
{
  THIS_COUNT=1
  for F in "$@" ; do
    verbose "###   child $$ processing '$F'"

    # Force a single thread since we are parallelizing one level up
    XZ_SUM=$(xz -d -T1 < "$F" | sha256sum; exit ${PIPESTATUS[0]})
    test $? != "0" && warn "### child $$ error on file $THIS_COUNT, '$F'" && continue

    XZ_SUM=${XZ_SUM%% *}

    # May need tweaking for other implementations w/different args
    ALT_SUM=$($ALT_XZ -d < "$F" | sha256sum; exit ${PIPESTATUS[0]})
    test $? != "0" && warn "### child $$ error on file $THIS_COUNT, '$F'" && continue

    ALT_SUM=${ALT_SUM%% *}

    # Force a mismatch for testing
    #ALT_SUM+="wakkawakka"

    if [ "$XZ_SUM" != "$ALT_SUM" ]; then
      die "Mismatch for '$F': xz '$XZ_SUM' vs $ALT_XZ '$ALT_SUM'"
    fi
    let THIS_COUNT=$THIS_COUNT+1
  done
}
export -f do_compare

test -f /etc/os-release || die "Required /etc/os-release not found"

# Various locations, commands, etc. differ by distro

OS_ID=$(sed -n -E 's/^ID="?([^ "]+)"? *$/\1/p' /etc/os-release 2>/dev/null)

case "$OS_ID" in

  "")
    die "Could not extract an ID= line from /etc/os-release"
    ;;

  debian|devuan|ubuntu)
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    OBJ_DIR="/var/packages/"
    ;;

  gentoo)
    JOBS=$(sed -E -n 's/^MAKEOPTS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/portage/make.conf 2>/dev/null)
    OBJ_DIR="$(portageq distdir)"
    if [ -z "$OBJ_DIR" ]; then
      OBJ_DIR="/usr/portage/distfiles/"
    else
      # Make sure there is a trailing slash
      OBJ_DIR="${OBJ_DIR%/}/"
    fi
    ;;

  # XXX: only actually tested on Rocky Linux yet
  centos|fedora|rhel|rocky)
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    OBJ_DIR="/var/repo/BUILD/"
    ;;

  *)
    die "Unsupported OS '$OS_ID'"
    ;;
esac

for COMMAND in $COMMANDS ; do
  command -v ${COMMAND} >/dev/null || die "${COMMAND} not found in PATH"
done

test -d "$OBJ_DIR" || die "Object dir '$OBJ_DIR' does not exist"

echo "### Building a list of '.xz' objects in '${OBJ_DIR}'..."

# Some distros unpack tarballs in the same dir those tarballs live;
# we are currently only concerned with checking those toplevel files.
# For other distros, limiting depth will have no impact.
mapfile -d '' OBJS < <(find "${OBJ_DIR}" -maxdepth 1 -type f -name \*.xz -print0)
export OBJ_COUNT=${#OBJS[@]}
BATCHES=$(( ($OBJ_COUNT + $BATCH_SIZE - 1) / $BATCH_SIZE))

COUNT=0
echo "### Processing $OBJ_COUNT objects in $JOBS parallel decompress-compare jobs"

printf "%s\0" "${OBJS[@]}" | \
    parallel -0 -j$JOBS -n $BATCH_SIZE --line-buffer --joblog +${CHECK_LOG} \
    'echo "### child $$ processing batch {#}/'"$BATCHES"'" && do_compare {} && echo "### child $$ finished"'

