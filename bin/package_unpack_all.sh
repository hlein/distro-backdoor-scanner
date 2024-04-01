#!/bin/bash
#
# Unpack the latest eligible version of every package in ::gentoo

die()
{
  echo "$@" >&2
  exit 1
}

UNPACK_LOG=~/parallel_unpack.log
PKG_LIST=~/package_list

for COMMAND in ebuild parallel portageq ; do
  command -v ${COMMAND} >/dev/null || die "${COMMAND} not found in PATH"
done

# Use the same scaling as make.conf, or 4 if unset
JOBS=$(sed -E -n 's/^MAKEOPTS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/portage/make.conf 2>/dev/null)
JOBS="${JOBS:-4}"
# Systems that end up i/o bound should scale down JOBS
##let JOBS=$JOBS/2

# XXX: We should ask portage rather than trying to guess/discover
UNPACK_DIR="/var/tmp/portage/"
test -d "$UNPACK_DIR" || die "Unpack target $UNPACK_DIR does not exist"

for D in /usr/portage/ /var/db/repos/gentoo/ ; do
  test -d "$D" && PORTAGE_DIR="$D" && break
done
test -n "$PORTAGE_DIR" || die "Could not find portage dir"
cd "$PORTAGE_DIR" || die "Could not cd $PORTAGE_DIR"

# List the highest version of each package that is eligible
# (skip non-keyworded/masked packages; skip older when newer exists)
if ! test -s "$PKG_LIST" ; then
  echo "### Generating package list"
  portageq all_best_visible / >"$PKG_LIST"
fi

COUNT=0
TOT=$(wc -l "$PKG_LIST")
echo "### Processing $TOT packages in $JOBS parallel fetch+unpack jobs"
for CAT_P in $(cat "$PKG_LIST") ; do
  # Bail out if our target filesystem(s) are filling
  for FILESYSTEM in "$PORTAGE_DIR" /var/tmp/portage/ ; do
    PCT=$(df "$FILESYSTEM" | awk -F'[ %]+' '/^\//{print $5}')
    test "$PCT" -lt 90 || die "${FILESYSTEM} filesystem at ${PCT}% full, refusing to continue"
  done
  # Skip packages that come from overlays instead of ::gentoo
  if ! test -d "${PORTAGE_DIR}/$(qatom -C -F '%{CATEGORY}/%{PN}' "${CAT_P}")" ; then
    let COUNT=$COUNT+1
    continue
  # Skip packages that have already been unpacked
  elif test -d "/var/tmp/portage/${CAT_P}/work" ; then
    let COUNT=$COUNT+1
    continue
  fi
  EBUILD="$(qatom -C -F '%{CATEGORY}/%{PN}/%{PF}' "$CAT_P").ebuild"
  # Have parallel emit a useful header line for each unpack job
  echo "echo '###   unpack $COUNT/$TOT $CAT_P $EBUILD' && ebuild $(echo \"$EBUILD\") unpack"
  let COUNT=$COUNT+1
done | parallel -j${JOBS} --joblog +${UNPACK_LOG}
