#!/bin/sh
# FF1 ff1core (forwarding agent) installer — dual-channel, capability-provisioning,
# cross-distro (systemd + OpenRC), POSIX /bin/sh (runs under bash, dash, busybox ash).
#
#   SSH / master 渠道（默认，二进制来自 master 随包 dl/）:
#     curl -fsSL <master>/install/ff1core.sh | sudo sh -s -- --master <url> --token <tok>
#   在线渠道（二进制来自 GitHub 发布仓，脚本自 raw.githubusercontent 取）:
#     curl -fsSL https://raw.githubusercontent.com/catxtom/ff1-publication/main/scripts/install.sh \
#       | sudo sh -s -- --master <url> --token <tok> --channel github
#   卸载: ... sh -s -- --uninstall
#
# ff1core 内嵌 realm + nginx（启动自解压到 FF1_REALM_PATH / FF1_NGINX_PATH），故只下载
# ff1core 一个二进制,转发引擎零安装依赖。安装时只补**内核态**能力(nft 计量 / tc+ifb
# 限速)——这些必须来自宿主机内核+iproute2/nftables,缺了也不中断(转发不依赖它们)。
set -eu
# pipefail where the shell supports it (bash/busybox-ash yes, dash no) — best-effort.
# shellcheck disable=SC3040
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

MASTER="" TOKEN="" ACTION="install" CHANNEL="dl" REPO="${REPO:-catxtom/ff1-publication}"
AGENT_TAG="${AGENT_TAG:-agent-latest}" SKIP_CAPS="${SKIP_CAPS:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --master) MASTER="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --skip-capabilities) SKIP_CAPS=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    *) shift ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "ff1: must run as root" >&2; exit 1; }

BIN=/usr/local/bin
ETC=/etc/ff1
UNIT=/etc/systemd/system/ff1core.service
OPENRC_INIT=/etc/init.d/ff1core
OPENRC_CONF=/etc/conf.d/ff1core
REALM_PATH="$BIN/ff1-realm"
NGINX_PATH="$BIN/ff1-nginx"

# detect_init picks the service manager: systemd (booted) or OpenRC (Alpine/Void/
# Gentoo). Order matters — a booted systemd host always wins. FF1_INIT overrides it
# for unusual hosts (or testing): FF1_INIT=openrc|systemd.
detect_init() {
  case "${FF1_INIT:-}" in systemd|openrc) echo "$FF1_INIT"; return ;; esac
  if [ -d /run/systemd/system ]; then echo systemd
  elif command -v rc-service >/dev/null 2>&1 || command -v openrc >/dev/null 2>&1; then echo openrc
  elif command -v systemctl >/dev/null 2>&1; then echo systemd
  else echo none; fi
}

# --- service-manager abstraction (systemd unit vs OpenRC init.d/conf.d) ----------

write_service() {
  if [ "$INIT" = systemd ]; then
    cat >"$UNIT" <<EOF
[Unit]
Description=FF1 ff1core forwarding agent
After=network-online.target
Wants=network-online.target

[Service]
Environment=FF1_MASTER_URL=$MASTER
Environment=FF1_NODE_TOKEN=$TOKEN
Environment=FF1_REALM_PATH=$REALM_PATH
Environment=FF1_CONFIG_DIR=$ETC/realm
ExecStart=$BIN/ff1core
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  else
    # OpenRC: supervise-daemon gives the Restart=always equivalent (auto-respawn).
    # Env comes from conf.d (sourced by OpenRC, exported → inherited by the daemon).
    mkdir -p /etc/init.d /etc/conf.d   # exist on OpenRC hosts; create defensively
    cat >"$OPENRC_INIT" <<EOF
#!/sbin/openrc-run
supervisor=supervise-daemon
name="ff1core"
description="FF1 ff1core forwarding agent"
command="$BIN/ff1core"
pidfile="/run/ff1core.pid"
respawn_delay=3
respawn_max=0
output_log="/var/log/ff1core.log"
error_log="/var/log/ff1core.log"
rc_ulimit="-n 1048576"

depend() {
	need net
	after firewall
}
EOF
    chmod +x "$OPENRC_INIT"
    cat >"$OPENRC_CONF" <<EOF
# FF1 ff1core environment — sourced by OpenRC before the service starts.
export FF1_MASTER_URL="$MASTER"
export FF1_NODE_TOKEN="$TOKEN"
export FF1_REALM_PATH="$REALM_PATH"
export FF1_CONFIG_DIR="$ETC/realm"
EOF
    chmod 0600 "$OPENRC_CONF"   # token lives here → root-only
  fi
}

enable_start() {
  if [ "$INIT" = systemd ]; then
    systemctl daemon-reload
    systemctl enable ff1core >/dev/null 2>&1 || true
    # restart (not `enable --now`) so a re-run/self-upgrade reloads the new binary.
    systemctl restart ff1core
  else
    rc-update add ff1core default >/dev/null 2>&1 || true
    rc-service ff1core restart
  fi
}

service_active() {
  if [ "$INIT" = systemd ]; then systemctl is-active --quiet ff1core
  else rc-service ff1core status >/dev/null 2>&1; fi
}

# healthy requires the service to STAY up across a settle window, not merely be up
# at one instant (a binary that panics a few seconds in would pass a single check).
healthy() {
  i=1
  while [ "$i" -le 10 ]; do
    sleep 1
    service_active || return 1
    i=$((i + 1))
  done
  return 0
}

if [ "$ACTION" = "uninstall" ]; then
  echo "ff1: uninstalling ff1core"
  INIT="$(detect_init)"
  if [ "$INIT" = systemd ]; then
    systemctl disable --now ff1core 2>/dev/null || true
  else
    rc-service ff1core stop 2>/dev/null || true
    rc-update del ff1core 2>/dev/null || true
  fi
  # let ff1core tear down its own nginx footprint (receipt-driven) if present
  "$BIN/ff1core" uninstall-nginx 2>/dev/null || true
  rm -f "$UNIT" "$OPENRC_INIT" "$OPENRC_CONF"
  [ "$INIT" = systemd ] && { systemctl daemon-reload 2>/dev/null || true; }
  rm -f "$BIN/ff1core" "$REALM_PATH" "$NGINX_PATH"
  rm -rf "$ETC"
  echo "ff1: ff1core removed (system packages untouched)"
  exit 0
fi

echo "@@FF1:STEP:preflight"
[ -n "$MASTER" ] && [ -n "$TOKEN" ] || { echo "ff1: usage: --master <url> --token <token> [--channel dl|github]" >&2; exit 1; }
command -v curl >/dev/null || { echo "ff1: curl is required" >&2; exit 1; }
INIT="$(detect_init)"
[ "$INIT" = none ] && { echo "ff1: 需要 systemd 或 OpenRC init 系统(两者都未检测到)" >&2; exit 1; }
echo "ff1: init=$INIT"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "ff1: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

echo "ff1: arch=$ARCH channel=$CHANNEL"
MASTER="${MASTER%/}"
case "$CHANNEL" in
  dl)     BIN_URL="$MASTER/dl/ff1core-linux-$ARCH" ;;
  github) BIN_URL="https://github.com/$REPO/releases/download/$AGENT_TAG/ff1core-linux-$ARCH" ;;
  *) echo "ff1: --channel must be dl|github" >&2; exit 1 ;;
esac
mkdir -p "$ETC/realm"

# ---- capability provisioning (nft metering / tc+ifb shaping) --------------------

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  elif command -v apk >/dev/null 2>&1; then echo apk
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo none; fi
}

pkg_install() { # <packages...>
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) return 1 ;;
  esac
}

ensure_modules() {
  # Kernel modules for ingress shaping (IFB redirect) + HTB + classification.
  mods="ifb sch_htb sch_ingress act_mirred cls_matchall nft_chain_nat"
  for m in $mods; do modprobe "$m" 2>/dev/null || true; done
  # persist across reboot (best-effort; path may not apply on every init)
  { echo "# FF1 forwarding + traffic-shaping kernel modules"; for m in $mods; do echo "$m"; done; } \
    > /etc/modules-load.d/ff1.conf 2>/dev/null || true
}

provision_capabilities() {
  [ -n "$SKIP_CAPS" ] && { echo "ff1: --skip-capabilities set; not provisioning packages/modules"; return; }
  # nginx is NOT installed here: ff1core carries a static nginx (stream built in) and
  # self-extracts it, so the nginx engine has zero install-time dependency. We only
  # deal with the kernel-plane tools that MUST come from the host: nft (metering) +
  # tc/iproute2 (shaping) + ifb module.
  #
  # CHECK-FIRST (可靠性关键): tc 几乎在所有发行版基础系统里(iproute2),nft 在 Debian10+
  # 也常已存在。**只有在真的缺失时才动包管理器** —— 这样绝大多数机器(含 apt 源已归档的
  # EOL 发行版如 Debian 10)根本不碰 apt,也就不会因 `apt-get update` 404/断网/GFW 而失败。
  need=""
  command -v nft >/dev/null 2>&1 || need="nft"
  command -v tc  >/dev/null 2>&1 || need="${need:+$need }tc"
  if [ -z "$need" ]; then
    echo "ff1: nft + tc 已就位,跳过包安装"
  else
    PM="$(detect_pm)"
    iproute="iproute2"; case "$PM" in dnf|yum) iproute="iproute" ;; esac
    pkgs=""
    case " $need " in *" nft "*) pkgs="nftables" ;; esac
    case " $need " in *" tc "*)  pkgs="${pkgs:+$pkgs }$iproute" ;; esac
    # Alpine ships tc in a subpackage; add it opportunistically (harmless elsewhere).
    [ "$PM" = apk ] && case " $need " in *" tc "*) pkgs="$pkgs iproute2-tc" ;; esac
    if [ "$PM" = none ]; then
      echo "ff1: WARN 缺 [$need] 且无包管理器,请手动安装 nftables/iproute2(否则计量/限速不可用)" >&2
    else
      echo "ff1: 缺 [$need],用 $PM 补装: $pkgs"
      pkg_install $pkgs ca-certificates curl \
        || echo "ff1: WARN 补装失败(可能源不可达/EOL 归档);继续 —— 计量/限速可能不可用,转发不受影响" >&2
    fi
  fi
  ensure_modules
  # GRACEFUL (不能出错): metering 需 nft、shaping 需 tc,但**转发(realm)一个都不需要**。
  # 所以即便最终仍缺,也**不中断安装** —— 节点照常转发,agent 会把"计量/限速不可用"作为
  # 能力上报给面板(而不是装机直接失败)。装得上 > 因降级而装不上。
  command -v nft >/dev/null 2>&1 || echo "ff1: WARN nft 不可用 —— 流量计量将关闭(转发不受影响,可稍后手动装 nftables)" >&2
  command -v tc  >/dev/null 2>&1 || echo "ff1: WARN tc 不可用 —— 限速整形将关闭(转发不受影响,可稍后手动装 iproute2)" >&2
  if ! modprobe ifb 2>/dev/null && ! lsmod 2>/dev/null | grep -q '^ifb'; then
    echo "ff1: WARN ifb 内核模块不可用 —— 上行(ingress)限速将关闭" >&2
  fi
}

echo "@@FF1:STEP:capabilities"
provision_capabilities

# ---- fetch ff1core (realm + nginx are embedded and self-extracted by ff1core) ---

echo "@@FF1:STEP:download"
echo "ff1: downloading ff1core ($ARCH) via $CHANNEL: $BIN_URL"
curl -fLsS --connect-timeout 30 --max-time 600 -o "$BIN/ff1core.new" "$BIN_URL" \
  || { echo "ff1: ERROR download failed: $BIN_URL" >&2; exit 1; }
chmod +x "$BIN/ff1core.new"
[ -f "$BIN/ff1core" ] && cp -f "$BIN/ff1core" "$BIN/ff1core.bak"   # keep last-known-good
mv -f "$BIN/ff1core.new" "$BIN/ff1core"                            # atomic swap over any running binary
rollback() { [ -f "$BIN/ff1core.bak" ] && mv -f "$BIN/ff1core.bak" "$BIN/ff1core"; }

echo "@@FF1:STEP:service"
write_service

echo "@@FF1:STEP:verify"
enable_start

if healthy; then
  # Keep .bak as the last-known-good for the NEXT upgrade's rollback.
  echo "ff1: ff1core installed and started (init=$INIT)"
else
  echo "ff1: ff1core did not stay healthy; rolling back" >&2
  if [ -f "$BIN/ff1core.bak" ]; then
    rollback
    enable_start || true
    echo "ff1: rolled back to the previous ff1core version" >&2
  else
    echo "ff1: no previous version to roll back to (fresh install failed)" >&2
  fi
  exit 1
fi
