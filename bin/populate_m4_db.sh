#!/bin/bash
#
# For a set of git repos harvest every iteration of every .m4 file
# and feed them to find_m4.sh to record their filename, serialno,
# checksum, and other metadata.
#
# These will then be used as a corpus of "known good" .m4 files,
# against which arbitrary repos' .m4 files can be compared.

# Override w/env vars
GNU_REPOS_TOPDIR="${GNU_REPOS_TOPDIR:-${HOME}/gnu-repos/}"
GNU_REPOS_TOPURL="${GNU_REPOS_TOPURL:-https://git.savannah.gnu.org/r/}"

# GNU autotools project repos we will harvest .m4 files from.
# TODO: Add support for specifying arbitrary repos/dirs to include
GNU_REPOS=(
	"autoconf"
	"autoconf-archive"
	"automake"
	"gettext"
	"gnulib"
	"libtool"
)

. /lib/gentoo/functions.sh || {
  # Stubs for non-Gentoo systems
  eerror() { echo "$@"; }
  ewarn() { echo "$@"; }
  einfo() { echo "$@"; }
  eindent() { :; }
  eoutdent() { :; }
}

die()
{
  echo "$@" >&2
  exit 1
}

if command -v find_m4.sh >/dev/null ; then
  FINDM4=find_m4.sh
elif [ -x "${BASH_SOURCE%/*}/find_m4.sh" ]; then
  FINDM4="${BASH_SOURCE%/*}/find_m4.sh"
else
  die "Could not find find_m4.sh in PATH or '${BASH_SOURCE%/*}/'"
fi

GNU_REPOS_TOPDIR="${GNU_REPOS_TOPDIR%/}/"
[[ -d $GNU_REPOS_TOPDIR ]] || die "GNU_REPOS_TOPDIR directory '$GNU_REPOS_TOPDIR' does not exist"
cd $GNU_REPOS_TOPDIR || die "chdir GNU_REPOS_TOPDIR directory '$GNU_REPOS_TOPDIR' failed"

GNU_REPOS_TOPURL="${GNU_REPOS_TOPURL%/}/"

# Warn about cloning repos only the first time
warn_clone_abort=1

DIRS=()
for gnu_repo in "${GNU_REPOS[@]}" ; do
  gnu_repo=${gnu_repo%.git}
  if [[ ! -d "${GNU_REPOS_TOPDIR}/${gnu_repo}" ]]; then
    einfo "Repo '$gnu_repo' not found under '${GNU_REPOS_TOPDIR}', cloning"
    if [[ $warn_clone_abort = 1 ]]; then
      ewarn "Hit ^C within 5 seconds to abort"
      sleep 5
    fi
    warn_clone_abort=0
    git clone ${GNU_REPOS_TOPURL}${gnu_repo}.git/ || die "Clone '${GNU_REPOS_TOPURL}${gnu_repo}.git' failed"
  fi
  DIRS+=( "${GNU_REPOS_TOPDIR}${gnu_repo}" )
done

for dir in "${DIRS[@]}" ; do
  [[ -d "${dir}"/.git ]] && { einfo "Skipping git repo ${dir##*/}, will handle in next loop."; continue; }
  MODE=0 $FINDM4 "${dir}" || exit 1
done

# Now go further and check out every commit touching M4 serial numbers.
# TODO: Use \x00 delimiter
for dir in "${DIRS[@]}" ; do
  [[ -d "${dir}/.git" ]] || continue

  git -C "${dir}" fetch --all --tags || die "git fetch failed"

  # TODO: Could this be parallelized, or does git do locking that
  # would defeat it?
  batch_dirs=()
  while read -d'|' gunk; do
    # Example text:
    # 1994-09-26T03:02:30+00:00 74cc3753fc2479e53045e952b3dcd908bbafef79
    #
    # M    acgeneral.m4
    # M    lib/autoconf/general.m4
    commit=
    files=()
    # TODO: Do we really need the read/printf here?
    while read line ; do
      fragment="${line##*[[:space:]]}"
      if [[ -z ${commit} ]] ; then
        commit="${fragment}"
        continue
      fi

      if [[ ${line} =~ \.m4$ ]] ; then
        files+=( "${fragment}" )
        continue
      fi
    done < <(printf "%s\n" "${gunk}")

    #einfo "Scraping ${dir##*/} at commit ${commit}"

    temp=$(mktemp -d)
    do_serial_check=1
    for file in "${files[@]}" ; do
      filename=${file##*/}
      echo "${dir}" > "${temp}"/${filename}.gitrepo
      echo "${commit}" > "${temp}"/${filename}.gitcommit

      git -C "${dir}" cat-file -p "${commit}:${file}" > "${temp}"/${filename}

      # Don't bother calling find_m4.sh if we didn't find any
      # .m4 files with a serial number in this batch.
      if [[ ${do_serial_check} == 1 ]] && grep -q "serial" "${temp}"/${filename} ; then
        # We found one which is good enough, so don't grep again.
        do_serial_check=0
      fi
    done

    [[ ${do_serial_check} == 0 ]] && batch_dirs+=( "${temp}" )
  done < <(git -C "${dir}" log --diff-filter=ACMR --date-order --reverse --format='| %ad %H' --name-status --date=iso-strict -- '*.m4')

  MODE=0 $FINDM4 "${batch_dirs[@]}" || exit 1
done
