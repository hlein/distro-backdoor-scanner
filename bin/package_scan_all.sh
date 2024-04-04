#!/bin/bash
#
# Process batches of package dirs in parallel;
# process files under each set of dirs serially.

die()
{
  echo "$@" >&2
  exit 1
}

SCAN_LOG=~/parallel_scan.log
PKG_LIST=~/package_list
COMMANDS="parallel perl xargs"
BATCH_SIZE=50
BATCH_NUM=0

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
    UNPACK_DIR="/var/packages/"

    make_dir_list()
    {
      # Debian package source trees are simply packagename/
      mapfile -d '' DIRS < <(find "${UNPACK_DIR}" -maxdepth 1 -type d -print0)
      # Scan a single package (XXX: hardcoded; should be an arg or env var)
      ##mapfile -d '' DIRS < <(find "${UNPACK_DIR}"xz-utils-5.6.0 -maxdepth 0 -type d -print0)
    }
    ;;

  gentoo)
    JOBS=$(sed -E -n 's/^MAKEOPTS="[^"#]*-j ?([0-9]+).*/\1/p' /etc/portage/make.conf 2>/dev/null)
    UNPACK_DIR="${PORTAGE_TMPDIR:-/var/tmp/portage/}"
    # We want to get the 'real' PORTAGE_TMPDIR, as PORTAGE_TMPDIR has confusing
    # semantics (PORTAGE_TMPDIR=/var/tmp -> stuff goes into /var/tmp/portage).
    UNPACK_DIR="${UNPACK_DIR%%/portage/}/portage/"

    make_dir_list()
    {
      # Gentoo package source trees have the form category/packagename-ver/work/*
      mapfile -d '' DIRS < <(find "${UNPACK_DIR}" -mindepth 3 -maxdepth 3 -type d -name work -print0)
      # Scan a single package (XXX: hardcoded; should be an arg or env var)
      ##mapfile -d '' DIRS < <(find "${UNPACK_DIR}"app-arch/xz-utils-5.6.1 -mindepth 1 -maxdepth 1 -type d -name work -print0)
    }
    ;;

  # XXX: only actually tested on Rocky Linux yet
  centos|fedora|rhel|rocky)
    # XXX: is there an equivalent of MAKE_OPTS that sets a -j factor?
    JOBS=$(grep -E '^processor.*: [0-9]+$' /proc/cpuinfo | wc -l)
    UNPACK_DIR="/var/repo/BUILD/"

    make_dir_list()
    {
      # Unpacked RPMs have a particular fan-out structure per repo
      mapfile -d '' DIRS < <(find "${UNPACK_DIR}" -maxdepth 1 -type d -print0)
      # Scan a single package (XXX: hardcoded; should be an arg or env var)
      ##mapfile -d '' DIRS < <(find "${UNPACK_DIR}/xz-5.6.1" -maxdepth 0 -type d -print0)
    }
    ;;

  *)
    die "Unsupported OS '$OS_ID'"
    ;;
esac

for COMMAND in $COMMANDS ; do
  command -v ${COMMAND} >/dev/null || die "'${COMMAND}' not found in PATH"
done

test -d "$UNPACK_DIR" || die "Unpack target '$UNPACK_DIR' does not exist"

cd "$UNPACK_DIR" || die "Could not cd '$UNPACK_DIR'"

# Depends on $PKG_LIST generated previously by package_unpack_all.sh
test -f "$PKG_LIST" || die "package list '$PKG_LIST' does not exist"
test -s "$PKG_LIST" || die "package list '$PKG_LIST' is empty"

# Function that parallel will kick off to do the work on batches of dirs
do_dirs()
{
  export GRANDPARENT=$$
  # XXX: Can inject a -name argument for testing; should be an arg or env var
  NAMEARG=''
  ##NAMEARG='-name CMakeLists.txt'
  find "$@" -type f $NAMEARG -print0 | xargs -0 perl -ne '
  # Note: perl -n mode eats trailing spaces in filenames;
  # trying to escape by rewriting ARGV in BEGIN does not work,
  # so we expect handfuls of failures opening perfectly good paths.
  BEGIN { $files_done=0; };
  if
   (
    # Patterns based loosely on indicators in known-trojaned xz-utils -
    # changes made to an .m4 file, strings from some binary files and
    # from fragments assembled at build time.
    # Add enough fuzz to catch slight variations, perhaps previous
    # generations, but not so much as to false positive much.
    m{
    # Strings in build-to-host.m4 in the release tarballs (not in git repo)
    # https://gist.github.com/thesamesam/223949d5a074ebc3dce9ee78baad9e27
      \#\s* build-to-host\.m4\s+ serial\s+ ([4-9]|3[0-9])
    | \|\s* eval\s+ \$gl_path
    | \[\s* eval\s+ \$gl_config .* \|\s* \$SHELL
    | dnl\s+ If\s+ the\s+ host\s+ conversion\s+ code\s+ has\s+ been\s+ placed\s+ in
    | dnl\s+ Search\s+ for\s+ Automake-defined\s+ pkg\*\s+ macros
    | map='\''tr\s+ "\\t\s+ \\-_"\s+ "\s+ \\t_\\-"'\''
    | HAVE_PKG_CONFIGMAKE=1
    # In build-to-host.m4 and in v5.6.1 stage2 extension loader
    # https://gynvael.coldwind.pl/?lang=en&id=782#stage2-ext
    | grep\s+ - (?: aErls | broaF )
    # Seen in stage1 loader
    # https://gynvael.coldwind.pl/?lang=en&id=782
    | head\s+ -c.*head\s+ -c.*head\s+ -c
    | \# \{ [3-5] \} \[\[:alnum:\]\] \{ [3-6] \} \#\{ [3-5] \} \$
    | eval\s+ \$[a-z]+\s* \|\s* tail\s+ -c
    | \#{2}s* [Hh]ello\s* \#{2}
    | \#{2}s* [Ww]orld\s* \#{2}
    # Stage1 substitution cipher implemented in tr
    # (generalized so other "keys" can match)
    | tr\s+ " (?: \\ [0-9]{1,3} - \\ [0-9]{1,3} ){3}
    # identifier bytes in different versions of stage1
    # https://gynvael.coldwind.pl/?lang=en&id=782
    | \x86 \xf9 \x5a \xf7 \x2e \x68 \x6a \xbc
    | \xe5 \x55 \x89 \xb7 \x24 \x04 \xd8 \x17
    # stage2 loader with some fuzz tolerances added
    # https://gynvael.coldwind.pl/?lang=en&id=782#stage2-backdoor
    | BEGIN\{FS="\\n";RS="\\n";ORS="";m=256;for\( ([a-z]) =0; $1 <m;
      $1 \+\+\)\{ [a-z] \[sprintf\("x%c", $1 \)\]= $1 ; [a-z]\[ $1
      \]=\(\( $1 \* [0-9] \)\+ [0-9] \)%m;\}
    # Kill switch env var key=val
    # https://piaille.fr/@zeno/112185928685603910
    | yolAbejyiejuvnup
    | Evjtgvsh5okmkAvj
    # Identifiers used by stage2 to find extensions/stage3
    | (?: ~!:_\sW | \|_!\{\s- | jV!\.\^% | %\.R\.1Z )
    # I have no memory of this place
    | if\s+ !\s+ echo\s+ "\$LDFLAGS"\s* |\s* grep\s+ [-a-z\s]+\s+ "-z(\s+ -Wl)?,now"\s+ .*\s* >\s* /dev/null
    | if\s+ (!\s+ )?test\s+ -[a-z]\s+ "[^\s"]+ /tests/files/\$[^\s"]+ "\s* >\s*/dev/null
    | sed\s+ -i\s+ "/\$./i\$."\s+ src/[^\s]+/Makefile\s* \|\|\s* true
    }x
   or
    (
     # One suspicious commit short-circuited cmake logic by entering a "."
     # in a line by itself in a CMakeLists.txt file; do we see that elsewhere?
     # https://git.tukaani.org/?p=xz.git;a=commit;h=328c52da8a2bbb81307644efdb58db2c422d9ba7
     $ARGV =~ /CMakeLists.txt$/ and
     m{
      ^ \. \s* $
     }x
    )
   or
    (
     # A key=value pair has been found to be an "off switch" env var; look
     # for others that match the observed pattern but are otherwise rare.
     /(?:^|['\''"\x0\s])([A-Za-z0-9]{12,18})=([A-Za-z0-9]{12,18})(?:$|['\''"\x0\s])/ &&
         length($1) eq length($2) &&
	 lc($1) ne lc($2) &&
	 $1 !~ /$3/ &&
	 $2 !~ /$1/ &&
	 $1 !~ /^(?:[A-Z]+|[A-Z]?[a-z]+|[0-9]+)$/ &&
	 $2 !~ /^(?:[A-Z]+|[A-Z]?[a-z]+|[0-9]+)$/ &&
	 $1 !~ /^(?:0x)?[A-Fa-f0-9]+$/ &&
	 $2 !~ /^(?:0x)?[A-Fa-f0-9]+$/
    )
   )
  {
    chomp;
    s/^[^!-~ ]+//;
    s/[^!-~ ]+$//;
    # Armor any non-ascii
    s/([^!-~ ])/sprintf("\\x%02s",unpack("C",$1))/eg;
    print "$ARGV $. $_\n";
  };
  # At the end of each file, reset $. and count the file as done
  close ARGV if (eof and ++$files_done);
  if (eof)
  {
    close ARGV;
    $files_done++;
    # Do not enable this, very loud and noticably slower
    print "###     $$ finished $ARGV\n" if $ENV{DEBUG};
  }
  END
  {
    # Log our heredity so post-processing can regroup if needed
    print "###   grandchild $::ENV{GRANDPARENT} -> " . getppid() .
        " -> $$ processed $files_done files\n";
  }
  '
}
export -f do_dirs

PKGS=$(wc -l "$PKG_LIST" | cut -d\  -f1)

# Populate DIRS (distro-specific)
make_dir_list

# XXX: we should track paths that have been scanned so we can resume
# without redundant re-scans. Either keep a list and filter against it,
# or touch state files a layer up?

export DIR_COUNT=${#DIRS[@]}
BATCHES=$(( ($DIR_COUNT + $BATCH_SIZE - 1) / $BATCH_SIZE))

echo "### Found $DIR_COUNT dirs for $PKGS pkgs under $UNPACK_DIR, doing $BATCHES batches of $BATCH_SIZE ea with $JOBS parallel jobs"

printf "%s\0" "${DIRS[@]}" | parallel -0 -j$JOBS -n $BATCH_SIZE --line-buffer --joblog +${SCAN_LOG} 'echo "### child $$ processing batch {#}/'"$BATCHES"'" && do_dirs {} && echo "### child $$ finished"'
