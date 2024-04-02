#!/bin/bash
#
# Unpack the latest eligible version of every package
# Current OSs supported:
# - Debian/Devuan/Ubuntu
# - Gentoo

die()
{
  echo "$@" >&2
  exit 1
}

UNPACK_LOG=~/parallel_unpack.log
PKG_LIST=~/package_list
COMMANDS="parallel "
DOWNLOAD_ONLY=0

test -f /etc/os-release || die "Required /etc/os-release not found"

# Various locations, commands, etc. differ by distro

OS_ID=$(sed -n -E 's/^ID="?([^ "]+)"? *$/\1/p' /etc/os-release 2>/dev/null)

case "$OS_ID" in

  "")
    die "Could not extract an ID= line from /etc/os-release"
    ;;

  debian|devuan|ubuntu)
    COMMANDS+="apt-cache apt-get"
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(egrep '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    PACKAGE_DIR=/var/packages/
    UNPACK_DIR="$PACKAGE_DIR"

    DEB_SRC=$(grep -r '^deb-src' /etc/apt/sources.list* 2>/dev/null | wc -l)
    if [ "$DEB_SRC" = "0" ]; then
      die 'No deb-src entries found in /etc/apt/sources.list*'
    fi

    if [ "$DOWNLOAD_ONLY" = "1" ]; then
      DOWNLOAD_FLAG=--download-only
    fi

    make_pkg_list()
    {
      # List all available packages
      apt-cache search . | cut -d\  -f1
    }

    make_pkg_get_cmd()
    {
      echo "echo '###   unpack $COUNT/$TOT $PKG' && apt-get source $DOWNLOAD_FLAG '$PKG'"
    }
    ;;

  gentoo)
    COMMANDS+="ebuild portageq"
    JOBS=$(sed -E -n 's/^MAKEOPTS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/portage/make.conf 2>/dev/null)
    for D in $(portageq get_repo_path "${EROOT:-/}" gentoo) /usr/portage/ /var/db/repos/gentoo/ ; do
      test -d "$D" && PACKAGE_DIR="$D" && break
    done
    test -n "$PACKAGE_DIR" || die "Could not find package dir"
    UNPACK_DIR="/var/tmp/portage/"

    if [ "$DOWNLOAD_ONLY" = "1" ]; then
      EBUILD_CMD=fetch
    else
      EBUILD_CMD=unpack
    fi

    make_pkg_list()
    {
      # List the highest version of each package that is eligible
      # (skip non-keyworded/masked packages; skip older when newer exists)
      portageq all_best_visible / | sed -E '/^acct-(user|group)\//d'
    }

    make_pkg_get_cmd()
    {
      # Skip packages that come from overlays instead of ::gentoo
      if ! test -d "${PACKAGE_DIR}/$(qatom -C -F '%{CATEGORY}/%{PN}' "${PKG}")" ; then
        return
      fi
      EBUILD="$(qatom -C -F '%{CATEGORY}/%{PN}/%{PF}' "$PKG").ebuild"
      echo "echo '###   unpack $COUNT/$TOT $EBUILD' && ebuild $(echo \"$EBUILD\") $EBUILD_CMD"
    }
    ;;

  *)
    die "Unsupported OS '$OS_ID'"
    ;;
esac

export -f make_pkg_list
export -f make_pkg_get_cmd

# Mirrors will hate you fetching too many in parallel
test "$DOWNLOAD_ONLY" = "1" && test "$JOBS" -gt 4 && JOBS=4

for COMMAND in $COMMANDS ; do
  command -v ${COMMAND} >/dev/null || die "${COMMAND} not found in PATH"
done

# On some OSs, these are the same
test -d "$UNPACK_DIR" || die "Unpack target $UNPACK_DIR does not exist"
cd "$PACKAGE_DIR" || die "Could not cd $PACKAGE_DIR"

if ! test -s "$PKG_LIST" ; then
  echo "### Generating package list"
  make_pkg_list >"$PKG_LIST"
fi

COUNT=0
TOT=$(wc -l "$PKG_LIST")
echo "### Processing $TOT packages in $JOBS parallel fetch+unpack jobs"
while IFS= read -r PKG ; do
  # Bail out if our target filesystem(s) are filling
  for FILESYSTEM in "$PACKAGE_DIR" "$UNPACK_DIR" ; do
    PCT=$(df "$FILESYSTEM" | awk -F'[ %]+' '/^\//{print $5}')
    test "$PCT" -lt 90 || die "${FILESYSTEM} filesystem at ${PCT}% full, refusing to continue"
  done
  make_pkg_get_cmd
  let COUNT=$COUNT+1
done <"$PKG_LIST" | parallel -j${JOBS} --joblog +${UNPACK_LOG}
