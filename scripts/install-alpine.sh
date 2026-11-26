#!/bin/sh
# Install pingora-waf on Alpine and enable the OpenRC service.
#
#   wget -qO- https://raw.githubusercontent.com/shidianxia/pingora-waf/main/scripts/install-alpine.sh | sh
#
# Optional environment:
#   PINGORA_WAF_VERSION=v0.1.0
#   PINGORA_WAF_UPSTREAM_HOST=127.0.0.1
#   PINGORA_WAF_UPSTREAM_PORT=8080
set -eu

repo="${PINGORA_WAF_REPO:-shidianxia/pingora-waf}"
upstream_host="${PINGORA_WAF_UPSTREAM_HOST:-127.0.0.1}"
upstream_port="${PINGORA_WAF_UPSTREAM_PORT:-8080}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root." >&2
    exit 1
fi

if [ ! -f /etc/alpine-release ]; then
    echo "This installer only supports Alpine Linux." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64) target="x86_64-unknown-linux-musl" ;;
    *)
        echo "Unsupported architecture: $(uname -m). Published builds are x86_64." >&2
        exit 1
        ;;
esac

case "$upstream_host" in
    *[!A-Za-z0-9._-]*)
        echo "Invalid PINGORA_WAF_UPSTREAM_HOST: $upstream_host" >&2
        exit 1
        ;;
esac

case "$upstream_port" in
    ''|*[!0-9]*)
        echo "Invalid PINGORA_WAF_UPSTREAM_PORT: $upstream_port" >&2
        exit 1
        ;;
esac

apk add --no-cache ca-certificates curl tar openrc

fetch() {
    curl -fsSL "$1" -o "$2"
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

version="${PINGORA_WAF_VERSION:-}"
if [ -z "$version" ]; then
    if fetch "https://api.github.com/repos/${repo}/releases/latest" "$tmpdir/release.json"; then
        version=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$tmpdir/release.json" | head -n 1)
    fi
    version="${version:-v0.1.0}"
fi

case "$version" in
    v[0-9]*) ;;
    *)
        echo "Invalid release tag: $version" >&2
        exit 1
        ;;
esac

asset="pingora-waf-${version}-${target}.tar.gz"
base_url="https://github.com/${repo}/releases/download/${version}"

echo "Downloading ${asset}"
fetch "${base_url}/${asset}" "$tmpdir/$asset"
fetch "${base_url}/${asset}.sha256" "$tmpdir/$asset.sha256"
(
    cd "$tmpdir"
    sha256sum -c "$asset.sha256"
)
tar -xzf "$tmpdir/$asset" -C "$tmpdir"

bin=$(find "$tmpdir" -type f -name pingora-waf | head -n 1)
cfg=$(find "$tmpdir" -type d -name config | head -n 1)
if [ -z "$bin" ] || [ -z "$cfg" ]; then
    echo "Release archive is missing the binary or config directory." >&2
    exit 1
fi

if ! id pingora-waf >/dev/null 2>&1; then
    adduser -D -H -s /sbin/nologin -h /var/lib/pingora-waf pingora-waf
fi

install -d -m 0755 /usr/local/bin /etc/conf.d
install -d -o pingora-waf -g pingora-waf -m 0755 /var/log/pingora-waf /var/lib/pingora-waf
install -d -o root -g pingora-waf -m 0750 /etc/pingora-waf
install -m 0755 "$bin" /usr/local/bin/pingora-waf

for file in "$cfg"/*.yaml; do
    [ -f "$file" ] || continue
    dest="/etc/pingora-waf/$(basename "$file")"
    if [ ! -e "$dest" ]; then
        install -o root -g pingora-waf -m 0640 "$file" "$dest"
    fi
done

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -f "$script_dir/pingora-waf.initd" ] && [ -f "$script_dir/pingora-waf.confd" ]; then
    init_src="$script_dir/pingora-waf.initd"
    conf_src="$script_dir/pingora-waf.confd"
else
    raw="https://raw.githubusercontent.com/${repo}/main/scripts"
    fetch "${raw}/pingora-waf.initd" "$tmpdir/pingora-waf.initd"
    fetch "${raw}/pingora-waf.confd" "$tmpdir/pingora-waf.confd"
    init_src="$tmpdir/pingora-waf.initd"
    conf_src="$tmpdir/pingora-waf.confd"
fi

install -m 0755 "$init_src" /etc/init.d/pingora-waf
if [ ! -e /etc/conf.d/pingora-waf ]; then
    sed \
        -e "s/^WAF_UPSTREAM_HOST=.*/WAF_UPSTREAM_HOST=\"${upstream_host}\"/" \
        -e "s/^WAF_UPSTREAM_PORT=.*/WAF_UPSTREAM_PORT=\"${upstream_port}\"/" \
        "$conf_src" > /etc/conf.d/pingora-waf
    chmod 0644 /etc/conf.d/pingora-waf
fi

rc-update add pingora-waf default || true

echo
echo "Installed pingora-waf ${version}"
echo "  proxy:    http://${WAF_LISTEN_ADDR:-0.0.0.0}:6188"
echo "  metrics:  http://127.0.0.1:6190/metrics"
echo "  config:   /etc/pingora-waf/waf_rules.yaml"
echo "  service:  /etc/conf.d/pingora-waf"
echo "  logs:     /var/log/pingora-waf/"
echo "The shipped rules blacklist 10.0.0.0/8. Edit the config before exposing the proxy."
echo

if rc-service pingora-waf restart; then
    rc-service pingora-waf status || true
else
    echo "OpenRC is installed and enabled for boot, but it is not supervising services in this environment." >&2
    exit 1
fi
