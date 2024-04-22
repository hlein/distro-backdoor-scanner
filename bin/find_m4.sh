#!/bin/bash
# TODO: Integrate with package_scan_all(?)
# TODO: Avoid adding duplicate entries?

die()
{
  echo "$@" >&2
  exit 1
}

COMMANDS=( cut find gawk git grep sha256sum sqlite3 )

KNOWN_M4_DBPATH="known_m4.db"
UNKNOWN_M4_DBPATH="unknown_m4.db"

# Various locations, commands, etc. differ by distro

OS_ID=$(sed -n -E 's/^ID="?([^ "]+)"? *$/\1/p' /etc/os-release 2>/dev/null)

case "${OS_ID}" in

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
    die "Unsupported OS '${OS_ID}'"
    ;;
esac

# Use the distro-specific unpack dir unless told otherwise
M4_DIR="${M4_DIR:-${UNPACK_DIR}}"

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

# unset DEBUG or 0: only display mismatches and other actionable items
# set DEBUG to non-0: very noisy
: "${DEBUG:=0}"

# Enabling DEBUG also enables VERBOSE by default
[[ -z ${DEBUG} || ${DEBUG} == "0" ]] || VERBOSE=1

debug()
{
  [[ -z ${DEBUG} || ${DEBUG} == "0" ]] && return
  # Deliberately treating this as a 'printf with debug check' function
  # shellcheck disable=2059
  printf "$@" >&2
}

# unset VERBOSE or 0: only print details at the end
# set VERBOSE to non-0: print any time a new or unmatched m4 is found,
# including git diff commands, etc.
: "${VERBOSE:=0}"

# Enable verbose flag for commands like rm
[[ -z ${VERBOSE} || ${VERBOSE} == "0" ]] || VERBOSE_FLAG=-v

verbose()
{
  [[ -z ${VERBOSE} || ${VERBOSE} == "0" ]] && return
  local cmd line
  cmd=$1
  shift

  eindent
  for line in "$@" ; do
    ${cmd} "${line}"
  done
  eoutdent
}

# Extract M4 serial number from an M4 macro.
extract_serial()
{
  local file=$1
  local serial serial_int
  local filename="${file##*/}"

  # https://www.gnu.org/software/automake/manual/html_node/Serials.html
  # We have to cope with:
  # - '#serial 1234 a.m4'
  # - '# serial 1234 b.m4'
  # TODO: pretty sure this can be optimized with sed(?) (less important now it uses gawk)
  # TODO: missed opportunity to diagnose multiple serial lines here, see https://lists.gnu.org/archive/html/bug-gnulib/2024-04/msg00266.html
  serial=$(gawk 'match($0, /^#(.* )?serial ([[:digit:]]+).*$/, a) {print a[2]; exit;}' "${file}")

  if [[ -z ${serial} ]] ; then
    # Some (old) macros may use an invalid format: 'x.m4 serial n'
    # https://lists.gnu.org/archive/html/bug-gnulib/2024-04/msg00051.html
    # TODO: pretty sure this can be optimized with sed
    # TODO: since that was fixed, there may be 2 valid checksums for each serial. How do we handle that
    # in the DB queries later on?
    serial=$(grep -m 1 -Pr "#(.+ )?(${filename} )?serial (\d+[^ ]*).*$" "${file}")
    serial="${serial#* }"
  fi

  # Fallbacks and warnings in case of no/bad serial number
  if [[ -z ${serial} ]] ; then
    serial="NULL"
    serial_int=0
    debug "[%s] No serial found, recording 'NULL' and for arithmetic ops using '0'\n" "${filename}"
  else
    serial_int="${serial//[!0-9]/}"
    [[ -z ${serial_int} ]] && serial_int=0
    [[ ${serial_int} != "${serial}" ]] && eerror "File '${file}': Non-numeric serial '${serial}', arithmetic ops will use '${serial_int}'"
  fi

  echo "${serial_int}" "${serial}"
}

# For a given file, get a comment-stripped checksum.
# If the file contained 'changecom', we give up, don't try to strip.
# https://www.gnu.org/software/m4/manual/html_node/Comments.html
# https://www.gnu.org/software/m4/manual/html_node/Changecom.html
# https://lists.gnu.org/archive/html/m4-discuss/2014-06/msg00000.html

make_stripped_checksum()
{
  local file="$1"
  local plain_checksum="$2"
  local strip_checksum

  # TODO: dnl can follow something other than whitespace, like
  # foo)dnl, bar]dnl. Broaden our match? We'd have to restore or
  # not consume such chars, unlike the whitespace we currently consume

  strip_checksum=$(gawk '/changecom/{exit 77}; { gsub(/#.*/,""); gsub(/(^| )dnl.*/,"");}; /^ *$/{next}; {print};' "${file}" 2>/dev/null \
	| sha256sum - \
	| cut -d' ' -f1 ; \
	exit ${PIPESTATUS[0]})
  local ret=$?
  if [[ ${ret} != 0 ]] ; then
    strip_checksum="${plain_checksum}"
    if [[ ${ret} != 77 ]]; then
      eerror "File '${file}': Got error ${ret} from gawk?"
    fi
  fi
  echo "${strip_checksum}"
}

# Initial creation of known M4 macros database.
# Creates a table called `m4` with fields:
# `name`
# `serial`
# `plain_checksum` (SHA256),
# `strip_checksum` (SHA256), (checksum of comment-stripped contents)
# `repository` (name of git repo)
# `commit` (git commit in `repository`)
create_known_db()
{
  sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF | grep -v '^wal$'
    PRAGMA journal_mode=WAL;
    CREATE table m4 (name TEXT, serial TEXT, plain_checksum TEXT, strip_checksum TEXT, repository TEXT, gitcommit TEXT, gitpath TEXT);
EOF
  [[ ${PIPESTATUS[0]} == 0 ]] || die "SQLite ${KNOWN_M4_DBPATH} DB creation failed"
}

# Initial creation of unknown M4 macros database.
# Creates a table called `m4` with fields:
# `name`
# `serial`
# `plain_checksum` (SHA256),
# `strip_checksum` (SHA256), (checksum of comment-stripped contents)
# `projectfile` (path under M4_DIR for this specific file, incl project dir)
# `reason` (what kind of check led to us adding it here)
create_unknown_db()
{
  sqlite3 "${UNKNOWN_M4_DBPATH}" <<-EOF | grep -v '^wal$'
    PRAGMA journal_mode=WAL;
    CREATE table m4 (name TEXT, serial TEXT, plain_checksum TEXT, strip_checksum TEXT, projectfile TEXT, reason TEXT);
EOF
  [[ ${PIPESTATUS[0]} == 0 ]] || die "SQLite ${UNKNOWN_M4_DBPATH} DB creation failed"
}

# Remember per-run unrecognized macros, so that we can then cross-ref
# across all analyzed projects, find common matching unknowns, etc.
record_unknown()
{
  local filename="$1"
  local serial="$2"
  local plain_checksum="$3"
  local strip_checksum="$4"
  local project_filepath="$5"
  local reason="$6"

  sqlite3 "${UNKNOWN_M4_DBPATH}" <<-EOF || die "SQLite insert into ${UNKNOWN_M4_DBPATH} failed"
    $(printf "PRAGMA synchronous = OFF;\nINSERT INTO \
      m4 (name, serial, plain_checksum, strip_checksum, projectfile, reason) \
      VALUES ('%s', '%s', '%s', '%s', '%s', '%s');\n" \
      "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${project_filepath:-NULL}" "${reason}"
    )
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
populate_known_db()
{
  local queries=()
  local serial serial_int
  local file filename
  local plain_checksum strip_checksum
  local processed=0

  for file in "${M4_FILES[@]}" ; do

    [[ $(( ${processed} % 1000 )) == 0 ]] && einfo "Processed ${processed} / ${#M4_FILES[@]} macro files"
    let processed=${processed}+1

    filename="${file##*/}"
    [[ ${filename} == @(aclocal.m4|acinclude.m4|m4sugar.m4) ]] && continue

    # TODO: reject pathological filenames? spaces, shell metacharacters, etc.

    dirname="${file%/*}"

    read -r serial_int serial <<< $(extract_serial "${file}")

    # TODO: we used to skip files w/no serial, should we again?
    # [[ ${serial} == NULL ]] && continue

    repository=$(git -C "${dirname}" rev-parse --show-toplevel 2>/dev/null || cat "${file}.gitrepo")
    commit=$(git -C "${dirname}" rev-parse HEAD 2>/dev/null || cat "${file}.gitcommit")
    path=$(cat "${file}".gitpath 2>/dev/null || echo "${file}")

    plain_checksum=$(sha256sum "${file}" | cut -d' ' -f 1)
    strip_checksum=$(make_stripped_checksum "${file}" "${plain_checksum}")

    queries+=(
      "$(printf "INSERT INTO \
        m4 (name, serial, plain_checksum, strip_checksum, repository, gitcommit, gitpath) \
        VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s');\n" \
        "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${repository:-NULL}" "${commit:-NULL}" "${path:-NULL}")"
    )

    debug "[%s] Got serial %s with checksum %s stripped %s\n" "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}"
  done

  sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF || die "SQLite batched insert into ${KNOWN_M4_DBPATH} failed"
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
  local max_serial_seen max_serial_seen_int serial serial_int
  local plain_checksum strip_checksum
  local delta absolute_delta
  local processed=0
  local known_filename known_filename_query

  declare -A valid_checksums=()
  declare -A known_filenames=()
  declare -A bad_checksums=()

  # Load up a list of all known checksums, for future reference
  known_checksum_query=$(sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF || die "SQLite lookup of known checksums failed"
      SELECT DISTINCT plain_checksum,strip_checksum FROM m4
EOF
  )
  for checksum in ${known_checksum_query} ; do
    IFS='|' read -ra known_checksum_query_parsed <<< "${checksum}"
    plain_checksum=${known_checksum_query_parsed[0]}
    strip_checksum=${known_checksum_query_parsed[1]}
    valid_checksums[${plain_checksum}]=1
    valid_checksums[${strip_checksum}]=1
  done

  # Load up a list of all observed filenames, for future reference
  known_filename_query=$(sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF || die "SQLite lookup of known names failed"
    SELECT DISTINCT name FROM m4
EOF
  )
  for known_filename in ${known_filename_query} ; do
    known_filenames[${known_filename}]=1
  done

  for file in "${M4_FILES[@]}" ; do

    [[ $(( ${processed} % 1000 )) == 0 ]] && einfo "Compared ${processed} / ${#M4_FILES[@]} macro files"
    let processed=${processed}+1

    filename="${file##*/}"
    [[ ${filename} == @(aclocal.m4|acinclude.m4|m4sugar.m4) ]] && continue

    # TODO: reject pathological filenames? spaces, shell metacharacters, etc.

    project_filepath=${file#"${M4_DIR}"}

    read -r serial_int serial <<< $(extract_serial "${file}")

    plain_checksum=$(sha256sum "${file}" | cut -d' ' -f 1)
    strip_checksum=$(make_stripped_checksum "${file}" "${plain_checksum}")

    debug "\n"
    debug "[%s] Got serial %s with checksum %s stripped %s\n" \
      "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}"
    debug "[%s] Checking database...\n" "${filename}"

    # Have we seen this checksum before (stripped or otherwise)?
    # If yes, it's only (mildly) interesting if it has a different name than we know it by.
    # If not, we need to see if it's a known serial number or not.
    local indexed_checksum=${valid_checksums[${plain_checksum}]} || ${valid_checksums[${strip_checksum}]} || 0

    if [[ ${indexed_checksum} == 1 ]] ; then
      # We know the checksum, we can move on.
      # TODO: Should we mention if only stripped matched, not raw?
      # TODO: Check if the filename and/or serial matched, make a note if they did not?
      let MATCH_COUNT=${MATCH_COUNT}+1
      continue
    fi

    #
    # If we get here, this checksum is not known-good.
    #

    if ! [[ ${known_filenames[${filename}]} ]] ; then
      # Have we seen this filename before during this scan, even though
      # it's not in our index?
      #
      # We've seen it before as an "unseen" macro, so not very interesting,
      # but remember we saw it in this project/path too.
      if [[ ${NEW_MACROS[${filename}]} ]] ; then
        record_unknown "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${project_filepath:-NULL}" "unknown-repeat"
        continue
      fi

      # We didn't see this filename before when indexing.
      NEW_MACROS[${filename}]=1

      ewarn "$(printf "Found new macro %s\n" "${file}")"

      debug "[%s] Got serial %s with checksum %s stripped %s\n" "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}"

      # This filename isn't in the index, so no point in carrying on.
      record_unknown "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${project_filepath:-NULL}" "new-filename"
      continue
    fi

    #
    # If we get here, the filename is known but the checksum is new.
    #

    # Is it a new checksum for an existing known serial?
    # Find the maximum serial number we've ever seen for this macro.
    # TODO: This could be optimized by preloading it into an assoc array
    # ... and save many repeated forks & queries (to avoid looking up same macro repeatedly)
    max_serial_seen_query=$(sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF || die "SQLite lookup of max serial for '${filename}' failed"
      SELECT MAX(CAST(serial AS INT)),name,serial,plain_checksum,strip_checksum,repository,gitcommit,gitpath FROM m4 WHERE name='${filename}';
EOF
    )

    # Check for discontinuities in serial number. Linear increase is OK,
    # like N+1 or so (likely just a genuinely new version), but something
    # like +20 is suspicious as they really want theirs to take priority...
    # TODO: Make this more intelligent?
    if [[ -n ${max_serial_seen_query} ]] ; then
      print_diff_cmd() {
        local cmd=$1

        IFS='|' read -ra parsed_results <<< "${max_serial_seen_query}"
        expected_repository=${parsed_results[5]}
        expected_gitcommit=${parsed_results[6]}
        expected_gitpath=${parsed_results[7]}
        verbose ${cmd} "diff using:"$'\n\t'"git diff --no-index <(git -C ${expected_repository} show '${expected_gitcommit}:${expected_gitpath}') '${file}'"

        DIFF_CMDS[${strip_checksum}]="git diff --no-index <(git -C ${expected_repository} show '${expected_gitcommit}:${expected_gitpath}') '${file}' # discontinuity"
        # We don't want to emit loads of diff commands for the same thing
        bad_checksums[${plain_checksum}]=1
        bad_checksums[${strip_checksum}]=1
      }

      # We don't want to emit loads of diff commands for the same thing
      if [[ ${bad_checksums[${plain_checksum}]} == 1 || ${bad_checksums[${strip_checksum}]} == 1 ]] ; then
        record_unknown "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${project_filepath:-NULL}" "known-bad-checksum"
        continue
      fi

      IFS='|' read -ra max_serial_seen_parsed <<< "${max_serial_seen_query}"
      max_serial_seen=${max_serial_seen_parsed[2]}
      # What even are numbers
      max_serial_seen_int="${max_serial_seen//[!0-9]/}"
      [[ -z ${max_serial_seen_int} ]] && max_serial_seen_int=0
      delta=$(( max_serial_seen_int - serial_int ))
      absolute_delta=$(( delta >= 0 ? delta : -delta ))

      # Call out large deltas at a higher priority
      if [[ ${delta} -lt -10 ]] ; then
        BAD_SERIAL_MACROS+=( "${filename}" )

        eerror "$(printf "Large serial delta found in %s!\n" "${filename}")"
        verbose eerror \
		      "$(printf "full path: %s" "${file}")" $'\n' \
		      "$(printf "serial=%s" "${serial}")" $'\n' \
		      "$(printf "max_serial_seen=%s" "${max_serial_seen}")" $'\n' \
		      "$(printf "delta=%s" "${absolute_delta}")" $'\n'
        print_diff_cmd eerror
      elif [[ ${delta} -lt 0 ]] ; then
        NEW_SERIAL_MACROS+=( "${filename}" )

        ewarn "$(printf "Newer macro serial found in %s\n" "${filename}")"
        verbose ewarn \
          "$(printf "serial=%s" "${serial}")" $'\n' \
		      "$(printf "max_serial_seen=%s" "${max_serial_seen}")" $'\n' \
		      "$(printf "absolute_delta=%s" "${absolute_delta}")" $'\n'
        print_diff_cmd ewarn
      fi
    fi

    # We know this filename, but not its checksum and maybe not serial number.
    # Look up all the checksums for this macro & serial.
    known_macro_query=$(sqlite3 "${KNOWN_M4_DBPATH}" <<-EOF || die "SQLite lookup of known records for '${filename}' failed"
      SELECT name,serial,plain_checksum,strip_checksum,repository,gitcommit,gitpath FROM m4 WHERE name='${filename}';
EOF
    )

    local line expected_serial checksum_ok
    for line in ${known_macro_query} ; do
      IFS='|' read -ra parsed_results <<< "${line}"
      expected_serial=${parsed_results[1]}
      expected_plain_checksum=${parsed_results[2]}
      expected_strip_checksum=${parsed_results[3]}
      expected_repository=${parsed_results[4]}
      expected_gitcommit=${parsed_results[5]}
      expected_gitpath=${parsed_results[6]}

      debug "[%s] Checking candidate w/ expected_serial=%s, expected_plain_checksum=%s, expected_strip_checksum=%s\n" \
        "${filename}" "${expected_serial}" "${expected_plain_checksum}" "${expected_strip_checksum}"

      # TODO: In the case of multiple knowns for this file w/different
      # serials & checksums, we are picking the first one with a serial
      # match. That doesn't necessarily mean the closest content match.
      # Add fuzzy hashes & find the candidate with the closest fuzzy hash?
      if [[ ${expected_serial} == "${serial}" ]] ; then
        # We know this serial, so we can assert what its checksum ought to be.
        if [[ ${expected_plain_checksum} == "${plain_checksum}" ]]; then
          checksum_ok=plain
        elif [[ ${expected_strip_checksum} == "${strip_checksum}" ]]; then
          checksum_ok=strip
        else
          checksum_ok=no
        fi

        debug "[%s] checksum_ok=%s\n" "${filename}" "${checksum_ok}"

        if [[ ${checksum_ok} == no ]] ; then
          BAD_MACROS+=( "${file}" )

          eerror "$(printf "Found mismatch in %s\n"  "${file}")"
          verbose eerror \
		        "$(printf "full path: %s" "${file}")" \
		        "$(printf "expected_serial=%s vs serial=%s" \
			        "${expected_serial}" "${serial}")" \
		        "$(printf "expected_plain_checksum=%s vs plain_checksum=%s" \
			        "${expected_plain_checksum}" "${plain_checksum}")" \
		        "$(printf "expected_strip_checksum=%s vs strip_checksum=%s" \
			        "${expected_strip_checksum}" "${strip_checksum}")" \
		        "diff using:"$'\n\t'"git diff --no-index <(git -C ${expected_repository} show '${expected_gitcommit}:${expected_gitpath}') '${file}'"

          DIFF_CMDS[${strip_checksum}]="git diff --no-index <(git -C ${expected_repository} show '${expected_gitcommit}:${expected_gitpath}') '${file}' # mismatch"

          # We don't want to emit loads of diff commands for the same thing
          bad_checksums[${plain_checksum}]=1
          bad_checksums[${strip_checksum}]=1

          # No point in checking this one against other checksums
          break
        fi
      fi
    done
    record_unknown "${filename}" "${serial}" "${plain_checksum}" "${strip_checksum}" "${project_filepath:-NULL}" "new-serial"
    debug "[%s] Got %s\n" "${filename}" "unknown"
  done
}

for COMMAND in "${COMMANDS[@]}" ; do
  command -v "${COMMAND}" >/dev/null || die "'${COMMAND}' not found in PATH"
done

# MODE=0: create database
# MODE=1: search against the db
: "${MODE:=0}"

declare -Ag NEW_MACROS=() DIFF_CMDS=()

M4_FILES=()
NEW_MACROS=()
NEW_SERIAL_MACROS=()
BAD_MACROS=()
BAD_SERIAL_MACROS=()
MATCH_COUNT=0

if [[ ${MODE} == 0 ]] ; then
  if [[ "$#" -le 3 ]] ; then
    label="$*"
  else
    label="$1 $2 ...[$#]"
  fi
  einfo "Running in create mode, scraping ${label}"

  if [[ -f "${KNOWN_M4_DBPATH}" ]] ; then
    debug "Using existing database...\n"
  else
    debug "Creating database...\n"
    create_known_db
  fi

  einfo "Finding macros to index..."
  find_macros "$@"

  einfo "Adding ${#M4_FILES[@]} macros to database..."
  populate_known_db
else
  einfo "Running in comparison mode..."
  [[ -f "${KNOWN_M4_DBPATH}" ]] || die "error: running in DB comparison mode but '${KNOWN_M4_DBPATH}' not found!"

  einfo "Purging old (if any) unknown db..."
  rm ${VERBOSE_FLAG} -f "${UNKNOWN_M4_DBPATH}"
  einfo "Creating new unknown db..."
  create_unknown_db

  # Which of these files are new?
  einfo "Finding macros in '${M4_DIR}' to compare..."
  find_macros "${M4_DIR}"

  einfo "Comparing ${#M4_FILES[@]} macros with database..."
  compare_with_db

  printf "\n"

  einfo "Scanning complete."

  einfo "Found ${MATCH_COUNT} matched m4, ${#NEW_MACROS[@]} new m4, ${#NEW_SERIAL_MACROS[@]} new serial, ${#BAD_MACROS[@]} differing m4, ${#BAD_SERIAL_MACROS[@]} serial jumps, ${#DIFF_CMDS[@]} diff commands."

  if (( ${#NEW_MACROS[@]} > 0 )) || (( ${#NEW_SERIAL_MACROS[@]} > 0 )) || (( ${#BAD_MACROS[@]} > 0 )) \
    || (( ${#BAD_SERIAL_MACROS[@]} > 0 )) || (( ${#DIFF_CMDS[@]} > 0 )) ; then

    # Sort our lists of new/modified/bad m4's

    (( ${#NEW_MACROS[@]} > 0 )) && \
		mapfile -d '' _sorted < <(printf '%s\0' "${!NEW_MACROS[@]}" | sort -z) && \
		ewarn "New macros: ${_sorted[@]}"

    (( ${#NEW_SERIAL_MACROS} > 0 )) && \
		mapfile -d '' _sorted < <(printf '%s\0' "${NEW_SERIAL_MACROS[@]}" | sort -z) && \
		ewarn "Updated macros: ${_sorted[@]}"

    (( ${#BAD_MACROS} > 0 )) && \
		mapfile -d '' _sorted < <(printf '%s\0' "${BAD_MACROS[@]}" | sort -z) && \
		eerror "Miscompared macros: ${_sorted[@]}"

    (( ${#BAD_SERIAL_MACROS} > 0 )) && \
		mapfile -d '' _sorted < <(printf '%s\0' "${BAD_SERIAL_MACROS[*]}" | sort -z) && \
		eerror "Significant serial diff. macros: ${_sorted[@]}"

    # DIFF_CMDS is already in a logical order (grouped by project)
    (( ${#DIFF_CMDS[@]} > 0 )) && {
      eerror "Collected diff cmds for review:" ;
      printf "%s\n" "${DIFF_CMDS[@]}" ;
    }
  fi
fi
