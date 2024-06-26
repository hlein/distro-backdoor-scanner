#!/bin/bash
#
# Unpack the latest valid version of every package

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

UNPACK_LOG=~/parallel_unpack.log
PKG_LIST=~/package_list
COMMANDS="df parallel "
DOWNLOAD_ONLY=0
# Only used on rpm-based distros, but keep this up here
# for visibility since it's a tunable knob.
RPM_LIST=~/rpm_list
FETCH_TIMEOUT=1800

# set VERBOSE to non-0: print more individual status messages
: "${VERBOSE:=0}"

test -f /etc/os-release || die "Required /etc/os-release not found"

verbose()
{
  [[ -z ${VERBOSE} || ${VERBOSE} == "0" ]] && return
  local line

  for line in "$@" ; do
    warn "${line}"
  done
}
export -f verbose

dfcheck()
{
  local filesystem pct
  for filesystem in "$@" ; do
    pct=$(df "${filesystem}" | awk -F'[ %]+' '/[0-9]%/{print $5}')
    echo "${pct}" | grep -q -E '^[0-9]+$' || die "Unable to get '${filesystem}' full %, unsafe to continue"
    test "${pct}" -lt 90 || die "${filesystem} filesystem at ${pct}% full, refusing to continue"
  done
}
export -f dfcheck

# On most OSs, this is a noop
pre_parallel_hook()
{
  :
}

# Various locations, commands, etc. differ by distro

OS_ID=$(sed -n -E 's/^ID="?([^ "]+)"? *$/\1/p' /etc/os-release 2>/dev/null)

case "${OS_ID}" in

  "")
    die "Could not extract an ID= line from /etc/os-release"
    ;;

  arch|endeavouros)
    COMMANDS+="antlr4 cargo cmake curl electron28 expac filterdiff gen-setup gendesk gnome-autogen.sh go gtkdocize intltoolize makepkg mate-autogen meson mlyacc npm opam pacman pipenv_to_requirements rustc setconf signify svn timeout uusi yarn yelp-build"
    # pacman -S $(pacman -Fq ... | sort -u | egrep -v '^extra/(nodejs-|go)')
    # Consistantly 404's for me:
    #COMMANDS+=" composer "

    PACKAGE_DIR="${HOME}/pkgs/distfiles/"
    PKGBUILD_DIR="${HOME}/pkgs/pkgbuild/"
    UNPACK_DIR="${HOME}/pkgs/sources/"
    LOG_DIR="${HOME}/pkgs/logs/"

    JOBS=$(sed -E -n 's/^MAKEFLAGS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/makepkg.conf 2>/dev/null)
    [[ -z $JOBS ]] && JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)

    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)

    # makepkg will refuse to run as root
    [[ $EUID == "0" ]] && die "Must be run as non-root"

    # ...and yet root must have synced before we start
    [[ $(ls /var/lib/pacman/sync/*.db 2>/dev/null | wc -l) -gt 0 ]] || \
	die "No .db files under /var/lib/pacman/sync/! Run pacman -Sy as root once first."

    # make our own config that tunes some settings
    if [[ ! -f ${HOME}/.package_unpack.conf ]]; then
      sed 's/curl -q/curl -s -S -/' /etc/makepkg.conf >${HOME}/.package_unpack.conf
      cat >>${HOME}/.package_unpack.conf <<EOF
GITFLAGS='--mirror --quiet'
SRCDEST='.'
LOGDEST='${LOG_DIR}'
EOF
    fi

    mkdir -p "${PACKAGE_DIR}" "${PKGBUILD_DIR}" "${UNPACK_DIR}" "${LOG_DIR}" || \
	die "Could not make needed directories."

    make_pkg_list()
    {
      # List all available packages (translated to real pkgbase)
      pacman -Sl | expac -S '%r|%e|%v' - | sort -u
    }

    import_keys()
    {
      [[ -f PKGBUILD ]] || return 0
      # XXX: This will catch only the first key of a multiline validpgpkeys=(... definition
      KEYS=$(grep -h validpgpkeys PKGBUILD .SRCINFO 2>/dev/null | grep -E -o '[A-Fa-f0-9]{40}' | sort -u)
      [[ -z $KEYS ]] && return 0
      gpg -q --recv-keys ${KEYS}
    }
    export -f import_keys

    # gitlab mangles package names (repository.git names) differently from versions
    # core|archlinux-keyring|20240313-1 - no mangling
    # extra|libsigc++-3.0|3.6.0-1 - name gets s/++/plusplus/
    # extra|nicotine+|3.3.2-1 - name gets s/+$/plus/
    # extra|dvd+rw-tools|7.1-9 - name gets s/+/-/g
    # core|grub|2:2.12-2 - ver gets s/:/-/g
    # extra|adobe-source-code-pro-fonts|2.042u+1.062i+1.026vf-1 - ver + left alone

    gitlab_pkg_mangle()
    {
      local pkg="$1"
      pkg="${pkg//++/plusplus}"
      pkg="${pkg/%+/plus}"
      pkg="${pkg//+/-}"
      pkg="${pkg//:/-}"
      echo "${pkg}"
    }
    export -f gitlab_pkg_mangle

    gitlab_ver_mangle()
    {
      local ver="$1"
      ver="${ver//:/-}"
      echo "${ver}"
    }
    export -f gitlab_ver_mangle

    make_pkg_cmd()
    {
      local repo_pkg_ver pkg_mangle pkg_unpack_dir ver_mangle repo_pkg_ver_mangle tarball
      IFS='|' read -r repo pkg ver <<< "${PKG}"
      repo_pkg="${repo}/${pkg}"
      repo_pkg_ver="${repo_pkg}-${ver}"
      repo_pkg_ver_mangle="${repo}/$(gitlab_pkg_mangle "${pkg}")-$(gitlab_ver_mangle "${ver}")"


      if [[ ${repo} == "endeavouros" ]]; then
        # EndeavourOS packages' PKGBUILD files will already be present
        tarball=
        pkg_unpack_dir="${UNPACK_DIR}${repo_pkg}"
        pkg_build_dir="${PKGBUILD_DIR}${repo}/${pkg}"

        # Some EndeavourOS packages can't be resolved, skip silently
        # https://github.com/endeavouros-team/PKGBUILDS/issues/335
        [[ -d "${pkg_build_dir}" ]] || return
      else
        tarball="${repo_pkg_ver}.tar.bz2"
        pkg_unpack_dir="${UNPACK_DIR}${repo_pkg_ver_mangle}"
        pkg_build_dir="${PKGBUILD_DIR}${repo_pkg_ver_mangle}"
      fi
      [[ -d "${pkg_unpack_dir}" ]] && return

      # Wrap unpacking in timeout(1) so that we do not wait forever
      # for pathological downloads / git clones, see:
      # https://bugs.gentoo.org/930633

      echo "echo '###   unpack ${COUNT}/${TOT} ${tarball}' && \
		dfcheck "${PACKAGE_DIR}" "${UNPACK_DIR}" "${PKGBUILD_DIR}" && \
		mkdir -p '${PKGBUILD_DIR}${repo}/' '${pkg_unpack_dir}/' && \
		[[ -z '${tarball}' ]] || \
			tar -C '${PKGBUILD_DIR}${repo}/' -xf '${PACKAGE_DIR}${tarball}' && \
		cd '${pkg_build_dir}' && \
		import_keys && \
		BUILDDIR='${pkg_unpack_dir}' MAKEPKG_CONF='${HOME}/.package_unpack.conf' timeout -v --preserve-status ${FETCH_TIMEOUT} makepkg --nodeps --nobuild --noconfirm --noprogressbar || \
		die '###   unpack failed ${COUNT}/${TOT} ${repo_pkg_ver} ${tarball}'"
    }

    # We need to fetch individual pkgbuild repos from Arch before
    # we can start actually fetching package sources + unpacking.
    # Cloning >10k repos from gitlab will kill them and they us,
    # so just grab versioned tarballs, and don't parallelize.
    pre_parallel_hook()
    {
      local outfile
      local pkgbuild_count

      # Progress bar... note we exclude endeavouros which we are
      # skipping down in the loop.
      pkgbuild_count=$(grep -E -v '^endeavouros\|' "${PKG_LIST}" | wc -l)
      echo "### Fetching ${pkgbuild_count} pkgbuild repo tarballs"
      local fetched=0

      while IFS='|' read -r repo pkg ver ; do

        # All EnOS packages live in their own single repo; handle separately.
        # XXX: Are there other Arch family distros that do similar?
        [[ $repo == "endeavouros" ]] && continue

        [[ $(( ${fetched} % 1000 )) == 0 ]] && echo "###  Fetched ${fetched} / ${pkgbuild_count}"
        let fetched=${fetched}+1

        outfile="${repo}/${pkg}-${ver}.tar.bz2"
        [[ -f "${PACKAGE_DIR}${outfile}" ]] && continue

        dfcheck "${PACKAGE_DIR}" "${PKGBUILD_DIR}" "${UNPACK_DIR}" || exit 1
        mkdir -p "${PACKAGE_DIR}${repo}/"
        pkg_mangle="$(gitlab_pkg_mangle "${pkg}")"
        ver_mangle="$(gitlab_ver_mangle "${ver}")"
        path_mangle="/archlinux/packaging/packages/${pkg_mangle}/-/archive/${ver_mangle}/${pkg_mangle}-${ver_mangle}.tar.bz2"

        verbose "###    Fetching 'https://gitlab.archlinux.org${path_mangle}' -> '${PACKAGE_DIR}${outfile}'"

        curl -s -S --max-time ${FETCH_TIMEOUT} -o "${PACKAGE_DIR}${outfile}" \
		"https://gitlab.archlinux.org${path_mangle}" || \
		warn "###    Error on ${pkg}-${ver}"
        # Increase if we hit rate limits
        sleep 1
      done <"${PKG_LIST}"

      # If there are any EnOS packages listed, get/update that repo
      if grep -q -l '^endeavouros\|' "${PKG_LIST}" ; then
        mkdir -p "${PKGBUILD_DIR}/endeavouros"
        if [[ ! -d "${PKGBUILD_DIR}/endeavouros/.git" ]]; then
          git -C "${PKGBUILD_DIR}" clone --quiet https://github.com/endeavouros-team/PKGBUILDS endeavouros
        else
          git -C "${PKGBUILD_DIR}/endeavouros" pull --quiet
        fi
      fi

      # Do not be fooled later by existing empty directories
      rmdir "${UNPACK_DIR}"/*/* 2>/dev/null
    }

    ;;

  debian|devuan|ubuntu)
    COMMANDS+="apt-cache apt-get"
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    PACKAGE_DIR=/var/packages/
    UNPACK_DIR="${PACKAGE_DIR}"

    DEB_SRC=$(grep -r '^deb-src' /etc/apt/sources.list* 2>/dev/null | wc -l)
    if [ "${DEB_SRC}" = "0" ]; then
      die 'No deb-src entries found in /etc/apt/sources.list*'
    fi

    if [ "${DOWNLOAD_ONLY}" = "1" ]; then
      DOWNLOAD_FLAG=--download-only
    fi

    make_pkg_list()
    {
      # List all available packages
      apt-cache search . | cut -d\  -f1
    }

    make_pkg_cmd()
    {
      echo "echo '###   unpack ${COUNT}/${TOT} ${PKG}' && \
		dfcheck "${PACKAGE_DIR}" "${UNPACK_DIR}" && \
		apt-get source ${DOWNLOAD_FLAG} '${PKG}'"
    }
    ;;

  gentoo)
    COMMANDS+="ebuild portageq"
    JOBS=$(sed -E -n 's/^MAKEOPTS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/portage/make.conf 2>/dev/null)
    [[ -z $JOBS ]] && JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)

    for D in $(portageq get_repo_path "${EROOT:-/}" gentoo) /usr/portage/ /var/db/repos/gentoo/ ; do
      test -d "${D}" && PACKAGE_DIR="${D}" && break
    done
    test -n "${PACKAGE_DIR}" || die "Could not find package dir"
    UNPACK_DIR="${PORTAGE_TMPDIR:-/var/tmp/portage/}"

    if [ "${DOWNLOAD_ONLY}" = "1" ]; then
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

    make_pkg_cmd()
    {
      # Skip packages that come from overlays instead of ::gentoo
      if ! test -d "${PACKAGE_DIR}/$(qatom -C -F '%{CATEGORY}/%{PN}' "${PKG}")" ; then
        return
      fi
      EBUILD="$(qatom -C -F '%{CATEGORY}/%{PN}/%{PF}' "${PKG}").ebuild"
      echo "echo '###   unpack ${COUNT}/${TOT} ${EBUILD}' \
		dfcheck "${PACKAGE_DIR}" "${UNPACK_DIR}" && \
		&& ebuild $(echo \"${EBUILD}\") ${EBUILD_CMD}"
    }
    ;;

  # XXX: only actually tested on Rocky Linux yet
  centos|fedora|rhel|rocky)
    # %prep stage can require various development tools; best to do:
    # dnf groupinstall "Development Tools"
    # dnf install javapackages-tools jq
    COMMANDS+="build-jar-repository cpio gcc git reposync rpm2cpio rpmbuild tar"
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    PACKAGE_DIR="/var/repo/dist/"
    UNPACK_DIR="/var/repo/"
    ENABLE_REPO='*-source'

    make_pkg_list()
    {
      dnf list --disablerepo='*' --enablerepo="${ENABLE_REPO}" --available | \
          awk '/^(Last metadata|(Available) Packages)/{next}; /\.src/{print $1}'
    }

    make_pkg_cmd()
    {
      # Extract the package name from the path+RPM name
      PNAME=$(rpm --queryformat "%{NAME}" -qp "${PKG}")
      # We could/should rpm2cpio ... | cpio -i..., but then unpacking
      # the .tar files inside would be our job, reading from .spec.
      # For now just skip the intermediate step. Run the %prep stage
      # which unpacks tars, applies patches, conditionally other things.
      echo "echo '###   unpack ${COUNT}/${TOT} ${PNAME}' && \
		dfcheck "${PACKAGE_DIR}" "${UNPACK_DIR}" && \
		mkdir -p ${UNPACK_DIR}SOURCES/ && \
		rpmbuild --define '_topdir ${UNPACK_DIR}' --quiet -rp '${PKG}'"
    }

    # We cannot really combine fetch+unpack, and reposync(1) is not
    # multiprocess (and if it was we'd need to worry about beating up
    # the mirrors we talked to, anyway). So, call it once before entering
    # the parallel unpacks. Unfortunately because it is a oneshot we can't
    # monitor df between fetches.
    pre_parallel_hook()
    {
      # First, fetch every available distfile
      reposync --disablerepo='*' --enablerepo="${ENABLE_REPO}" --source || \
          warn "reposync errored, attempting to continue"
      # Second, build a list of RPMs and use that instead of ${PKG_LIST}.
      # Ignore the bird, follow the river.
      find ${PACKAGE_DIR}${ENABLE_REPO}/Packages/ -type f -name \*.src.rpm >"${RPM_LIST}" || \
           die "find RPMs failed"
      PKG_LIST="${RPM_LIST}"
      # Prepare the target directory structure, just once.
      mkdir -p ${UNPACK_DIR}{BUILD,BUILDROOT,RPMS,SOURCES,SRPMS}
    }
    ;;

  *)
    die "Unsupported OS '${OS_ID}'"
    ;;
esac

export -f make_pkg_list
export -f make_pkg_cmd
export -f pre_parallel_hook

# Mirrors will hate you fetching too many in parallel
test "${DOWNLOAD_ONLY}" = "1" && test "${JOBS}" -gt 4 && JOBS=4

for COMMAND in ${COMMANDS} ; do
  command -v ${COMMAND} >/dev/null || die "${COMMAND} not found in PATH"
done

# On some OSs, these are the same
test -d "${UNPACK_DIR}" || die "Unpack target ${UNPACK_DIR} does not exist"
cd "${PACKAGE_DIR}" || die "Could not cd ${PACKAGE_DIR}"

if ! test -s "${PKG_LIST}" ; then
  echo "### Generating package list"
  make_pkg_list >"${PKG_LIST}"
fi

pre_parallel_hook

COUNT=0
TOT=$(wc -l "${PKG_LIST}")
echo "### Processing ${TOT} packages in ${JOBS} parallel fetch+unpack jobs"
while IFS= read -r PKG ; do
  make_pkg_cmd
  let COUNT=${COUNT}+1
done <"${PKG_LIST}" | parallel -j${JOBS} --joblog +${UNPACK_LOG}

