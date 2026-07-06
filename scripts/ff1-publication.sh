#!/usr/bin/env bash
# ff1-publication.sh — FF1 发布仓公共库（GitHub raw + GitHub Releases）
#
# 1:1 对应 xctl 的 scripts/lib/xctl-publication.sh。所有发版资源（在线安装脚本 raw、
# ff1core / ff1-master Release 二进制）都走 GitHub 发布仓 catxtom/ff1-publication。
#
# 渠道（asset ↔ tag）：
#   agent  : ff1core-linux-{arch}(.sha256)          rolling=agent-latest  versioned=agent-{VERSION}
#   master : ff1master-linux-{arch}-latest.tar.gz    rolling=master-latest versioned=master-{VERSION}
#   scripts: raw.githubusercontent.com/<repo>/<ref>/scripts/install.sh（在线一键安装）

_ff1_pub_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
if [[ -n "$_ff1_pub_root" && -f "${_ff1_pub_root}/.env.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${_ff1_pub_root}/.env.local"
  set +a
fi
unset _ff1_pub_root

: "${FF1_PUBLICATION_REPO:=catxtom/ff1-publication}"
: "${GITHUB_REPO:=${FF1_PUBLICATION_REPO}}"
: "${FF1_PUBLICATION_PROBE_TIMEOUT:=5}"

MASTER_ROLLING_TAG="${MASTER_ROLLING_TAG:-master-latest}"
AGENT_ROLLING_TAG="${AGENT_ROLLING_TAG:-agent-latest}"

: "${FF1_SCRIPTS_REF:=main}"

# publication_resolve_version：空 / 「#」（zsh 行内注释误传）→ UTC 时间戳；非法字符失败。
publication_resolve_version() {
  local ver="${1:-}"
  ver="${ver#"${ver%%[![:space:]]*}"}"
  ver="${ver%"${ver##*[![:space:]]}"}"

  if [[ -z "$ver" || "$ver" == "#" || "$ver" == "#"* ]]; then
    if [[ -n "$ver" ]]; then
      echo "WARN: 忽略疑似 shell 注释参数 version=${ver}（zsh 默认不把行内 # 当注释）" >&2
    fi
    ver="$(date -u +%Y%m%d%H%M%S)"
    echo "==> 使用 UTC 时间戳 version: ${ver}" >&2
  fi

  if [[ ! "$ver" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    cat >&2 <<EOF
ERROR: 非法 version: ${ver}
  仅允许字母、数字及 . _ -，且不能以符号开头。
  示例: $0 all 20260630120000
EOF
    return 1
  fi
  printf '%s' "$ver"
}

publication_scripts_raw_base() {
  if [[ -n "${FF1_SCRIPTS_RAW_BASE:-}" ]]; then
    echo "${FF1_SCRIPTS_RAW_BASE%/}"
    return 0
  fi
  echo "https://raw.githubusercontent.com/${GITHUB_REPO}/${FF1_SCRIPTS_REF}/scripts"
}

publication_scripts_source_label() { echo "GitHub (${GITHUB_REPO})"; }

gh_release_download_url() { echo "https://github.com/${GITHUB_REPO}/releases/download/${1}/${2}"; }
publication_release_download_url() { gh_release_download_url "$1" "$2"; }

master_package_url() {
  local arch=$1 tag=${2:-$MASTER_ROLLING_TAG}
  publication_release_download_url "$tag" "ff1master-linux-${arch}-latest.tar.gz"
}
agent_binary_url() {
  local arch=$1 tag=${2:-$AGENT_ROLLING_TAG}
  publication_release_download_url "$tag" "ff1core-linux-${arch}"
}
agent_sha256_url() {
  local arch=$1 tag=${2:-$AGENT_ROLLING_TAG}
  publication_release_download_url "$tag" "ff1core-linux-${arch}.sha256"
}

# 在线安装脚本（GitHub raw）+ 一键命令（供发版后打印/控制台展示）。
online_install_script_url() { echo "$(publication_scripts_raw_base)/install.sh"; }
online_install_curl_pipe() {
  # <master> / <token> 由调用者替换；--channel github 强制从 GitHub 拉 agent 二进制。
  echo "curl -fsSL $(online_install_script_url) | sudo sh -s -- --master <MASTER_URL> --token <TOKEN> --channel github"
}

publication_print_github_release_urls() {
  echo ""
  echo "==> GitHub Release"
  echo "    https://github.com/${GITHUB_REPO}/releases/tag/${1}"
}

# ---- Release 发版：本机构建物直传 GitHub ----

publication_release_upload_rolling() {
  local rolling_tag=$1 title=$2; shift 2
  gh_publication_repo_preflight
  echo "==> GitHub rolling release ${rolling_tag}"
  gh_release_upload_rolling "$rolling_tag" "$title" "$@"
  publication_print_github_release_urls "$rolling_tag"
}

publication_release_upload_versioned() {
  local tag=$1 title=$2 notes=$3; shift 3
  gh_publication_repo_preflight
  echo "==> GitHub 版本 release ${tag}"
  gh_release_upload_versioned "$tag" "$title" "$notes" "$@"
  publication_print_github_release_urls "$tag"
}

# GitHub Release 要求默认分支至少有一个 commit（空仓库会 422 Repository is empty）。
gh_publication_repo_preflight() {
  command -v gh >/dev/null || { echo "需要 GitHub CLI: https://cli.github.com/" >&2; exit 1; }
  local is_empty
  if ! is_empty="$(gh repo view "$GITHUB_REPO" --json isEmpty -q .isEmpty 2>&1)"; then
    echo "ERROR: 无法访问 GitHub 仓库 ${GITHUB_REPO}" >&2
    echo "$is_empty" >&2
    echo "请确认仓库已创建且 gh auth login 有权限。" >&2
    exit 1
  fi
  if [[ "$is_empty" == "true" ]]; then
    cat >&2 <<EOF
ERROR: ${GITHUB_REPO} 仍是空仓库，无法创建 Release（HTTP 422 Repository is empty）。
先在默认分支 push 至少一个 commit：
  git init && echo "# ff1-publication" > README.md && git add README.md \\
    && git commit -m "chore: init" && git branch -M main \\
    && git remote add origin https://github.com/${GITHUB_REPO}.git && git push -u origin main
EOF
    exit 1
  fi
}

gh_release_upload_assets() {
  local tag=$1; shift
  local assets=("$@") total=${#assets[@]} i=0 f size
  for f in "${assets[@]}"; do
    i=$((i + 1)); size="$(du -h "$f" | awk '{print $1}')"
    echo "    [${i}/${total}] 上传 $(basename "$f") (${size})…"
    gh release upload "$tag" "$f" --repo "$GITHUB_REPO" --clobber
  done
}

gh_release_delete_if_exists() {
  local tag=$1
  gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1 || return 0
  echo "==> 删除旧 release ${tag}（重建 rolling，避免无 git tag 导致下载 404）"
  gh release delete "$tag" --repo "$GITHUB_REPO" --yes
}

gh_git_tag_exists() { gh api -q .object.sha "repos/${GITHUB_REPO}/git/ref/tags/${1}" >/dev/null 2>&1; }
gh_git_tag_delete_if_exists() {
  gh_git_tag_exists "$1" || return 0
  echo "==> 删除孤儿 git tag ${1}（仅有 tag、无可用 release）"
  gh api -X DELETE "repos/${GITHUB_REPO}/git/refs/tags/${1}" >/dev/null
}
gh_resolve_commitish_sha() {
  local ref=$1 sha
  sha="$(gh api "repos/${GITHUB_REPO}/git/refs/heads/${ref}" -q .object.sha 2>/dev/null)" && { echo "$sha"; return 0; }
  sha="$(gh api "repos/${GITHUB_REPO}/commits/${ref}" -q .sha 2>/dev/null)" && { echo "$sha"; return 0; }
  return 1
}
# releases/download/<tag>/<asset> 依赖底层 git tag 存在；tag 缺失匿名下载会 404 → 补建。
gh_release_ensure_tag() {
  local tag=$1 target=$2 sha
  gh_git_tag_exists "$tag" && return 0
  echo "==> git tag ${tag} 缺失，按 target=${target} 补建（否则 releases/download 会 404）"
  if ! sha="$(gh_resolve_commitish_sha "$target")" || [[ -z "$sha" ]]; then
    echo "WARN: 无法解析 ${target} 的 commit，git tag ${tag} 未补建 → 下载可能 404" >&2
    return 0
  fi
  gh api -X POST "repos/${GITHUB_REPO}/git/refs" -f "ref=refs/tags/${tag}" -f "sha=${sha}" >/dev/null 2>&1 \
    || echo "WARN: 补建 git tag ${tag} 失败" >&2
}

gh_release_upload_rolling() {
  local rolling_tag=$1 title=$2; shift 2
  local assets=("$@") target="${FF1_SCRIPTS_REF:-main}"
  gh_release_delete_if_exists "$rolling_tag"
  echo "==> 创建 rolling release ${rolling_tag}（target=${target}，上传 ${#assets[@]} 个文件）"
  gh release create "$rolling_tag" --repo "$GITHUB_REPO" --target "$target" --title "$title" \
    --notes "Rolling 渠道；装机脚本默认拉取此 tag 下资源。"
  gh_release_ensure_tag "$rolling_tag" "$target"
  gh_release_upload_assets "$rolling_tag" "${assets[@]}"
  gh_release_verify_downloadable "$rolling_tag" "$(basename "${assets[0]}")"
}

gh_release_verify_downloadable() {
  local url; url="https://github.com/${GITHUB_REPO}/releases/download/${1}/${2}"
  if curl -fsSL --range 0-0 "$url" -o /dev/null 2>/dev/null; then
    echo "==> 下载自检通过（匿名可拉取）：${2}"
  else
    echo "WARN: 下载自检失败(可能 404) → ${url}" >&2
  fi
}

gh_release_upload_versioned() {
  local tag=$1 title=$2 notes=$3; shift 3
  local assets=("$@")
  if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    echo "WARN: release ${tag} 已存在，跳过版本 tag（rolling 已更新）" >&2
    return 0
  fi
  gh_git_tag_delete_if_exists "$tag"
  echo "==> 创建版本 release ${tag}（上传 ${#assets[@]} 个文件）"
  gh release create "$tag" --repo "$GITHUB_REPO" --title "$title" --notes "$notes" \
    || { echo "WARN: 版本 release ${tag} 创建失败（rolling 已更新）" >&2; return 0; }
  gh_release_upload_assets "$tag" "${assets[@]}" \
    || { echo "WARN: 版本 release ${tag} 资源上传失败（rolling 已更新）" >&2; return 0; }
}
