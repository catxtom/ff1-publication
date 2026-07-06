#!/usr/bin/env bash
# ff1-master-install.sh — FF1 Master 交互式安装 / 升级 / 卸载 管理器。
#
# 参考老版 ff1panel-master-install.sh 的交互菜单 UX + LicenseCenter 的「升级」自动识别
# （v1 迁数据 / v2 换程序），适配新 FF1（master 内嵌 web + migrations，发布包只有
# ff1-master + dl/ + ff1-migrate-v1）。
#
#   交互菜单:  curl -fsSL https://raw.githubusercontent.com/catxtom/ff1-publication/main/scripts/ff1-master-install.sh | bash
#   装完后:    ff1                      # 随时开菜单
#   非交互:    bash ff1-master-install.sh -install|-upgrade|-uninstall|-restart
#   升级由面板「Master 升级」后台 detached 调用 `-upgrade`。
set -uo pipefail

# ---------- 常量 ----------
REPO="${FF1_PUBLICATION_REPO:-catxtom/ff1-publication}"
MASTER_TAG="${MASTER_TAG:-master-latest}"
MASTER_DIR="${FF1_MASTER_DIR:-/opt/ff1}"
ETC="${FF1_ETC:-/etc/ff1}"
DATA_DIR="${ETC}/data"
BACKUP_DIR="${FF1_BACKUP_DIR:-/root/ff1databack}"
UNIT=/etc/systemd/system/ff1-master.service
CONFIG="${ETC}/master.yaml"
SELF_COPY="${ETC}/ff1-master-install.sh"
FF1_CLI=/usr/local/bin/ff1
MIGRATE_BIN="${MASTER_DIR}/ff1-migrate-v1"
LOCAL_PACKAGE="${LOCAL_PACKAGE:-}"   # 离线：本地 ff1master-linux-<arch>-*.tar.gz

# 老版 ff1panel（迁移源）痕迹
V1_DIR=/etc/ff1/ff1master
V1_CONFIG="${V1_DIR}/configs/master.yaml"
V1_SERVICE=ff1master

# ---------- 颜色 / 打印（对齐老版 emoji 前缀）----------
if [ -t 1 ]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else RED=; GREEN=; YELLOW=; BLUE=; NC=; fi
print_info()    { echo -e "${BLUE}🅸${NC} $*"; }
print_warn()    { echo -e "${YELLOW}🆆${NC} $*"; }
print_error()   { echo -e "${RED}🅴${NC} $*" >&2; }
print_success() { echo -e "${GREEN}🆂${NC} $*"; }
die() { print_error "$*"; exit 1; }

banner() {
  echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"
  echo
  echo -e "  FF1 Master 管理菜单"
  echo -e "${BLUE}   ________  ________   _____ ${NC}"
  echo -e "${BLUE}  |\\  _____\\|\\  _____\\ / __  \\ ${NC}"
  echo -e "${BLUE}  \\ \\  \\__/ \\ \\  \\__/ |\\/_|\\  \\ ${NC}"
  echo -e "${BLUE}   \\ \\   __\\ \\ \\   __\\\\|/ \\ \\  \\ ${NC}"
  echo -e "${BLUE}    \\ \\  \\_|  \\ \\  \\_|     \\ \\  \\ ${NC}"
  echo -e "${BLUE}     \\ \\__\\    \\ \\__\\       \\ \\__\\ ${NC}"
  echo -e "${BLUE}      \\|__|     \\|__|        \\|__| ${NC}"
  echo
  echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"
}

# ---------- 前置检查 ----------
[ "$(id -u)" = 0 ] || die "请以 root 运行（本脚本自行检测权限，不依赖 sudo）"
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖: $1"; }
# fetch <url> <outfile>: curl 优先，失败/缺失回退 wget（最小 Debian 常只带 wget，或 curl 坏）。
fetch() {
  # curl 静默尝试（吞掉 stderr，避免刷 "(28)" 之类吓人报错）；不通再明确改用 wget。
  # 本类机器常见：curl 直连 github 超时/被封，wget 却能下 —— 所以 wget 是必要回退而非冗余。
  if command -v curl >/dev/null 2>&1 && curl -fLsS --connect-timeout 20 --max-time 900 -o "$2" "$1" 2>/dev/null; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    print_info "curl 未通，改用 wget 下载…" >&2
    wget -q -O "$2" "$1" && return 0
  fi
  return 1
}
preflight() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "需要 curl 或 wget"
  need_cmd systemctl; need_cmd tar
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported arch $(uname -m)" ;;
  esac
  PKG_URL="https://github.com/${REPO}/releases/download/${MASTER_TAG}/ff1master-linux-${ARCH}-latest.tar.gz"
}

# ---------- 安装版本识别（对齐 LicenseCenter detect_install_version）----------
# 输出: none | v1 | v2 | partial
detect_install_version() {
  local has_v2=0 has_v1=0
  local v2_trace=0
  # complete v2 = binary AND config both present.
  if [ -x "${MASTER_DIR}/ff1-master" ] && [ -f "$CONFIG" ]; then has_v2=1; fi
  # any lone v2 trace (binary xor config xor unit) → "partial", but only if not a complete v1/v2.
  if [ -x "${MASTER_DIR}/ff1-master" ] || [ -f "$CONFIG" ] \
     || systemctl list-unit-files 2>/dev/null | grep -q '^ff1-master\.service'; then v2_trace=1; fi
  if [ -f "$V1_CONFIG" ] || [ -d "$V1_DIR" ] \
     || systemctl list-unit-files 2>/dev/null | grep -q "^${V1_SERVICE}\.service"; then has_v1=1; fi
  if [ "$has_v2" = 1 ]; then echo v2
  elif [ "$has_v1" = 1 ]; then echo v1        # a complete v1 wins over a stray v2 trace (offer migrate)
  elif [ "$v2_trace" = 1 ]; then echo partial
  else echo none; fi
}

# ---------- 取包 + 校验 + 解压（install & upgrade 共用）----------
fetch_package() { # -> echoes 解压后的包目录
  local tmp; tmp="$(mktemp -d)"
  if [ -n "$LOCAL_PACKAGE" ]; then
    print_info "使用本地包 $LOCAL_PACKAGE" >&2
    cp "$LOCAL_PACKAGE" "${tmp}/pkg.tar.gz"
  else
    print_info "下载 ${PKG_URL}" >&2
    fetch "$PKG_URL" "${tmp}/pkg.tar.gz" || die "下载失败: $PKG_URL"
    # 完整性：对published .sha256 校验（供应链门；二进制以 root 运行）。缺 sidecar 仅警告。
    if fetch "${PKG_URL}.sha256" "${tmp}/pkg.sha256" 2>/dev/null; then
      local want got
      want="$(awk '{print $1}' "${tmp}/pkg.sha256" 2>/dev/null)"
      got="$(sha256sum "${tmp}/pkg.tar.gz" 2>/dev/null | awk '{print $1}')"
      [ -n "$want" ] && [ "$want" = "$got" ] || die "校验和不符 (want=${want:-?} got=${got:-?}) — 拒绝安装"
      print_info "校验和 OK" >&2
    else
      print_warn "无 published .sha256 — 跳过完整性校验" >&2
    fi
  fi
  tar -xzf "${tmp}/pkg.tar.gz" -C "$tmp" || die "解压失败"
  local pkg="${tmp}/ff1master-linux-${ARCH}"
  [ -x "${pkg}/ff1-master" ] || die "包结构错误: 缺 ${pkg}/ff1-master"
  echo "$pkg"
}

# swap_binary <pkg_dir>：原子替换 binary + dl/ + ff1-migrate-v1，保留上一个作 .bak 回滚。
swap_binary() {
  local pkg="$1"
  mkdir -p "$MASTER_DIR/dl"
  [ -f "${MASTER_DIR}/ff1-master" ] && cp -f "${MASTER_DIR}/ff1-master" "${MASTER_DIR}/ff1-master.bak"
  install -m 0755 "${pkg}/ff1-master" "${MASTER_DIR}/ff1-master.new"
  mv -f "${MASTER_DIR}/ff1-master.new" "${MASTER_DIR}/ff1-master"   # 原子覆盖运行中的二进制
  ln -sf "${MASTER_DIR}/ff1-master" /usr/local/bin/ff1-master
  [ -d "${pkg}/dl" ] && cp -Rf "${pkg}/dl/." "${MASTER_DIR}/dl/" 2>/dev/null || true
  # 迁移工具随包分发（v1→v2 用），有则装上
  [ -f "${pkg}/ff1-migrate-v1" ] && install -m 0755 "${pkg}/ff1-migrate-v1" "$MIGRATE_BIN" 2>/dev/null || true
  # 存一份本安装脚本 + 示例配置，供 `ff1` 菜单与自升级复用。经 `curl | bash` 安装时 $0 是
  # "bash"（不是文件），cp 会失败 → 改为:$0 是可读文件就 cp,否则从发布仓拉回规范脚本。
  if [ -r "$0" ] && [ -f "$0" ]; then
    cp -f "$0" "$SELF_COPY" 2>/dev/null || true
  else
    # raw 优先，被 GitHub 限流(429)就走 jsDelivr CDN 兜底。
    fetch "https://raw.githubusercontent.com/${REPO}/main/scripts/ff1-master-install.sh" "$SELF_COPY" 2>/dev/null \
      || fetch "https://cdn.jsdelivr.net/gh/${REPO}@main/scripts/ff1-master-install.sh" "$SELF_COPY" 2>/dev/null || true
  fi
  chmod +x "$SELF_COPY" 2>/dev/null || true
  [ -f "${pkg}/configs/master.example.yaml" ] && cp -f "${pkg}/configs/master.example.yaml" "${ETC}/master.example.yaml" || true
}
master_rollback() { [ -f "${MASTER_DIR}/ff1-master.bak" ] && mv -f "${MASTER_DIR}/ff1-master.bak" "${MASTER_DIR}/ff1-master"; }

# healthy：要求服务在 settle 窗口内持续 active（Type=simple fork 即报 active，秒崩会漏）。
healthy() { local i; for i in $(seq 1 8); do sleep 1; systemctl is-active --quiet ff1-master || return 1; done; return 0; }

# 装/升级前先清掉**非 systemd 拉起的残留 master 野进程**：它们占着面板端口、开着老的 state.db，
# 会让新写入的账号在登录时“看不到”（表现为账号密码明明对却报 invalid）。
# 精确匹配「<安装目录>/ff1-master 」带全路径+尾空格 → 绝不会误伤本安装脚本 ff1-master-install.sh。
kill_stale_master() {
  systemctl stop ff1-master 2>/dev/null || true
  local pids; pids="$(pgrep -f "${MASTER_DIR}/ff1-master " 2>/dev/null || true)"
  [ -n "$pids" ] && { print_warn "清理残留 master 野进程: $(echo "$pids" | tr '\n' ' ')"; kill -9 $pids 2>/dev/null || true; sleep 1; }
  return 0
}

# 装完自检：**在本机直连 master 登录一次**，当场确认后端认这对账号密码（绕开浏览器/域名/前端/证书）。
# 成功 → 打印 ✅；失败 → 把后端原始响应打出来，便于一眼定位（而不是让用户去浏览器盲试）。
verify_login() {
  local user="$1" pass="$2" port body payload url
  port="$(grep -E '^http_addr:' "$CONFIG" 2>/dev/null | sed 's/.*://; s/"//g' | tr -d ' ')"
  [ -n "$port" ] || { print_warn "无法解析端口，跳过登录自检"; return 0; }
  payload="{\"username\":\"${user}\",\"password\":\"${pass}\"}"
  url="http://127.0.0.1:${port}/api/auth/login"
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS --max-time 10 -X POST "$url" -d "$payload" 2>/dev/null)"
  else
    body="$(wget -q -O - --post-data="$payload" "$url" 2>/dev/null)"
  fi
  case "$body" in
    *'"token"'*) print_success "登录自检通过 ✅（后端已接受该账号密码，浏览器登录即可）"; return 0 ;;
    *) print_warn "登录自检未通过 —— 后端原始响应: ${body:-<空/连接失败>}"; return 1 ;;
  esac
}

write_unit() {
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
}

install_ff1_cli() {
  cat >"$FF1_CLI" <<EOF
#!/usr/bin/env bash
# FF1 管理菜单入口（由 ff1-master-install.sh 生成）
exec bash "${SELF_COPY}" "\$@"
EOF
  chmod +x "$FF1_CLI"
}

# 检测本机 IPv4：合并 ip-addr + hostname -I 两个来源后**去重**（否则同一 IP 会列多遍），
# 排除回环/链路本地/Docker 私网。
server_ips() {
  { ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}'
    hostname -I 2>/dev/null | tr ' ' '\n'; } \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | grep -vE '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | sort -u
}

# gen_pw / gen_user：随机 14 位密码 + 随机 6 位用户名（老版 FF1 都是自动生成 + 展示）。
gen_pw()   { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 14; echo; }
gen_user() { printf 'a'; LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 5; echo; }

show_entry() {
  local port url
  url="$(grep -E '^public_url:' "$CONFIG" 2>/dev/null | sed 's/^public_url:[[:space:]]*//; s/"//g')"
  port="$(grep -E '^http_addr:' "$CONFIG" 2>/dev/null | sed 's/.*://; s/"//g' | tr -d ' ')"
  echo; echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"
  echo "  FF1 Master 管理入口"
  echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"; echo
  print_info "配置面板访问地址（请使用授权域名访问）："
  echo "———————————————————————————————————"
  [ -n "$url" ] && echo -e "  ${GREEN}public_url${NC}: ${url}"
  # 其它检测到的本机地址（去掉与 public_url 重复的那条）
  local ip a
  for ip in $(server_ips); do
    a="http://${ip}:${port:-8443}"
    [ "$a" = "$url" ] && continue
    echo "  $a"
  done
  echo "———————————————————————————————————"
  print_info "管理员：见首次安装输出 / journalctl -u ff1-master | grep -i password"
  echo
}

# ---------- 全新安装 ----------
do_fresh_install() {
  preflight
  banner
  print_info "全新安装 FF1 Master（${ARCH}）"
  # 老版 FF1 流程：只问端口，其余全自动。public_url 自动用检测到的 IP:端口（NAT/域名场景在
  # 面板或 ${CONFIG} 里改）；管理员密码自动随机生成并在装完显示（FF1_ADMIN_PASSWORD 可覆盖）。
  local PORT PUBURL ADMPW ADMUSER LICENSE_KEY defip
  while :; do
    read -r -p "$(echo -e "${GREEN}?${NC} 管理后台端口 [8443]: ")" PORT; PORT="${PORT:-8443}"
    case "$PORT" in ''|*[!0-9]*) print_warn "端口必须是数字" ;; *) [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break; print_warn "端口范围 1-65535" ;; esac
  done
  # License：装机可填 v2 授权码（留空=装完在面板→授权中心填）。老版 FF1 也是装机问。
  read -r -p "$(echo -e "${GREEN}?${NC} FF1 授权码 License（留空则装完在面板填）: ")" LICENSE_KEY
  case "$LICENSE_KEY" in *[\"\\]*) print_warn "授权码含非法字符,已忽略"; LICENSE_KEY="" ;; esac
  defip="$(server_ips | head -1)"; defip="${defip:-127.0.0.1}"
  PUBURL="${FF1_PUBLIC_URL:-http://${defip}:${PORT}}"
  ADMUSER="${FF1_ADMIN_USERNAME:-$(gen_user)}"   # 随机 6 位用户名（老版 FF1 也是随机）
  ADMPW="${FF1_ADMIN_PASSWORD:-$(gen_pw)}"

  mkdir -p "$MASTER_DIR/dl" "$ETC" "$DATA_DIR"
  local pkg; pkg="$(fetch_package)" || die "取包/校验失败（见上）"; [ -n "$pkg" ] || die "取包失败：包目录为空"
  swap_binary "$pkg"

  if [ ! -f "$CONFIG" ]; then
    local SECRET; SECRET="$(head -c 32 /dev/urandom | base64)"
    cat >"$CONFIG" <<EOF
http_addr: "0.0.0.0:${PORT}"
data_dir: "${DATA_DIR}"
public_url: "${PUBURL}"
log_level: "none"
dev: false
secret_key: "${SECRET}"
license_key: "${LICENSE_KEY}"
admin:
  username: "${ADMUSER}"
  password: "${ADMPW}"
trust_proxy: true
EOF
    chmod 0600 "$CONFIG"
    print_success "已生成 ${CONFIG}"
  else
    # 复用已有配置的管理员凭据（显示与实际一致，不再用新生成的假凭据）
    local eu ep
    eu="$(grep -E '^[[:space:]]+username:' "$CONFIG" | head -1 | sed 's/.*username:[[:space:]]*//; s/"//g')"
    ep="$(grep -E '^[[:space:]]+password:' "$CONFIG" | head -1 | sed 's/.*password:[[:space:]]*//; s/"//g')"
    [ -n "$eu" ] && ADMUSER="$eu"; [ -n "$ep" ] && ADMPW="$ep"
    print_info "复用已有配置 ${CONFIG}"
  fi

  write_unit; install_ff1_cli
  kill_stale_master   # 清掉残留野进程，保证 -u/-p 写入的库与服务读取的是同一个
  # 先用 -u/-p 建库 + 建/改管理员（保证显示的凭据一定能登，绕开"库非空则不 bootstrap"坑），
  # 再起服务（服务见 admin 已存在就不再 bootstrap；旧版二进制无 -u/-p 时回退到服务 bootstrap）。
  "${MASTER_DIR}/ff1-master" --config "$CONFIG" -u "$ADMUSER" -p "$ADMPW" >/dev/null 2>&1 \
    || print_warn "预设管理员未生效（可能是旧版二进制）—— 将由服务按配置 bootstrap"
  systemctl daemon-reload
  systemctl enable ff1-master >/dev/null 2>&1 || true
  systemctl restart ff1-master.service
  if healthy; then
    print_success "安装完成，服务已启动"
    echo
    echo -e "  ${GREEN}管理员${NC}  用户名: ${YELLOW}${ADMUSER}${NC}   密码: ${YELLOW}${ADMPW}${NC}"
    echo -e "  ${RED}请务必记录以上凭据${NC}（写在 ${CONFIG}；改密见菜单或 ff1-master -u <用户> -p <新密码>）"
    [ -n "$LICENSE_KEY" ] && print_info "授权码已写入配置，首启会自动种入（面板→授权中心可查/换）" \
                          || print_warn "未填授权码 → 请在面板 设置→授权中心 填 v2 授权码（否则面板会锁）"
    verify_login "$ADMUSER" "$ADMPW"
    show_entry
    print_info "以后运行 ${GREEN}ff1${NC} 打开本菜单。"
  else
    print_error "master 未能稳定启动 — 查: journalctl -u ff1-master"; return 1
  fi
}

# ---------- v2 就地升级（换 binary + dl/，保留 config/data）----------
update_v2() {
  preflight
  [ -x "${MASTER_DIR}/ff1-master" ] || die "未安装（无 ${MASTER_DIR}/ff1-master）；请先全新安装"
  print_info "升级 FF1 Master（binary + dl/，保留 config/data）"
  local pkg; pkg="$(fetch_package)" || die "取包/校验失败（见上）"; [ -n "$pkg" ] || die "取包失败：包目录为空"
  swap_binary "$pkg"
  kill_stale_master   # 换二进制后清残留野进程，避免旧进程占端口/开着旧库
  systemctl daemon-reload
  systemctl restart ff1-master.service
  if healthy; then
    print_success "升级完成，已重启（保留 ff1-master.bak 作回滚点）"; return 0
  fi
  print_warn "新版未稳定，回滚中…"; master_rollback
  systemctl restart ff1-master.service || true
  die "已回滚到上一版 — 查: journalctl -u ff1-master"
}

# ---------- 从旧版 ff1panel 迁移（v1 → v2，自动迁数据）----------
migrate_from_v1() {
  preflight
  banner
  print_warn "检测到老版 FF1 Panel（ff1panel/ff1master）安装。"
  print_info "将：停旧服务 → 备份旧库 → 安装新 FF1 → 用迁移工具把节点/规则/用户/设置迁入新库。"
  echo -en "${YELLOW}继续从旧版迁移升级? [y/N]: ${NC}"; local c; read -r c
  [[ "$c" =~ ^[Yy]$ ]] || { print_warn "已取消"; return 0; }

  # 定位旧库
  local v1db=""
  for cand in "${V1_DIR}/data/master.db" "${V1_DIR}/master.db" /etc/ff1/ff1master/data/master.db; do
    [ -f "$cand" ] && { v1db="$cand"; break; }
  done
  [ -n "$v1db" ] || die "未找到旧版数据库（找过 ${V1_DIR}/data/master.db 等）"
  print_info "旧库: $v1db"

  # 停旧服务
  systemctl stop "$V1_SERVICE" 2>/dev/null || true
  pkill -9 -f ff1master 2>/dev/null || true

  # 备份旧库
  mkdir -p "$BACKUP_DIR"
  local snap="${BACKUP_DIR}/v1-master-$(date +%Y%m%d-%H%M%S).db.gz"
  # 备份必须成功才继续（磁盘满/权限问题就此中止,旧库/服务尚未动）
  gzip -c "$v1db" > "$snap" || die "旧库备份失败（$snap）—— 已中止，未改动任何东西"
  print_success "旧库已备份: $snap"

  # 装新 FF1（如尚未装）
  mkdir -p "$MASTER_DIR/dl" "$ETC" "$DATA_DIR"
  local pkg; pkg="$(fetch_package)" || die "取包/校验失败（见上）"; [ -n "$pkg" ] || die "取包失败：包目录为空"; swap_binary "$pkg"
  [ -x "$MIGRATE_BIN" ] || die "迁移工具缺失（${MIGRATE_BIN}）；请用含 ff1-migrate-v1 的新版包"

  # 生成新配置（若无）
  if [ ! -f "$CONFIG" ]; then
    local SECRET defip; SECRET="$(head -c 32 /dev/urandom | base64)"; defip="$(server_ips | head -1)"; defip="${defip:-127.0.0.1}"
    cat >"$CONFIG" <<EOF
http_addr: "0.0.0.0:8443"
data_dir: "${DATA_DIR}"
public_url: "http://${defip}:8443"
log_level: "info"
dev: false
secret_key: "${SECRET}"
admin:
  username: "admin"
  password: ""
trust_proxy: true
EOF
    chmod 0600 "$CONFIG"
  fi

  # 迁移工具**自己用 FF1 migrations 建新 schema 再灌数据**（新库该有什么全由转换决定，
  # master 不先启动、不 bootstrap admin —— 新的不动，只把旧的转过来）。
  print_info "迁移数据 v1 → v2 …"
  # 传本机 secret_key，让 2FA/SSH 密文按新 master 的编码封装（否则 2FA 会被丢弃需重绑）
  local SEC; SEC="$(grep -E '^secret_key:' "$CONFIG" 2>/dev/null | sed 's/^secret_key:[[:space:]]*//; s/"//g')"
  if "$MIGRATE_BIN" --old "$v1db" --new "${DATA_DIR}/state.db" --secret "$SEC"; then
    print_success "数据迁移完成"
  else
    print_error "迁移失败（旧库只读未动、已备份 $snap）"
    print_info "可修正后重试: ${MIGRATE_BIN} --old $v1db --new ${DATA_DIR}/state.db --secret <key>"
    return 1
  fi

  # 起服务（master 见迁入的用户已存在 → 不再 bootstrap 额外 admin）
  write_unit; install_ff1_cli; kill_stale_master; systemctl daemon-reload
  systemctl enable ff1-master >/dev/null 2>&1 || true
  systemctl restart ff1-master.service
  if healthy; then
    print_success "从旧版升级完成，新 FF1 已启动。旧库保留在 $v1db（确认无误后可自行删除）。"
    show_entry
  else
    die "迁移后 master 未稳定 — 查: journalctl -u ff1-master"
  fi
}

# ---------- 「升级」菜单：自动识别 v1 / v2 / partial ----------
do_upgrade() {
  preflight
  case "$(detect_install_version)" in
    v2)      update_v2 ;;
    v1)      migrate_from_v1 ;;
    partial) print_warn "检测到半装状态，按全新安装续装…"; do_fresh_install ;;
    *)       print_error "未检测到可升级的安装"; print_info "空机器请选「全新安装」。" ;;
  esac
}

do_uninstall() {
  echo -en "${YELLOW}确认卸载 FF1 Master?（保留 ${ETC} 配置与数据）[y/N]: ${NC}"; local c; read -r c
  [[ "$c" =~ ^[Yy]$ ]] || { print_warn "已取消卸载"; return 0; }
  systemctl disable --now ff1-master 2>/dev/null || true
  # ⚠ 只杀 daemon（/opt/ff1/ff1-master ...），别用裸 'ff1-master' —— 那会匹配到正在跑本脚本的
  # `bash /etc/ff1/ff1-master-install.sh` 把自己 SIGKILL 掉,卸载做一半。disable --now 已停服。
  pkill -9 -f "${MASTER_DIR}/ff1-master " 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  rm -rf "$MASTER_DIR"; rm -f "$FF1_CLI" /usr/local/bin/ff1-master   # 含 swap_binary 建的软链
  print_success "FF1 Master 已卸载；${ETC}（配置 / state.db）保留 — 需彻底清除请手动 rm -rf ${ETC}"
}

save_db() {
  local db="${DATA_DIR}/state.db"
  [ -f "$db" ] || { print_error "数据库不存在: $db"; return 1; }
  mkdir -p "$BACKUP_DIR"
  local out="${BACKUP_DIR}/state-$(date +%Y%m%d-%H%M%S).db.gz"
  gzip -c "$db" > "$out" && print_success "已备份: $out"
}

show_help() {
  print_info "FF1 Master 运维"
  echo "  systemctl start|stop|restart|status ff1-master"
  echo "  journalctl -u ff1-master -f"
  echo "  配置: ${CONFIG}"
  echo "  数据: ${DATA_DIR}/state.db"
  echo
  print_info "全局命令："
  echo "  ff1                     - 打开本管理菜单"
  echo "  bash $SELF_COPY -upgrade    - 非交互升级（面板「Master 升级」也走它）"
  echo
  print_info "修改管理员密码（命令行）："
  echo "  ${MASTER_DIR}/ff1-master --config ${CONFIG} -u <用户名> -p <新密码>   # 无需重启,立即生效"
  echo
  print_info "菜单「升级」自动识别："
  echo "  v2（当前 FF1） → 下新包、换 binary+dl/、重启"
  echo "  v1（老 ff1panel） → 停旧服务、备份旧库、装新 FF1、迁数据"
}

# 修改/新增管理员凭据（走 ff1-master -u/-p，直接改 DB，无需重启）。
change_admin_password() {
  [ -x "${MASTER_DIR}/ff1-master" ] || { print_error "未安装 FF1 Master"; return 1; }
  local u p
  read -r -p "$(echo -e "${GREEN}?${NC} 管理员用户名 [admin]: ")" u; u="${u:-admin}"
  read -r -s -p "$(echo -e "${GREEN}?${NC} 新密码: ")" p; echo
  [ -n "$p" ] || { print_warn "密码不能为空"; return 1; }
  if "${MASTER_DIR}/ff1-master" --config "$CONFIG" -u "$u" -p "$p"; then
    print_success "已更新管理员「$u」的密码（立即生效，无需重启）。"
  else
    print_error "改密失败 — 查: journalctl -u ff1-master"; return 1
  fi
}

# 自更新本管理菜单脚本（raw 优先，429 走 jsDelivr）。
update_menu_script() {
  print_info "更新管理菜单脚本…"
  if fetch "https://raw.githubusercontent.com/${REPO}/main/scripts/ff1-master-install.sh" "${SELF_COPY}.new" 2>/dev/null \
     || fetch "https://cdn.jsdelivr.net/gh/${REPO}@main/scripts/ff1-master-install.sh" "${SELF_COPY}.new" 2>/dev/null; then
    mv -f "${SELF_COPY}.new" "$SELF_COPY"; chmod +x "$SELF_COPY"
    print_success "菜单已更新，重新运行 ff1 生效。"
  else
    rm -f "${SELF_COPY}.new"; print_error "下载失败（raw / jsDelivr 都不通）"; return 1
  fi
}

# ---------- 交互菜单（对齐老版 show_menu 布局）----------
menu() {
  while true; do
    clear; banner; echo
    echo -e "${GREEN}1.${NC}  全新安装 FF1 Master"
    echo -e "${GREEN}2.${NC}  卸载 FF1 Master"
    echo -e "${YELLOW}———————————————————————————————————${NC}"
    echo -e "${GREEN}3.${NC}  升级 FF1 Master（当前版换程序 / 旧版迁数据）"
    echo -e "${YELLOW}———————————————————————————————————${NC}"
    echo -e "${GREEN}4.${NC}  重启 FF1 Master"
    echo -e "${GREEN}5.${NC}  停止 FF1 Master"
    echo -e "${YELLOW}———————————————————————————————————${NC}"
    echo -e "${GREEN}6.${NC}  查看日志"
    echo -e "${GREEN}7.${NC}  保存数据库"
    echo -e "${YELLOW}———————————————————————————————————${NC}"
    echo -e "${GREEN}8.${NC}  帮助"
    echo -e "${GREEN}9.${NC}  查看管理入口"
    echo -e "${GREEN}10.${NC} 修改管理员密码"
    echo -e "${GREEN}00.${NC} 更新管理菜单"
    echo -e "${YELLOW}———————————————————————————————————${NC}"
    echo -e "${RED}0.${NC}  退出"
    echo -e "${BLUE}▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃${NC}"; echo
    local choice; read -r -p "$(echo -e "${GREEN}请选择操作 [0-10, 00]: ${NC}")" choice
    # 动作放子 shell 里跑：里面的 die/exit 只结束子 shell，菜单不会被带崩。
    case "$choice" in
      1) ( do_fresh_install ) ;;
      2) ( do_uninstall ) ;;
      3) ( do_upgrade ) ;;
      4) systemctl restart ff1-master && print_success "已重启" ;;
      5) systemctl stop ff1-master && print_success "已停止" ;;
      6) journalctl -u ff1-master -f ;;
      7) save_db ;;
      8) show_help ;;
      9) show_entry ;;
      10) ( change_admin_password ) ;;
      00) ( update_menu_script ) ;;
      0) print_info "退出"; break ;;
      *) print_error "无效选择，请重新输入" ;;
    esac
    echo; read -r -p "$(echo -e "${YELLOW}按回车键继续...${NC}")" _
  done
}

# ---------- 入口：非交互 flag 或 交互菜单 ----------
main() {
  local action=""
  for a in "$@"; do case "$a" in
    -install|--install) action=install ;;
    -upgrade|--upgrade) action=upgrade ;;
    -uninstall|--uninstall) action=uninstall ;;
    -restart|--restart) action=restart ;;
  esac; done

  case "$action" in
    install)   do_fresh_install ;;
    upgrade)   do_upgrade ;;            # 面板「Master 升级」走这条（v2 就地升级 / v1 迁移）
    uninstall) need_cmd systemctl; do_uninstall ;;   # 卸载不需要 curl/tar，别 gate 在 preflight
    restart)   systemctl restart ff1-master && print_success "已重启" ;;
    "")        # 无参 → 交互菜单。经 `curl | bash` 时 stdin 绑在管道上，read 会立刻 EOF →
               # 死循环「无效选择」。把 stdin 接回控制终端；接不上就提示改用 flag。
               if [ ! -t 0 ]; then
                 if [ -e /dev/tty ]; then exec </dev/tty
                 else die "无交互终端；请用: bash $0 -install|-upgrade|-uninstall|-restart"; fi
               fi
               menu ;;
  esac
}
main "$@"
