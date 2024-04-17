#!/bin/bash
# TODO: Integrate with package_scan_all and then add to Makefile
# TODO: Avoid adding duplicate entries?
# TODO: Should we add where we saw each macro too?
# TODO: Should we add fuzziness for copyright years, newlines (at EOF)?

die()
{
  echo "$@" >&2
  exit 1
}

# Various locations, commands, etc. differ by distro

OS_ID=$(sed -n -E 's/^ID="?([^ "]+)"? *$/\1/p' /etc/os-release 2>/dev/null)

case "$OS_ID" in

  "")
    die "Could not extract an ID= line from /etc/os-release"
    ;;

  debian|devuan|ubuntu)
    UNPACK_DIR="/var/packages/"
    ;;

  gentoo)
    UNPACK_DIR="${PORTAGE_TMPDIR:-/var/tmp/portage/}"
    # We want to get the 'real' PORTAGE_TMPDIR, as PORTAGE_TMPDIR has confusing
    # semantics (PORTAGE_TMPDIR=/var/tmp -> stuff goes into /var/tmp/portage).
    UNPACK_DIR="${UNPACK_DIR%%/portage/}/portage/"
    ;;

  centos|fedora|rhel|rocky)
    UNPACK_DIR="/var/repo/BUILD/"
    ;;

  *)
    die "Unsupported OS '$OS_ID'"
    ;;
esac

# Use the distro-specific unpack dir unless told otherwise
M4_DIR="${M4_DIR:-${UNPACK_DIR}}"

. /lib/gentoo/functions.sh || {
  # Stubs for non-Gentoo systems
  eerror() { echo "$@"; }
  ewarn() { echo "$@"; }
  einfo() { echo "$@"; }
  eindent() { :; }
  eoutdent() { :; }
}

debug()
{
  [[ -n ${DEBUG} ]] || return
  # Deliberately treating this as a 'printf with debug check' function
  # shellcheck disable=2059
  printf "$@"
}

# Extract M4 serial number from an M4 macro.
extract_serial()
{
  local file=$1
  local serial
  local filename="${file##*/}"

  # https://www.gnu.org/software/automake/manual/html_node/Serials.html
  # We have to cope with:
  # - '#serial 1234 a.m4'
  # - '# serial 1234 b.m4'
  # TODO: handle decimal (below too)
  # TODO: pretty sure this can be optimized with sed(?) (less important now it uses gawk)
  # TODO: can we optimise out the head -n1 and just do that natively with gawk?
  # TODO: missed opportunity to diagnose multiple serial lines here, see https://lists.gnu.org/archive/html/bug-gnulib/2024-04/msg00266.html
  serial=$(gawk 'match($0, /^#(.* )?serial ([[:digit:]]+).*$/, a) {print a[2]}' "${file}" | head -n1)

  if [[ -z ${serial} ]] ; then
    # Some (old) macros may use an invalid format: 'x.m4 serial n'
    # https://lists.gnu.org/archive/html/bug-gnulib/2024-04/msg00051.html
    # TODO: pretty sure this can be optimized with sed
    # TODO: since that was fixed, there may be 2 valid checksums for each serial. How do we handle that
    # in the DB queries later on?
    serial=$(grep -m 1 -Pr "#(.+ )?(${filename} )?serial (\d+).*$" "${file}")
    serial="${serial#* }"
  fi

  echo "${serial}"
}

# Initial creation of database.
# Creates a table called `m4` with fields `name`, `serial`, `checksum` (SHA256),
# `repository` (name of git repo), `commit` (git commit in `repository`).
create_db()
{
  sqlite3 m4.db <<-EOF || die "SQLite DB creation failed"
    CREATE table m4 (name TEXT, serial INTEGER, checksum TEXT, repository TEXT, gitcommit TEXT, gitpath TEXT);
EOF
}

# Search passed directories for M4 macros and populate `M4_FILES` with the result.
find_macros()
{
  # What .m4 files are there in the wild?
  # TODO: exclude list for aclocal.m4 and so on?
  mapfile -d '' M4_FILES < <(find "$@" -iname "*.m4" -type f -print0)
}

# Populate the DB with the contents of `M4_FILES`.
populate_db()
{
  local queries=()
  local serial checksum
  local file filename
  for file in "${M4_FILES[@]}" ; do
    filename="${file##*/}"
    [[ ${filename} == @(aclocal.m4|acinclude.m4|m4sugar.m4) ]] && continue

    serial=$(extract_serial "${file}")
    # XXX: What if it's a naughty .m4 file without a serial, as opposed to
    # e.g. SELinux's refpolicy/support/divert.m4?
    if [[ -z ${serial} ]] ; then
      continue
    fi

    repository=$(git -C "$(dirname "${file}")" rev-parse --show-toplevel 2>/dev/null || cat "${file}.gitrepo")
    commit=$(git -C "$(dirname "${file}")" rev-parse HEAD 2>/dev/null || cat "${file}.gitcommit")
    path=$(cat "${file}".gitpath 2>/dev/null || echo "${file}")

    checksum=$(sha256sum "${file}" | cut -d' ' -f 1)
    queries+=(
      "$(printf "INSERT INTO m4 (name, serial, checksum, repository, gitcommit, gitpath) VALUES ('%s', '%s', '%s', '%s', '%s', '%s');\n" \
        "${filename}" "${serial}" "${checksum}" "${repository:-NULL}" "${commit:-NULL}" "${path:-NULL}")"
    )

    debug "[%s] Got serial %s with checksum %s\n" "${filename}" "${serial}" "${checksum}"
  done

  sqlite3 m4.db <<-EOF || die "SQLite queries failed"
    PRAGMA synchronous = OFF;
    ${queries[@]}
EOF
}

# Compare `M4_FILES` found on disk with the contents of the database (known M4 serials/hashes).
compare_with_db()
{
  # We have `M4_FILES` as a bunch of macros pending verification that we found
  # unpacked in archives.
  local file filename
  local max_serial_seen serial
  local checksum query_result
  local delta absolute_delta
  for file in "${M4_FILES[@]}" ; do
    filename="${file##*/}"
    [[ ${filename} == @(aclocal.m4|acinclude.m4|m4sugar.m4) ]] && continue

    serial=$(extract_serial "${file}")
    # XXX: What if it's a naughty .m4 file without a serial, as opposed to
    # e.g. SELinux's refpolicy/support/divert.m4?
    if [[ -z ${serial} ]] ; then
      continue
    fi

    checksum=$(sha256sum "${file}" | cut -d' ' -f 1)

    debug "\n"
    debug "[%s] Got serial %s with checksum %s\n" "${filename}" "${serial}" "${checksum}"
    debug "[%s] Checking database...\n" "${filename}"

    # TODO: This could be optimized by preloading it into an assoc array
    # ... and save many repeated forks & even queries (to avoid looking up same macro repeatedly)
    query_result=$(sqlite3 m4.db <<-EOF || die "SQLite query failed"
      $(printf "SELECT name,serial,checksum,repository,gitcommit,gitpath FROM m4 WHERE name='%s' LIMIT 1" "${filename}")
EOF
    )

    # We've never seen the macro's name before, even.
    if [[ -z ${query_result} ]] ; then
      NEW_MACROS+=( "${filename}" )
      ewarn "$(printf "Found new macro %s\n" "${filename}")"
      continue
    fi

    # Find the maximum serial number we've ever seen for this macro.
    # TODO: This could be optimized by preloading it into an assoc array
    # ... and save many repeated forks & even queries (to avoid looking up same macro repeatedly)
    max_serial_seen=$(sqlite3 m4.db <<-EOF || die "SQlite query failed"
      SELECT MAX(serial) FROM m4 WHERE name='${filename}';
EOF
    )
    # Check for discontinuities in serial number. Linear increase is OK,
    # like N+1 or so (likely just a genuinely new version), but something
    # like +20 is suspicious as they really want theirs to take priority...
    # TODO: Make this more intelligent?
    if [[ -n ${max_serial_seen} ]] ; then
      delta=$(( max_serial_seen - serial ))
      absolute_delta=$(( delta >= 0 ? delta : -delta ))

      if [[ ${delta} -lt -10 ]] ; then
        BAD_SERIAL_MACROS+=( "${filename}" )

        eerror "$(printf "Large serial delta found in %s!\n" "${filename}")"
        eindent
        eerror "$(printf "full path: %s\n" "${file}")"
        eerror "$(printf "serial=%s\n" "${serial}")"
        eerror "$(printf "max_serial_seen=%s\n" "${max_serial_seen}")"
        eerror "$(printf "delta=%s\n" "${delta}")"
        eoutdent
      elif [[ ${delta} -lt 0 ]] ; then
        NEW_SERIAL_MACROS+=( "${filename}" )

        ewarn "$(printf "Newer macro serial found in %s\n" "${filename}")"
        eindent
        ewarn "$(printf "serial=%s\n" "${serial}")"
        ewarn "$(printf "max_serial_seen=%s\n" "${max_serial_seen}")"
        ewarn "$(printf "absolute_delta=%s\n" "${absolute_delta}")"
        eoutdent
      fi
    fi

    # We know this macro, but we may not recognize its checksum
    # or indeed serial number.
    local line expected_serial expected_checksum
    for line in "${query_result[@]}" ; do
      expected_serial=$(echo "${line}" | awk -F'|' '{print $2}')
      expected_checksum=$(echo "${line}" | awk -F'|' '{print $3}')
      expected_repository=$(echo "${line}" | awk -F'|' '{print $4}')
      expected_gitcommit=$(echo "${line}" | awk -F'|' '{print $5}')
      expected_gitpath=$(echo "${line}" | awk -F'|' '{print $6}')

      debug "[%s] Checking candidate w/ expected_serial=%s, expected_checksum=%s\n" \
        "${filename}" "${expected_serial}" "${expected_checksum}"

      if [[ ${expected_serial} == "${serial}" ]] ; then
        # We know this serial, so we can assert what its checksum ought to be.
        if [[ ${expected_checksum} != "${checksum}" ]] ; then
          BAD_MACROS+=( "${file}" )

          # If we have /path/to/cache-a/foo/bar.baz /zoo/wee/cache-b/foo/bar.baz,
          # we want to extract foo/baz.baz.
          common_stem=$(printf "%s\n%s\n" "${expected_gitpath}" "${file}" | rev | sed -e 'N;s/^\(.*\).*\n\1.*$/\1/' | rev)
          common_stem=${common_stem#/}
          # Sometimes, we might have completely disjoint paths apart from the filename.
          # In that case, take the repo path and just append the path to it relative to the repo.
          if [[ ${common_stem} == "${filename}" ]] ; then
            common_stem=${expected_gitpath##"${expected_repository}"}
            common_stem=${common_stem#/}
          fi

          eerror "$(printf "Found mismatch in %s!\n"  "${filename}")"
          eindent
          eerror "$(printf "full path: %s\n" "${file}")"
          eerror "$(printf "expected_serial=%s vs serial=%s\n" \
            "${expected_serial}" "${serial}")"
          eerror "$(printf "expected_checksum=%s vs checksum=%s\n" \
            "${expected_checksum}" "${checksum}")"

          ewarn "diff using: git diff --no-index <(git -C "${expected_repository}" show "${expected_gitcommit}":${common_stem}) "${file}""
          eoutdent
        fi
      fi
    done

    debug "[%s] Got %s\n" "${filename}" "${query_result}"
  done
}

COMMANDS=( sha256sum sqlite3 grep awk cut find )

for COMMAND in "${COMMANDS[@]}" ; do
  command -v "${COMMAND}" >/dev/null || die "'${COMMAND}' not found in PATH"
done

# MODE=0: create database
# MODE=1: search against the db
: "${MODE:=0}"

# unset DEBUG: only display mismatches and other actionable items
# set DEBUG: very noisy
#DEBUG=1

M4_FILES=()
NEW_MACROS=()
NEW_SERIAL_MACROS=()
BAD_MACROS=()
BAD_SERIAL_MACROS=()

if [[ ${MODE} == 0 ]] ; then
  if [ "$#" -le 3 ]; then
    label="$*"
  else
    label="$1 $2 ...[$#]"
  fi
  einfo "Running in create mode, scraping $label"

  if [[ -f m4.db ]] ; then
    debug "Using existing database...\n"
  else
    debug "Creating database...\n"
    create_db
  fi

  debug "Finding macros to index...\n"
  find_macros "$@"

  debug "Adding macros to database...\n"
  populate_db
else
  einfo "Running in comparison mode..."
  [[ -f m4.db ]] || die "error: running in DB comparison mode but m4.db not found!"

  # Which of these files are new?
  einfo "Finding macros in '${M4_DIR}' to compare..."
  find_macros "$M4_DIR"

  einfo "Comparing macros with database..."
  compare_with_db

  printf "\n"
  if (( ${#NEW_MACROS} > 0 )) || (( ${#NEW_SERIAL_MACROS} > 0 )) || (( ${#BAD_MACROS} > 0 )) \
    || (( ${#BAD_SERIAL_MACROS} > 0 )) ; then
    einfo "Scanning complete. Summary below."

    (( ${#NEW_MACROS} > 0 )) && ewarn "New macros: ${NEW_MACROS[*]}"
    (( ${#NEW_SERIAL_MACROS} > 0 )) && ewarn "Updated macros: ${NEW_SERIAL_MACROS[*]}"

    (( ${#BAD_MACROS} > 0 )) && eerror "Miscompared macros: ${BAD_MACROS[*]}"
    (( ${#BAD_SERIAL_MACROS} > 0 )) && eerror "Significant serial diff. macros: ${BAD_SERIAL_MACROS[*]}"
  fi
fi
