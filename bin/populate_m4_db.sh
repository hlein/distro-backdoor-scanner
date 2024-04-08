#!/bin/bash
# Complements find_m4.sh which only knows how to scrape
# .m4 files from given directories.
#
# This script, otoh, handles the git mangling to go through
# and find useful serial numbers for us to put in the DB.

. /lib/gentoo/functions.sh || {
  # Stubs for non-Gentoo systems
  eerror()
  {
    echo "$@"
  }

  ewarn()
  {
    echo "$@"
  }

  einfo()
  {
    echo "$@"
  }

  eindent()
  {
    :;
  }

  eoutdent()
  {
    :;
  }
}

die()
{
  echo "$@" >&2
  exit 1
}

# Basic set of directories (git checkouts of core GNU autotools projects)
DIRS=(
    "/home/sjames/git/autoconf"
    "/home/sjames/git/autoconf-archive"
    "/home/sjames/git/automake"
    "/home/sjames/git/gettext"
    "/home/sjames/git/gnulib"
    "/home/sjames/git/libtool"
)

for dir in "${DIRS[@]}" ; do
  [[ -d "${dir}" ]] || { die "Need to clone ${dir##*/}?"; }
  [[ -d "${dir}"/.git ]] || { echo "Skipping git repo ${dir##*/}, will handle in next loop."; continue; }
  # TODO: https://mywiki.wooledge.org/BashFAQ/028
  MODE=0 bash bin/find_m4.sh "${dir}"
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
      if [[ -z ${commit} ]] ; then
        commit="${line##*[[:space:]]}"
        continue
      fi

      if [[ ${line} =~ \.m4$ ]] ; then
        files+=( "${line##*[[:space:]]}" )
        continue
      fi
    done < <(printf "%s\n" "${gunk}")

    #einfo "Scraping ${dir##*/} at commit ${commit}"

    temp=$(mktemp -d)
    do_serial_check=1
    for file in "${files[@]}" ; do
      git -C "${dir}" cat-file -p "${commit}:${file}" > "${temp}"/${file##*/}

      # Don't bother calling bin/find_m4.sh if we didn't find any
      # .m4 files with a serial number in this batch.
      if [[ ${do_serial_check} == 1 ]] && grep -q "serial" "${temp}"/${file##*/} ; then
        # We found one which is good enough, so don't grep again.
        do_serial_check=0
      fi
    done

    [[ ${do_serial_check} == 0 ]] && batch_dirs+=( "${temp}" )
  done < <(git -C "${dir}" log --diff-filter=ACMR --date-order --reverse --format='| %ad %H' --name-status --date=iso-strict -- '*.m4')

  # TODO: https://mywiki.wooledge.org/BashFAQ/028
  MODE=0 bash bin/find_m4.sh "${batch_dirs[@]}"
done
