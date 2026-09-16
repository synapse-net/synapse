# Synapse

A fast, hardened reverse tunnel for Linux servers. One static binary, an
interactive menu, and a single install command.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/synapse-net/synapse/main/install.sh | sudo sh
```

Detects your CPU architecture, verifies the release checksum, installs everything into
**`/root/synapse`**, and opens the menu. Re-running it upgrades in place and restarts any
running tunnel.

The binary and every tunnel's config live in that one directory, so tuning a tunnel by hand
means editing the TOML sitting next to the binary. `/usr/local/bin/synapse` is a symlink
into it, so the command still works from anywhere.

```sh
synapse           # configure, manage, check status, or remove a tunnel
synapse -v        # version
synapse license   # what this install is entitled to
synapse update    # is this the current build? (and must both ends move together?)
```

`synapse update` fetches nothing: the version travels inside the signed licence grant, so a
box in Iran learns it from its peer rather than by reaching out to us. It exits 4 when a
newer build is published and 3 when nothing has ever told this install anything — which is
not the same as being up to date.

### With a licence

A licence comes with a token and a one-time download link for your own build:

```sh
curl -fsSL https://raw.githubusercontent.com/synapse-net/synapse/main/install.sh \
  | sudo sh -s -- --license <token> --from <your one-time link>
```

The link works once — it is spent the moment the download starts — so if it fails, ask for
a new one rather than re-running. `--license @/path/to/token` reads the token from a file
instead of the command line, which keeps it out of the process table; the token is stored in
`/root/synapse/license.key` and written into every tunnel config on the box. Already have
the right build? `sudo synapse license set <token>` does the same thing without downloading
anything — and on a box that is already running, it takes effect **without a restart**: the
tunnels re-read the licence in place, so nobody using them is disconnected. The menu's
Licence screen does the same from a paste, and `synapse license check` asks the service about
this box now instead of at the next quarter hour.

### Without the one-line install

A box that cannot reach GitHub — or one being set up from a laptop over a hand-carried
file — installs from a tarball instead. Fetch the three files from anywhere that works,
copy them to the box, and point the installer at the tarball:

```sh
BASE=https://raw.githubusercontent.com/synapse-net/synapse/main
VERSION=$(curl -fsSL $BASE/pub/VERSION)      # e.g. v0.5.6
ARCH=amd64                                   # or arm64
curl -fLO $BASE/pub/synapse_${VERSION}_linux_${ARCH}.tar.gz
curl -fLO $BASE/pub/checksums_${VERSION}.txt
curl -fLO $BASE/install.sh
```

On the box, verify and install:

```sh
sha256sum -c --ignore-missing checksums_${VERSION}.txt
sudo sh install.sh --local ./synapse_${VERSION}_linux_${ARCH}.tar.gz --role iran
```

`--local` skips every download and runs the same install as the one-liner: it copies the
tarball out of the way first, so the original survives a failed attempt, then extracts into
`/root/synapse`, links `/usr/local/bin/synapse`, and opens the menu on that side's setup.
`--role kharej` for the other end, and add `--kind direct` on **both** boxes if the Iran box
is the one that dials. Leave `--role` off and the menu asks.

Checksums are verified for you when a `<tarball>.sha256` file sits beside the tarball —
either a `sha256sum` line or a bare hash pasted out of a chat window. Without one the
installer warns and continues, because a box with no route to fetch anything else is better
off installed than refused; it still runs the binary before reporting success, which catches
a truncated transfer or the wrong architecture. So on an air-gapped hand-carry, write the
hash next to the file yourself:

```sh
sha256sum synapse_${VERSION}_linux_${ARCH}.tar.gz > synapse_${VERSION}_linux_${ARCH}.tar.gz.sha256
```

Add `--license <token>` to activate at the same time, `--no-deps` to keep the installer away
from the package manager, and `--no-menu` to install without opening the menu. `sh install.sh
--help` lists them all. Upgrading later is the same command with the newer tarball.

Upgrading from v0.1.1 or earlier moves `/etc/synapse/*.toml` across and rewrites the
systemd units automatically; running tunnels are restarted once, on the new paths.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/synapse-net/synapse/main/install.sh | sudo sh -s uninstall
```

Stops and deletes every `synapse-*` service, the symlink, and `/root/synapse`. To remove a
single tunnel instead of everything, use **`synapse`**.

## Supported systems

One static binary **per CPU architecture**, not per distribution — it is built CGO-free, so
there is no libc to mismatch and the same artefact runs everywhere:

| | |
|---|---|
| **Distributions** | Ubuntu · Debian · CentOS · AlmaLinux · Rocky · Fedora · Arch · openSUSE · Alpine — any modern Linux |
| **Architectures** | `amd64` (x86-64) · `arm64` (aarch64) |
| **Kernel** | 3.2 or newer; glibc and musl both fine |

Optional host tools, needed only for specific features (a plain tcp/ws/tls tunnel needs
none of them):

| tool | needed for |
|---|---|
| `iptables` (or `iptables-nft`) | the RST-drop firewall option and the tun-mode forwarder |
| `iproute2` (`ip`) | `tun` transport |
| systemd | running tunnels as a service (without it the menu still writes the config and shows you how to start it) |

Tool locations are resolved at runtime, so it works whether your distro keeps `iptables`
in `/usr/sbin` (Debian, RHEL) or `/usr/bin` (Arch).

## Transports

| transport | what it is |
|---|---|
| `tcp` / `tcpmux` / `xtcpmux` | plain and multiplexed TCP — highest throughput |
| `ws` / `wss` / `wsmux` / `wssmux` / `xwsmux` | WebSocket, optionally over TLS and behind a CDN |
| `anytls` | uTLS browser-ClientHello mimicry with a real SNI |
| `httpmimic` (alias `xhttp`) | the stream carried inside a chunked HTTP request/response |
| `tun` + `ipx` | raw IP-protocol carrier (icmp/ipip/udp/tcp/gre) with AEAD encryption |

Extra traffic-resilience layers, per tunnel: **`[obfuscation]`** (adaptive padding + timing
jitter, off automatically under load) and **`[fragment]`** (splits the TLS ClientHello so
the SNI never lands in one packet).
