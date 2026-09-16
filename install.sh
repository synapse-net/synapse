#!/bin/sh
# Synapse installer / uninstaller — the only file this project publishes.
#
#   install:    curl -fsSL https://raw.githubusercontent.com/synapse-net/synapse/main/install.sh | sudo sh
#   uninstall:  curl -fsSL https://raw.githubusercontent.com/synapse-net/synapse/main/install.sh | sudo sh -s uninstall
#   licensed:   ... | sudo sh -s -- --license <token> --from <one-time link>
#   one side:   ... | sudo sh -s -- --license <token> --from <link> --role iran|kharej
#                  [--kind reverse|direct]
#   offline:    sudo sh install.sh --local ./synapse_vX.Y.Z_linux_amd64.tar.gz --role iran
#
# Install downloads the prebuilt binary for this host's CPU architecture from our own
# distribution host, verifies it against the published checksums, installs it and every config into
# /root/synapse, symlinks /usr/local/bin/synapse so the command stays global, and opens the
# interactive menu. Uninstall stops and deletes every synapse-* service, the symlink and
# /root/synapse.
#
# One directory on purpose: tuning a tunnel means hand-editing its TOML, and the config
# belongs beside the binary rather than under /etc on the other side of the filesystem.
#
# Supported: any Linux distribution — Ubuntu/Debian, CentOS/AlmaLinux/Rocky, Fedora, Arch,
# openSUSE, Alpine. The binary is static (built CGO-free), so there is one artefact per
# architecture (amd64, arm64), never one per distro. `iptables` is needed only for the
# RST-drop firewall option, `iproute2` only for tun mode, systemd only to run as a service.
#
# POSIX sh on purpose: a fresh VPS image is not guaranteed to have bash, and `curl | sh` on
# a box with no bash failing at line 1 is a bad first impression.
set -eu

# Where everything this script fetches comes from (roadmap 11.6k). It used to be GitHub —
# raw.githubusercontent for the script and a release for the tarball — which made the one
# command a customer runs *as root* a dependency on a host we do not control, serving a repo
# 11.7 says is private. Both now come from the licence box, over the same TLS front the
# fifteen-minute check already uses. Overridable for the verification harness, which runs it
# against a throwaway daemon on the loopback.
BASE_URL="${SYNAPSE_BASE_URL:-https://raw.githubusercontent.com/synapse-net/synapse/main}"
# The licence box stays as the second base: the public repo is the front door, and the two
# hosts fail for different reasons (a blocked github vs a burnt Iranian address), so one
# covers the other. An explicit SYNAPSE_BASE_URL turns the fallback off - the verification
# harness points at a loopback daemon and must not silently reach a real host.
BASE_URL_FALLBACKS="https://update.parsgamers.com.ge:8444"
if [ -n "${SYNAPSE_BASE_URL:-}" ]; then BASE_URL_FALLBACKS=""; fi
VERSION="${SYNAPSE_VERSION:-latest}"
BIN_NAME="synapse"
# A licence token, and the one-time link the licence service issued for this customer's
# stamped build. Both have an environment spelling so a provisioning system can pass them
# without putting a bearer credential in a command line that `ps` shows to every user on the
# box; --license also takes @/path/to/file for the same reason.
#
# They are two flags rather than one because they are two different things and are often
# used apart: --from alone installs the premium build (for someone who will paste the token
# into the menu), and --license alone is the upgrade an operator does after buying, when the
# build on the box is already the right one.
LICENSE="${SYNAPSE_LICENSE:-}"
DOWNLOAD_URL="${SYNAPSE_DOWNLOAD_URL:-}"
# Roadmap 12a, the two flags that let one command finish one side of a tunnel.
#
# --role iran|kharej is handed to the menu, which then skips its Role question. It is the
# one step a customer cannot answer from the command they were given: everything else the
# menu asks is about their own ports and backend, but "which number is my side" is a fact of
# the purchase, and the bot already knows it.
#
# --local <file> installs a tarball that is already on the box, through exactly the same path
# a download takes. It exists because the Iran side of a first install often cannot reach
# anything abroad — sometimes not even our distribution host — and the tunnel that would fix
# that is the thing being installed. A tarball that arrived by Telegram, scp or a USB stick
# had no supported way in: the script demands an https:// URL.
ROLE="${SYNAPSE_ROLE:-}"
# --kind reverse|direct is handed to the menu beside the role. Empty means the menu asks, and
# an empty answer there is reverse: every box in the field runs one.
KIND="${SYNAPSE_KIND:-}"
LOCAL_TARBALL="${SYNAPSE_LOCAL:-}"
# --no-deps leaves the package manager alone; by default the missing host tools are installed.
NO_DEPS="${SYNAPSE_NO_DEPS:-}"
# --no-menu installs and stops (roadmap item 14b). The script's last act is to exec the menu
# whenever there is a terminal, which is right for somebody installing by hand and wrong for
# the guided install: there the bot's screen hands over two commands — this one, and then
# `synapse setup` — and a menu that eats the terminal takes the second one as an answer to a
# prompt. It is also what a provisioning script wants, which until now it only got by having
# no controlling terminal.
NO_MENU="${SYNAPSE_NO_MENU:-}"
# The install root. Literally /root, not $HOME: this script runs under sudo, where $HOME is
# often still the invoking user's, and the binary and its tokens should not land in a home
# directory that other logins can reach.
INSTALL_DIR="${SYNAPSE_DIR:-/root/synapse}"
CONFIG_DIR="$INSTALL_DIR"
LEGACY_CONFIG_DIR="/etc/synapse"
# Where the symlink goes, so `synapse` works from anywhere without touching a shell profile.
LINK_DIR="${SYNAPSE_BIN_DIR:-/usr/local/bin}"
UNIT_DIR="/etc/systemd/system"

# --- output ----------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'
  C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_GRAY='\033[90m'
else
  C_RESET=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_GRAY=''
fi

say()  { printf "%b[*]%b %s\n" "$C_GRAY" "$C_RESET" "$1"; }
ok()   { printf "%b✓%b %s\n"   "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf "%b!%b %s\n"   "$C_YELLOW" "$C_RESET" "$1"; }
die()  { printf "%b✗%b %s\n"   "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

need_root() { [ "$(id -u)" = "0" ] || die "run as root (prefix the command with sudo)"; }

# --- uninstall -------------------------------------------------------------------------

uninstall() {
  need_root
  say "removing synapse"

  # Stop, disable and delete every tunnel service this project installed. Stopping the unit
  # sends the process SIGTERM, which is what makes it withdraw its own firewall rules before
  # it exits. A daemon that already died on a fatal path never did; that is swept below.
  #
  # Which units are ours is decided by what they run, never by their name. The licence box
  # runs synapse-licensed and synapse-licbot, and both match the same glob a tunnel does — so
  # the old sweep by name, followed by `rm -f $UNIT_DIR/synapse-*.service`, took the licence
  # authority down with the tunnels on the one host where that is unrecoverable. A tunnel unit
  # is the one whose ExecStart names a config file in one of our config directories; nothing
  # else does, because the daemon and the bot take flags rather than a TOML.
  if command -v systemctl >/dev/null 2>&1; then
    UNITS=$(systemctl list-unit-files --no-legend "$BIN_NAME-*.service" 2>/dev/null | awk '{print $1}')
    for f in "$UNIT_DIR/$BIN_NAME-"*.service; do
      if [ -f "$f" ]; then
        UNITS="$UNITS
$(basename "$f")"
      fi
    done
    REMOVED=""
    for u in $(printf '%s\n' $UNITS | sort -u); do
      f="$UNIT_DIR/$u"
      [ -f "$f" ] || continue
      if ! grep -qE "^ExecStart=.*($INSTALL_DIR|$LEGACY_CONFIG_DIR)/[^ ]*\.toml" "$f"; then
        say "left $u alone: not a tunnel"
        continue
      fi
      systemctl disable --now "$u" >/dev/null 2>&1 && ok "stopped $u" || warn "could not stop $u"
      rm -f "$f"
      REMOVED=yes
    done
    if [ -n "$REMOVED" ]; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    # A unit file deleted without `systemctl disable` leaves its enablement link behind, and
    # the link outlives the uninstall. Only the dangling ones go: a link whose unit file is
    # still there belongs to a service that is still installed — the licence box's.
    for l in "$UNIT_DIR"/*.wants/"$BIN_NAME-"*.service; do
      [ -L "$l" ] || continue
      [ -e "$l" ] && continue
      rm -f "$l" && ok "removed dangling $l"
    done
  fi

  # The rules of daemons that exited without withdrawing their own. Stopping a unit is what
  # normally withdraws them, but a run that dies on a fatal path never gets there, and after
  # an uninstall nothing on this box ever runs to sweep it. Only `synapse-` comments whose
  # pid is gone are touched: a live sibling's rule is byte-identical, and an untagged comment
  # from an older build has no owner we can check.
  if command -v iptables >/dev/null 2>&1; then
    iptables -w 5 -S OUTPUT 2>/dev/null | grep -F -- '--comment "synapse-' | while IFS= read -r rule; do
      pid=$(printf '%s' "$rule" | sed -n 's/.*--comment "synapse-[a-z-]*:\([0-9][0-9]*\)".*/\1/p')
      [ -n "$pid" ] || continue
      [ -d "/proc/$pid" ] && continue
      eval "iptables -w 5 -D OUTPUT ${rule#-A OUTPUT }" 2>/dev/null &&
        ok "removed leftover firewall rule of pid $pid"
    done
  fi

  # The symlink first, then the directory it points into. Remove the link only if it is ours:
  # on a box where an older release installed a real binary at that path, that file is also
  # ours, but anything else there belongs to whoever put it there.
  if [ -L "$LINK_DIR/$BIN_NAME" ] || [ -f "$LINK_DIR/$BIN_NAME" ]; then
    rm -f "$LINK_DIR/$BIN_NAME"
    ok "removed $LINK_DIR/$BIN_NAME"
  fi

  # The install directory holds the binary and the tunnel tokens; take it too, but ask first
  # when a human is present so a reinstall-in-place does not silently lose every tunnel.
  for dir in "$INSTALL_DIR" "$LEGACY_CONFIG_DIR"; do
    [ -d "$dir" ] || continue
    REPLY=y
    if [ -t 0 ]; then
      printf "%bremove %s and all tunnel configs? [Y/n] %b" "$C_YELLOW" "$dir" "$C_RESET"
      read -r REPLY || REPLY=y
    fi
    case "${REPLY:-y}" in
      n|N) say "kept $dir" ;;
      *)   rm -rf "$dir"; ok "removed $dir" ;;
    esac
  done

  ok "synapse uninstalled"
  exit 0
}

# --- dependencies ----------------------------------------------------------------------

# pkg_install installs the named packages with whatever package manager this distro has.
# Quiet and non-interactive: this often runs from `curl | sh`, where a prompt has no stdin.
pkg_install() {
  [ $# -gt 0 ] || return 0
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive --quiet install "$@" >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet --no-cache "$@" >/dev/null 2>&1
  else
    return 1
  fi
}

# pkg_name maps a command to this distro's package for it, because the names differ.
pkg_name() {
  case "$1" in
    ip)
      if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        echo iproute
      else
        echo iproute2
      fi ;;
    curl) echo "curl ca-certificates" ;;
    *)    echo "$1" ;;
  esac
}

# ensure_deps installs what is missing before anything needs it. curl and tar are fatal when
# absent and unfixable; ip and iptables are per-feature and only earn a warning.
ensure_deps() {
  if [ -n "$NO_DEPS" ]; then return 0; fi

  want=""
  if [ -z "$LOCAL_TARBALL" ] && ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    want="$want $(pkg_name curl)"
  fi
  command -v tar >/dev/null 2>&1     || want="$want $(pkg_name tar)"
  command -v ip >/dev/null 2>&1      || want="$want $(pkg_name ip)"
  command -v iptables >/dev/null 2>&1 || want="$want $(pkg_name iptables)"

  # shellcheck disable=SC2086
  set -- $want
  [ $# -gt 0 ] || return 0

  say "installing missing packages: $*"
  if pkg_install "$@"; then
    ok "packages installed"
  else
    warn "could not install packages automatically; install them by hand if a step below fails"
  fi

  command -v ip >/dev/null 2>&1       || warn "no iproute2: the tun transport will not work"
  command -v iptables >/dev/null 2>&1 || warn "no iptables: the RST-drop option and tun forwarding will not work"
}

# --- install ---------------------------------------------------------------------------

install_synapse() {
  need_root
  [ "$(uname -s)" = "Linux" ] || die "synapse ships Linux binaries only; this is $(uname -s)"

  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "no prebuilt binary for $(uname -m) — only amd64 and arm64 are published" ;;
  esac

  ensure_deps

  # One of curl or wget is enough; minimal images sometimes carry only one. Under --local
  # neither is needed, and demanding one would refuse the install on exactly the box the
  # flag exists for — a machine with no route out is also a machine where nobody bothered
  # to install a downloader.
  if command -v curl >/dev/null 2>&1; then
    fetch()      { curl -fsSL "$1"; }
    fetch_file() { curl -fsSL "$1" -o "$2"; }
  elif command -v wget >/dev/null 2>&1; then
    fetch()      { wget -qO- "$1"; }
    fetch_file() { wget -qO "$2" "$1"; }
  elif [ -z "$LOCAL_TARBALL" ]; then
    die "need curl or wget"
  fi
  command -v tar >/dev/null 2>&1 || die "need tar"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM

  if [ -n "$LOCAL_TARBALL" ]; then
    local_tarball
  elif [ -n "$DOWNLOAD_URL" ]; then
    premium_download
  else
    release_download
  fi

  tar -xzf "$TMP/$TARBALL" -C "$TMP" || die "tar failed — the download is probably truncated"
  [ -f "$TMP/$BIN_NAME" ] || die "$BIN_NAME missing from the tarball"

  install_files
  finish
}

# release_download fetches the stock build from our distribution host and verifies it against
# the published checksums.txt. Sets TARBALL.
#
# This is the unlicensed path, and since 11.1 the binary it installs refuses to run without a
# licence — which is the point at which the customer is told to talk to the bot. It is still
# worth having: an operator upgrading a box in the field wants the binary before the token, and
# an install that fails at "download" cannot tell them the difference.
# pick_base settles which distribution host this install uses, and resolves the latest tag
# while it is there. One line, one file, no API: every base publishes the current tag in
# pub/VERSION. Parsing a JSON release feed with sed was the fragile half of the old path, and
# its redirect to an HTML page is what some minimal images could not follow.
#
# The same fetch is the reachability probe: a base that cannot serve VERSION cannot serve the
# tarball either, so the next base is tried before anything large is downloaded.
pick_base() {
  if [ "$VERSION" = "latest" ]; then say "resolving the latest release..."; fi
  for base in "$BASE_URL" $BASE_URL_FALLBACKS; do
    got=$(fetch "$base/pub/VERSION" 2>/dev/null | tr -d ' \t\r\n')
    if [ -z "$got" ]; then
      warn "$base is not answering; trying the next host"
      continue
    fi
    BASE_URL="$base"
    if [ "$VERSION" = "latest" ]; then VERSION="$got"; fi
    return 0
  done
  die "could not reach any distribution host (network blocked? set SYNAPSE_BASE_URL, or install from a local tarball with --local)"
}

release_download() {
  pick_base
  say "installing synapse $VERSION for linux/$ARCH"

  BASE="$BASE_URL/pub"
  TARBALL="synapse_${VERSION}_linux_${ARCH}.tar.gz"

  say "downloading $TARBALL"
  fetch_file "$BASE/$TARBALL" "$TMP/$TARBALL" || die "download failed: $BASE/$TARBALL"

  # The checksum is not optional. This binary terminates a tunnel and holds its token; a
  # truncated download over a lossy link is the *likely* failure here, not the exotic one,
  # and it would install a corrupt binary that systemd then restart-loops on.
  if fetch_file "$BASE/checksums_${VERSION}.txt" "$TMP/checksums.txt" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      # Match the filename in field 2 whether sha256sum wrote it in text mode ("<hash>  file")
      # or binary mode ("<hash> *file") — the separator differs by platform, the hash does not.
      EXPECTED=$(awk -v f="$TARBALL" '{ n=$2; sub(/^\*/, "", n); if (n == f) print $1 }' "$TMP/checksums.txt")
      ACTUAL=$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')
      [ -n "$EXPECTED" ] || die "no checksum listed for $TARBALL"
      [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — got $ACTUAL, expected $EXPECTED"
      ok "checksum verified"
    else
      warn "sha256sum not found; skipping verification"
    fi
  else
    warn "no checksums.txt in the release; skipping verification"
  fi
}

# premium_download fetches a per-customer build from the one-time link the licence service
# issued (--from / SYNAPSE_DOWNLOAD_URL; docs/LICENSING.md Part 12). Sets TARBALL.
#
# Three things make this path different from the public one, and all three are consequences
# of the link being one-time:
#
#   - There is no checksums.txt to fetch, because there is no published artefact — the
#     tarball is stamped for this customer as it is served, so no two are identical. The
#     service sends its sha256 in the X-Synapse-Sha256 header instead, and that is what is
#     verified. It is not a signature and is not claimed as one: it catches the truncated
#     transfer, which is the failure this actually has.
#   - The link is spent the moment the response starts, so *nothing* below re-fetches, and
#     every failure after this point says so. An operator who reads "download failed" and
#     re-runs the command would otherwise spend their evening wondering why the second
#     attempt 404s.
#   - The architecture is chosen *here* (roadmap 12b). Whoever minted the link — the bot,
#     the shop, an operator — was not looking at this box, so the link is unpinned and the
#     claim carries `arch=`, which this script has already detected. An operator can still
#     pin one deliberately, in which case the pin wins and the served build may not run
#     here; `install_files` execs the installed binary and names that as the likely cause.
premium_download() {
  case "$DOWNLOAD_URL" in
    https://*) ;;
    http://127.0.0.1*|http://localhost*)
      # Plain HTTP only against the loopback, where there is no network to eavesdrop on.
      # This is what the verification harness uses; a real link is https.
      warn "downloading over plain HTTP from the loopback" ;;
    *) die "--from must be an https:// link (got: $DOWNLOAD_URL)" ;;
  esac
  command -v sha256sum >/dev/null 2>&1 || warn "sha256sum not found; the download cannot be verified"

  TARBALL="synapse_premium_linux_${ARCH}.tar.gz"
  # Tell the service what this box is. A link that already carries a query keeps it — an
  # operator's link can have one — so the separator is chosen rather than assumed.
  case "$DOWNLOAD_URL" in
    *\?*) CLAIM_URL="${DOWNLOAD_URL}&arch=${ARCH}" ;;
    *)    CLAIM_URL="${DOWNLOAD_URL}?arch=${ARCH}" ;;
  esac
  say "downloading your licensed build for linux/$ARCH (one-time link)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -D "$TMP/headers" "$CLAIM_URL" -o "$TMP/$TARBALL" \
      || die "download failed — a one-time link is spent by the first attempt and expires after 24h; ask for a new one"
  else
    # wget writes response headers to stderr under -S, and only there.
    wget -qS -O "$TMP/$TARBALL" "$CLAIM_URL" 2>"$TMP/headers" \
      || die "download failed — a one-time link is spent by the first attempt and expires after 24h; ask for a new one"
  fi

  EXPECTED=$(awk 'tolower($1) == "x-synapse-sha256:" { print $2 }' "$TMP/headers" | tr -d '\r' | tail -n1)
  if [ -n "$EXPECTED" ] && command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')
    [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — got $ACTUAL, expected $EXPECTED (the link is spent; ask for a new one)"
    ok "checksum verified"
  else
    warn "the download carried no checksum header; skipping verification"
  fi
}

# local_tarball takes a tarball that is already on this box (--local / SYNAPSE_LOCAL) and
# puts it where the two download paths leave theirs, so everything after this point — the
# extract, install, the migrate, the menu — is the same code (roadmap 12a, 12d).
#
# It copies rather than extracting in place: the file is the customer's, often the only copy
# on a box with no route to fetch another, and `tar -xzf` writing a `synapse` binary into
# whatever directory they happened to `cd` into is a surprise. $TMP is removed on exit either
# way, so the original survives a failed install and can be retried.
#
# Verification is what this path cannot have. There is no header to read and no published
# checksums.txt that covers a stamped per-customer build, so a `<file>.sha256` beside the
# tarball is honoured when it exists and its absence is a warning, not a refusal — the
# transfer that got the file here was a hand-carry, and if that is what the box has, an
# installer that says no leaves the operator with nothing. `install_files` still runs the
# binary before declaring success, which catches the truncation and the wrong architecture.
local_tarball() {
  [ -f "$LOCAL_TARBALL" ] || die "--local: no such file: $LOCAL_TARBALL"
  [ -r "$LOCAL_TARBALL" ] || die "--local: cannot read $LOCAL_TARBALL"
  [ -s "$LOCAL_TARBALL" ] || die "--local: $LOCAL_TARBALL is empty"

  TARBALL=$(basename "$LOCAL_TARBALL")
  say "installing from $LOCAL_TARBALL"
  cp "$LOCAL_TARBALL" "$TMP/$TARBALL" || die "--local: could not copy $LOCAL_TARBALL"

  if [ -f "$LOCAL_TARBALL.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    # Either shape of a sha256sum line, and a bare hash on its own — a hash pasted out of a
    # chat window arrives without a filename more often than with one.
    EXPECTED=$(awk 'NF { print $1; exit }' "$LOCAL_TARBALL.sha256" | tr -d '\r')
    ACTUAL=$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')
    [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — got $ACTUAL, expected $EXPECTED (the transfer is corrupt; copy the file again)"
    ok "checksum verified"
  else
    warn "no $TARBALL.sha256 beside it; the file cannot be verified"
  fi
}

# install_files puts the extracted binary in place and links it.
install_files() {
  # 0700: the directory holds every tunnel's token alongside the binary.
  mkdir -p "$INSTALL_DIR"
  chmod 0700 "$INSTALL_DIR"
  # Install to a temporary name and rename into place: mv within one filesystem is atomic,
  # so an upgrade can never leave a half-written binary where a running service will exec it.
  install -m 0755 "$TMP/$BIN_NAME" "$INSTALL_DIR/.$BIN_NAME.new"
  mv -f "$INSTALL_DIR/.$BIN_NAME.new" "$INSTALL_DIR/$BIN_NAME"
  BIN="$INSTALL_DIR/$BIN_NAME"
  # Run it once before going any further. This used to be inlined in the message below,
  # where a binary that could not exec still printed a cheerful "installed" line: a command
  # substitution that fails inside an argument does not fail the command. A licensed link
  # normally serves the architecture this script asks for (12b), so reaching this on that
  # path means the link was pinned to another one.
  if ! VER=$("$BIN" -v 2>&1); then
    if [ -n "$DOWNLOAD_URL" ]; then
      die "the downloaded binary does not run here ($VER) — this box is $ARCH; was the link pinned to another architecture?"
    fi
    if [ -n "$LOCAL_TARBALL" ]; then
      die "the binary in $LOCAL_TARBALL does not run here ($VER) — this box is $ARCH; is that the tarball for another architecture?"
    fi
    die "the installed binary does not run here ($VER)"
  fi
  ok "installed $BIN ($VER)"

  # Keep the command global. -f because the path may still hold a real binary from a release
  # before v0.1.2; -n so a re-run cannot plant the link *inside* an existing symlinked dir.
  mkdir -p "$LINK_DIR"
  ln -sfn "$BIN" "$LINK_DIR/$BIN_NAME"
  ok "linked $LINK_DIR/$BIN_NAME -> $BIN"

  # Two repairs, one subcommand. It moves a pre-v0.1.2 install across (/etc/synapse/*.toml
  # into $INSTALL_DIR, every unit rewritten so ExecStart names the new paths), and it adds
  # the ReadWritePaths line to units written before that line existed — without which a
  # licensed tunnel cannot cache the grant it just fetched. The second repair is why the call
  # is unconditional: a box past the layout move has no $LEGACY_CONFIG_DIR and would never
  # run it. SYNAPSE_VERSION can still pin a release older than the subcommand, so a failure
  # is only worth a warning when there was a layout to move.
  MIG_OUT=$("$BIN" migrate 2>&1) && MIG_OK=1 || MIG_OK=
  if [ -n "$MIG_OK" ]; then
    if [ -n "$MIG_OUT" ]; then printf '%s
' "$MIG_OUT"; fi
  elif [ -d "$LEGACY_CONFIG_DIR" ]; then
    printf '%s
' "$MIG_OUT"
    warn "migration failed — your configs are still in $LEGACY_CONFIG_DIR"
  fi
}

# finish stores the licence, restarts what was running, and hands over to the menu.
finish() {
  # The licence, before the restarts: `license set` writes [license] token into every config
  # in the install directory and signals the tunnels already running to re-read it (roadmap
  # 34.6), so the licence is in effect before the restart below rather than because of it.
  # The restart still has to happen — it is what puts the *new binary* into effect — but a
  # box that never needed one would be licensed all the same.
  if [ -n "$LICENSE" ]; then
    set_license
  fi

  if command -v systemctl >/dev/null 2>&1; then
    RUNNING=$(systemctl list-units --type=service --state=running --no-legend "$BIN_NAME-*" 2>/dev/null \
      | awk '{print $1}')
    if [ -n "$RUNNING" ]; then
      say "restarting existing tunnels onto the new binary"
      for unit in $RUNNING; do
        systemctl restart "$unit" && ok "restarted $unit" || warn "could not restart $unit"
      done
    fi
  fi

  printf "\n"
  printf "%b✓%b done. Run %bsynapse%b to configure or remove a tunnel; configs are in %b%s%b.\n" \
    "$C_GREEN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$CONFIG_DIR" "$C_RESET"
  say "uninstall everything later with:  curl -fsSL $BASE_URL/install.sh | sudo sh -s uninstall"

  # Only launch the menu when a human is at the keyboard. `curl | sh` gives the script no
  # usable stdin, so read from the terminal explicitly; in CI or a provisioning script there
  # is no terminal and we exit quietly instead of hanging on a prompt forever. Test that
  # /dev/tty can actually be *opened*, not just that the node exists — a non-interactive
  # SSH/CI session has no controlling terminal, where a bare `[ -r /dev/tty ]` is true but
  # the redirect then fails noisily.
  #
  # The probe runs in a SUBSHELL, and that is the whole point. A failed redirection on a
  # builtin is a fatal error for a non-interactive POSIX shell: `{ : < /dev/tty; }` makes
  # dash abandon the script with status 2 and busybox ash with status 1 — measured on
  # Ubuntu 22.04 and alpine:3 — so a perfectly successful `curl | sh` ended by reporting
  # failure to whatever provisioning script ran it. Inside `( )` the failure kills only the
  # subshell, which is exactly the false condition we wanted.
  #
  # --role is carried through to the menu, which then opens on the tunnel walk for that side
  # with its Role question already answered (roadmap 12a).
  # --no-menu (item 14b): the caller has its own next command and the menu would consume the
  # terminal before it could be typed. Checked before the terminal probe, so the answer does
  # not depend on whether there happens to be one.
  if [ -n "$NO_MENU" ]; then
    exit 0
  fi
  if [ -n "$ROLE" ]; then
    set -- menu --role "$ROLE"
    [ -n "$KIND" ] && set -- "$@" --kind "$KIND"
  else
    set -- menu
  fi
  if [ -t 0 ]; then
    exec "$BIN" "$@"
  elif (exec 3</dev/tty) 2>/dev/null; then
    exec "$BIN" "$@" < /dev/tty
  fi

  # Never leave the exit status to whatever the last conditional happened to evaluate to.
  exit 0
}

# set_license stores the token by handing it to the binary. Everything that could go wrong
# with it — is the signature ours, is this the machine it was bound to, is the term over,
# which configs need the key writing into them — is decided there, in Go, under test. This
# function's whole job is turning `synapse license set`'s exit status into a sentence.
#
# Exit 3 means the command worked and the licence is not usable here. That is a failed
# install of a *licensed* build, so it stops rather than dropping the operator into a menu
# where every premium option is marked (licence) with no explanation.
set_license() {
  case "$LICENSE" in
    @*)
      # --license @/path keeps the token out of the process table, where a plain argument is
      # readable by every user on the box for as long as the install runs.
      LIC_FILE=${LICENSE#@}
      [ -r "$LIC_FILE" ] || die "cannot read the licence token file: $LIC_FILE"
      LICENSE=$(tr -d ' \t\r\n' < "$LIC_FILE")
      [ -n "$LICENSE" ] || die "the licence token file is empty: $LIC_FILE"
      ;;
  esac

  # --role is passed straight through: the token is stored before any tunnel config exists,
  # so without it the binary has nothing to read this box's side off and the machine stays
  # unbound until the first tunnel starts.
  LIC_RC=0
  if [ -n "$ROLE" ]; then
    "$BIN" license set "$LICENSE" --role "$ROLE" || LIC_RC=$?
  else
    "$BIN" license set "$LICENSE" || LIC_RC=$?
  fi
  case "$LIC_RC" in
    0) ;;
    3) die "the token was stored, but this install is not licensed — the reason is above" ;;
    *) die "storing the licence failed (exit $LIC_RC)" ;;
  esac
}

# --- dispatch --------------------------------------------------------------------------

usage() {
  cat <<EOF
usage: install.sh [install|uninstall] [--license <token|@file>] [--from <one-time link>]
                  [--role iran|kharej] [--kind reverse|direct] [--local <tarball>]
                  [--no-menu] [--no-deps]

  --license   activate a licence token: it is written to $INSTALL_DIR/license.key and into
              [license] token in every tunnel config, the tunnels already running are told to
              re-read it without a restart, and the licence is checked before this returns.
              @/path reads it from a file, which keeps it out of the process table.
              Env: SYNAPSE_LICENSE.
  --from      download the binary from the one-time link the licence service issued instead
              of the stock release. Env: SYNAPSE_DOWNLOAD_URL.
  --role      which side this box is: iran (server, accepts users) or kharej (client, dials
              the Iran box). The menu opens straight on that side's setup instead of asking.
              Env: SYNAPSE_ROLE.
  --kind      the shape of the tunnel: reverse (default — the kharej box dials) or direct
              (the Iran box dials). It must be the same on both boxes; the relay ports stay
              on the Iran side either way. Env: SYNAPSE_KIND.
  --local     install a tarball already on this box instead of downloading one — for an Iran
              box that cannot reach us yet. Verified against <tarball>.sha256 if that file is
              beside it. Env: SYNAPSE_LOCAL.
  --no-menu   install and stop, instead of opening the menu. What the guided install passes,
              because its next screen hands over a \`synapse setup\` line to run after this
              one. Env: SYNAPSE_NO_MENU.
  --no-deps   do not touch the package manager. By default a missing curl, tar, iproute2 or
              iptables is installed with the distro's own package manager before the install
              starts. Env: SYNAPSE_NO_DEPS.

A licensed install normally passes both: the link brings the build that contains the premium
features, the token unlocks the ones that licence bought.
EOF
  exit 0
}

ACTION=install
while [ $# -gt 0 ]; do
  case "$1" in
    install|"")          ACTION=install ;;
    uninstall|remove|rm) ACTION=uninstall ;;
    --license)   shift; [ $# -gt 0 ] || die "--license needs a token (or @file)"; LICENSE=$1 ;;
    --license=*) LICENSE=${1#--license=} ;;
    --from)      shift; [ $# -gt 0 ] || die "--from needs a URL"; DOWNLOAD_URL=$1 ;;
    --from=*)    DOWNLOAD_URL=${1#--from=} ;;
    --role)      shift; [ $# -gt 0 ] || die "--role needs a side (iran or kharej)"; ROLE=$1 ;;
    --role=*)    ROLE=${1#--role=} ;;
    --kind)      shift; [ $# -gt 0 ] || die "--kind needs a kind (reverse or direct)"; KIND=$1 ;;
    --kind=*)    KIND=${1#--kind=} ;;
    --local)     shift; [ $# -gt 0 ] || die "--local needs a path to a tarball"; LOCAL_TARBALL=$1 ;;
    --local=*)   LOCAL_TARBALL=${1#--local=} ;;
    --no-menu)   NO_MENU=1 ;;
    --no-deps)   NO_DEPS=1 ;;
    -h|--help)   usage ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# A flag that only means something on an install must not be swallowed silently by an
# uninstall — the operator has misunderstood something and should hear it now.
if [ "$ACTION" = uninstall ] && { [ -n "$LICENSE" ] || [ -n "$DOWNLOAD_URL" ] || [ -n "$ROLE" ] || [ -n "$KIND" ] || [ -n "$LOCAL_TARBALL" ] || [ -n "$NO_MENU" ]; }; then
  die "--license, --from, --role, --kind, --local and --no-menu apply to install, not uninstall"
fi

# Normalise the role here, where the message can still be read, rather than letting the menu
# reject it after the whole install has run. The Persian words are the spelling everything
# else in this project uses; server/client are accepted for the operator who thinks in those.
case "$ROLE" in
  "") ;;
  iran|IRAN|server)   ROLE=iran ;;
  kharej|KHAREJ|client) ROLE=kharej ;;
  *) die "--role must be iran or kharej (got: $ROLE)" ;;
esac

case "$KIND" in
  "") ;;
  reverse|REVERSE) KIND=reverse ;;
  direct|DIRECT)   KIND=direct ;;
  *) die "--kind must be reverse or direct (got: $KIND)" ;;
esac

# A kind with no role has nothing to answer: the menu asks both questions in one walk.
if [ -n "$KIND" ] && [ -z "$ROLE" ]; then
  die "--kind needs --role: the kind is the second question of one side's walk"
fi

# Two sources for one binary is a mistake with a silent winner, so say which one was meant.
if [ -n "$LOCAL_TARBALL" ] && [ -n "$DOWNLOAD_URL" ]; then
  die "--local and --from both name a build to install; pass one"
fi

case "$ACTION" in
  uninstall) uninstall ;;
  install)   install_synapse ;;
esac
