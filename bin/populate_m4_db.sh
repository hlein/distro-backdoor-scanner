#!/bin/bash
#
# For a set of git repos harvest every iteration of every .m4 file
# and feed them to find_m4.sh to record their filename, serialno,
# checksum, and other metadata.
#
# These will then be used as a corpus of "known good" .m4 files,
# against which arbitrary repos' .m4 files can be compared.

# Override w/env vars
KNOWN_REPOS_TOPDIR="${KNOWN_REPOS_TOPDIR:-${HOME}/known-repos/}"
GNU_REPOS_TOPURL="${GNU_REPOS_TOPURL:-https://git.savannah.gnu.org/r/}"
NO_NET="${NO_NET:-0}"

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

# Other repos we will harvest. These should be full clonable URLs
OTHER_REPOS=(
	"https://github.com/freetype/freetype"
	"https://gitlab.gnome.org/GNOME/gnome-common"
	"https://gitlab.gnome.org/GNOME/gobject-introspection"
	"https://gitlab.gnome.org/GNOME/gtk-doc"
	"https://github.com/pkgconf/pkgconf"
	"https://gitlab.gnome.org/GNOME/vala"
	"https://gitlab.xfce.org/xfce/xfce4-dev-tools"
)

shopt -s expand_aliases
alias tput=false
test -f /lib/gentoo/functions.sh && . /lib/gentoo/functions.sh || {
  # Stubs for non-Gentoo systems
  eerror() { echo "$@"; }
  ewarn() { echo "$@"; }
  einfo() { echo "$@"; }
  eindent() { :; }
  eoutdent() { :; }
}
unalias tput

cleanup()
{
  [[ ${#CLEAN_DIRS[@]} == 0 ]] && return
  einfo "Cleaning up ${#CLEAN_DIRS[@]} tmpdirs..."
  printf "%s\0" "${CLEAN_DIRS[@]}" | xargs -0 -I@ bash -c 'rm -f @/*.m4{,.gitcommit,.gitpath,.gitrepo} && rmdir @'
  CLEAN_DIRS=()
}

die()
{
  echo "$@" >&2
  cleanup
  exit 1
}

COMMANDS=( git grep mktemp realpath )

if command -v find_m4.sh >/dev/null ; then
  FINDM4=find_m4.sh
elif [[ -x "${BASH_SOURCE%/*}/find_m4.sh" ]]; then
  FINDM4="${BASH_SOURCE%/*}/find_m4.sh"
  FINDM4=$(realpath "${FINDM4}")
else
  die "Could not find find_m4.sh in PATH or '${BASH_SOURCE%/*}/'"
fi

for COMMAND in "${COMMANDS[@]}" ; do
  command -v "${COMMAND}" >/dev/null || die "'${COMMAND}' not found in PATH"
done

# If TMPDIR is set, force it to be an absolute path
[[ -n "${TMPDIR}" ]] && TMPDIR=$(realpath "${TMPDIR}")

KNOWN_REPOS_TOPDIR="${KNOWN_REPOS_TOPDIR%/}/"
[[ -d ${KNOWN_REPOS_TOPDIR} ]] || die "KNOWN_REPOS_TOPDIR directory '${KNOWN_REPOS_TOPDIR}' does not exist"
cd ${KNOWN_REPOS_TOPDIR} || die "chdir KNOWN_REPOS_TOPDIR directory '${KNOWN_REPOS_TOPDIR}' failed"

# Warn about cloning repos only the first time
warn_clone_abort=1

DIRS=()
for repo in "${GNU_REPOS[@]}" "${OTHER_REPOS[@]}" ; do

  # canonicalize repo name and path
  repo="${repo%/}"; repo="${repo%.git}"

  repo_topurl="${repo%/*}"
  if [[ -z $repo_topurl ]]; then
    repo_topurl="${GNU_REPOS_TOPURL}"
  else
    repo="${repo##*/}"
  fi
  repo_topurl="${repo_topurl%/}/"
  
  if [[ ! -d "${KNOWN_REPOS_TOPDIR}/${repo}" ]]; then
    [[ ${NO_NET} != "0" ]] && die "Repo '${repo}' not found under '${KNOWN_REPOS_TOPDIR}' but NO_NET='${NO_NET}'"
    einfo "Repo '${repo}' not found under '${KNOWN_REPOS_TOPDIR}', cloning"
    if [[ ${warn_clone_abort} == 1 ]]; then
      ewarn "Hit ^C within 5 seconds to abort"
      sleep 5
    fi
    warn_clone_abort=0
    git clone ${repo_topurl}${repo}.git/ || die "Clone '${repo_topurl}${repo}.git' failed"
  fi
  git -C ${repo} branch | grep -E -q '^\* (master|main)$' || die "Repo ${repo} exists but not in master/main branch"
  DIRS+=( "${KNOWN_REPOS_TOPDIR}${repo}" )
done

einfo "Checking for regular directories to be processed..."
for dir in "${DIRS[@]}" ; do
  [[ -d "${dir}"/.git ]] && continue
  einfo "Processing .m4 files under ${dir##*/}..."
  MODE=0 ${FINDM4} "${dir}" || exit 1
done

CLEAN_DIRS=()

trap 'die' SIGINT

einfo "Checking for git repos to be processed..."
# Now go further and check out every commit touching M4 serial numbers.
# TODO: Use \x00 delimiter
for dir in "${DIRS[@]}" ; do
  [[ -d "${dir}/.git" ]] || continue

  einfo "Processing all versions of all .m4 files in git repo ${dir##*/}..."

  batch_dirs=()

  # Make sure we have the latest, unless NO_NET was set
  [[ ${NO_NET} == "0" ]] && { git -C "${dir}" pull --tags || die "git pull failed"; }

  # TODO: Could this be parallelized, or does git do locking that
  # would defeat it?
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
    CLEAN_DIRS+=( "${temp}" )
    for file in "${files[@]}" ; do
      filename=${file##*/}
      echo "${dir}" > "${temp}"/${filename}.gitrepo
      echo "${commit}" > "${temp}"/${filename}.gitcommit
      echo "${file#${dir}}" > "${temp}"/${filename}.gitpath

      git -C "${dir}" cat-file -p "${commit}:${file}" > "${temp}"/${filename}
    done

    batch_dirs+=( "${temp}" )
  done < <(git -C "${dir}" log --diff-filter=ACMR --date-order --reverse --format='| %ad %H' --name-status --date=iso-strict -- '*.m4')

  MODE=0 ${FINDM4} "${batch_dirs[@]}" || die

  # remove all tempdirs created for this repo
  cleanup
done
