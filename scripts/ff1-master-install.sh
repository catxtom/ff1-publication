#!/usr/bin/env bash
# ff1-master-install.sh — FF1 Master 安装 / 升级 / 卸载 / 重启（GitHub 发布仓分发）。
#
# 1:1 对应 xctl 的 xctl-master-install.sh，但更简单：FF1 master 已内嵌 web + migrations，
# 发布包只有 ff1-master + dl/(ff1core) + configs + start.sh。
#
#   安装:  curl -fsSL https://raw.githubusercontent.com/catxtom/ff1-publication/main/scripts/ff1-master-install.sh | sudo bash -s -- -install
#   升级:  sudo bash ff1-master-install.sh -upgrade      # 只换二进制 + dl/，保留 config/data
#   卸载:  sudo bash ff1-master-install.sh -uninstall
#   重启:  sudo bash ff1-master-install.sh -restart
#
# 升级由面板「Master 升级」按钮后台 detached 调用；也可手动跑。
set -euo pipefail

REPO="${FF1_PUBLICATION_REPO:-catxtom/ff1-publication}"
MASTER_TAG="${MASTER_TAG:-master-latest}"
MASTER_DIR="${FF1_MASTER_DIR:-/opt/ff1}"
ETC="${FF1_ETC:-/etc/ff1}"
UNIT=/etc/systemd/system/ff1-master.service
CONFIG="${ETC}/master.yaml"
LOCAL_PACKAGE="${LOCAL_PACKAGE:-}"   # 离线：指向本地 ff1master-linux-<arch>-*.tar.gz
ACTION="install"
for a in "$@"; do case "$a" in
  -install|--install) ACTION=install ;;
  -upgrade|--upgrade) ACTION=upgrade ;;
  -uninstall|--uninstall) ACTION=uninstall ;;
  -restart|--restart) ACTION=restart ;;
esac; done

log() { echo "ff1-master: $*"; }
die() { echo "ff1-master: ERROR $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root"
command -v systemctl >/dev/null || die "systemd (systemctl) required"
command -v curl >/dev/null || die "curl required"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac
PKG_URL="https://github.com/${REPO}/releases/download/${MASTER_TAG}/ff1master-linux-${ARCH}-latest.tar.gz"

if [ "$ACTION" = restart ]; then
  systemctl restart ff1-master.service && log "restarted"
  exit 0
fi

if [ "$ACTION" = uninstall ]; then
  log "uninstalling master (config + data preserved under ${ETC})"
  systemctl disable --now ff1-master 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  rm -rf "$MASTER_DIR"
  log "master removed; ${ETC} (config/state.db) kept — remove it manually to purge"
  exit 0
fi

# ---- fetch + extract the master package (install & upgrade share this) ----
fetch_package() { # -> echoes the extracted package dir
  local tmp pkg
  tmp="$(mktemp -d)"
  if [ -n "$LOCAL_PACKAGE" ]; then
    log "using local package $LOCAL_PACKAGE" >&2
    cp "$LOCAL_PACKAGE" "${tmp}/pkg.tar.gz"
  else
    log "downloading ${PKG_URL}" >&2
    curl -fLsS --connect-timeout 30 --max-time 900 -o "${tmp}/pkg.tar.gz" "$PKG_URL" \
      || die "download failed: $PKG_URL"
    # Integrity: verify against the published .sha256 (supply-chain gate; the binary
    # runs as root). A missing sidecar warns rather than fails, for older releases.
    if curl -fLsS --connect-timeout 20 -o "${tmp}/pkg.sha256" "${PKG_URL}.sha256" 2>/dev/null; then
      want="$(awk '{print $1}' "${tmp}/pkg.sha256" 2>/dev/null)"
      got="$(sha256sum "${tmp}/pkg.tar.gz" 2>/dev/null | awk '{print $1}')"
      [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch (want=${want:-?} got=${got:-?}) — refusing to install"
      log "checksum ok" >&2
    else
      log "WARN no published .sha256 for the package — skipping integrity check" >&2
    fi
  fi
  tar -xzf "${tmp}/pkg.tar.gz" -C "$tmp"
  pkg="${tmp}/ff1master-linux-${ARCH}"
  [ -x "${pkg}/ff1-master" ] || die "bad package: ${pkg}/ff1-master missing"
  echo "$pkg"
}

# swap_binary <pkg_dir> : replace the binary + dl/, keeping the previous binary as
# ff1-master.bak (last-known-good for rollback). Preserves config/data.
swap_binary() {
  local pkg="$1"
  mkdir -p "$MASTER_DIR/dl"
  [ -f "${MASTER_DIR}/ff1-master" ] && cp -f "${MASTER_DIR}/ff1-master" "${MASTER_DIR}/ff1-master.bak"
  install -m 0755 "${pkg}/ff1-master" "${MASTER_DIR}/ff1-master.new"
  mv -f "${MASTER_DIR}/ff1-master.new" "${MASTER_DIR}/ff1-master"   # atomic over running binary
  ln -sf "${MASTER_DIR}/ff1-master" /usr/local/bin/ff1-master
  [ -d "${pkg}/dl" ] && cp -Rf "${pkg}/dl/." "${MASTER_DIR}/dl/" 2>/dev/null || true
  # keep a copy of this install script + example config for future self-upgrade
  cp -f "$0" "${ETC}/ff1-master-install.sh" 2>/dev/null || true
  chmod +x "${ETC}/ff1-master-install.sh" 2>/dev/null || true
  [ -f "${pkg}/configs/master.example.yaml" ] && cp -f "${pkg}/configs/master.example.yaml" "${ETC}/master.example.yaml" || true
}

master_rollback() { [ -f "${MASTER_DIR}/ff1-master.bak" ] && mv -f "${MASTER_DIR}/ff1-master.bak" "${MASTER_DIR}/ff1-master"; }

# healthy: require the unit to STAY active across a settle window (Type=simple
# reports active on fork, so a binary that panics a few seconds in would pass one check).
healthy() {
  local i
  for i in $(seq 1 8); do
    sleep 1
    systemctl is-active --quiet ff1-master || return 1
  done
  return 0
}

if [ "$ACTION" = upgrade ]; then
  [ -x "${MASTER_DIR}/ff1-master" ] || die "not installed (no ${MASTER_DIR}/ff1-master); run -install first"
  log "upgrading master (binary + dl/ only; config/data preserved)"
  pkg="$(fetch_package)"
  swap_binary "$pkg"
  systemctl daemon-reload
  systemctl restart ff1-master.service
  if healthy; then
    log "upgrade complete, master restarted (kept ff1-master.bak as last-known-good)"
    exit 0
  fi
  log "new master did not stay healthy; rolling back" >&2
  master_rollback
  systemctl restart ff1-master.service || true
  die "rolled back to the previous master — check: journalctl -u ff1-master"
fi

# ---- fresh install ----
mkdir -p "$MASTER_DIR/dl" "$ETC"
pkg="$(fetch_package)"
swap_binary "$pkg"

# generate a config on first install (secret key + data dir); never overwrite.
if [ ! -f "$CONFIG" ]; then
  SECRET="$(head -c 32 /dev/urandom | base64)"
  cat >"$CONFIG" <<EOF
http_addr: "0.0.0.0:8443"
data_dir: "${ETC}/data"
public_url: "${FF1_PUBLIC_URL:-http://$(hostname -I 2>/dev/null | awk '{print $1}'):8443}"
log_level: "info"
dev: false
secret_key: "${SECRET}"
admin:
  username: "admin"
  password: "${FF1_ADMIN_PASSWORD:-}"
trust_proxy: false
EOF
  chmod 0600 "$CONFIG"
  log "generated ${CONFIG} (edit public_url / admin as needed)"
fi
mkdir -p "${ETC}/data"

cat >"$UNIT" <<EOF
[Unit]
Description=FF1 Master control panel
After=network-online.target
Wants=network-online.target

[Service]
Environment=FF1_AGENT_BIN_DIR=${MASTER_DIR}/dl
ExecStart=${MASTER_DIR}/ff1-master --config ${CONFIG}
WorkingDirectory=${MASTER_DIR}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ff1-master >/dev/null 2>&1 || true
systemctl restart ff1-master.service
if healthy; then
  log "installed and started. config: ${CONFIG}"
  log "panel: $(grep -E '^public_url:' "$CONFIG" | sed 's/^public_url:[[:space:]]*//; s/\"//g')"
else
  die "master did not start — check: journalctl -u ff1-master"
fi
