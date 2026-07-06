# ff1-publication — FF1 安装脚本发布仓

> 由 FF1 源码 `./scripts/publish-github.sh scripts` 同步到 GitHub，请勿手改 `scripts/`。
> 本仓库**只放构建产物**（安装脚本 + Release 二进制），不含源码。

## 仓库

**GitHub**：`https://github.com/catxtom/ff1-publication`

- 脚本 raw：`.../raw/main/scripts/install.sh`（节点 agent）、`.../scripts/ff1-master-install.sh`（Master）
- Release：`agent-latest` / `master-latest`（rolling）+ `agent-{版本}` / `master-{版本}`

---

> **取脚本地址**：raw 优先；GitHub 对 raw 有按 IP 的匿名限流(429)，被限就走 jsDelivr CDN 兜底
> `https://cdn.jsdelivr.net/gh/catxtom/ff1-publication@main/scripts/...`。二进制走 Release 下载，不受此限流。

## 在线安装节点 agent（ff1core）

```bash
{ curl -fsSL https://raw.githubusercontent.com/catxtom/ff1-publication/main/scripts/install.sh \
  || curl -fsSL https://cdn.jsdelivr.net/gh/catxtom/ff1-publication@main/scripts/install.sh; } \
  | sh -s -- --master <MASTER_URL> --token <TOKEN> --channel github
```

- 全静态二进制（ff1core 内嵌 realm + nginx），POSIX `/bin/sh`，systemd / OpenRC 均支持。
- `--channel github`：从本发布仓的 `agent-latest` 拉 `ff1core-linux-<arch>`。
- 卸载：`... | sh -s -- --uninstall`

## 在线安装 / 管理 Master（交互菜单）

```bash
bash <(curl -fLSs https://raw.githubusercontent.com/catxtom/ff1-publication/main/scripts/ff1-master-install.sh \
     || curl -fLSs https://cdn.jsdelivr.net/gh/catxtom/ff1-publication@main/scripts/ff1-master-install.sh)
```

Master 包（`ff1master-linux-<arch>-latest.tar.gz`）见 `master-latest` Release，内嵌前端 SPA +
`dl/`（随包 ff1core，供 SSH 装机渠道）+ `ff1-migrate-v1`（老 ff1panel→新 FF1 迁移工具）。
