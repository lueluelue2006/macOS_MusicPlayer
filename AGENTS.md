# Codex 工作约定（重要）

## 版本号递增规则（默认，除非用户特别说明）

- **小更新**：版本号 `+0.0.1`。
  - 例如：`3.7 -> 3.7.1`，`3.7.1 -> 3.7.2`。
- **大更新**：版本号 `+0.1`。
  - 例如：`3.7 -> 3.8`，`3.7.5 -> 3.8`。
- 若用户明确指定版本号（例如“直接发 4.0”），以用户要求为准。

## Git 工作流（默认强制）

- 每次有效修改都要走 Git：至少 1 个原子提交（commit）。
- 提交前先做必要验证（至少编译通过或最小可复现验证通过）。
- 默认提交后推送到 `origin/main`；除非用户明确要求“先不推送”。
- 仅排查性质、未形成最终修改的临时改动可不提交；一旦形成最终改动，必须提交。

## GitHub Releases 维护规则（强制）

### 1) 每次发版都要上传 Release

- 不仅 `x.y`，**`x.y.z` 小版本也必须上传到 GitHub Releases**。
- 每次发布都必须包含可下载资产，不允许只发 tag/源码压缩包。

### 2) Release 资产要求（强制双架构）

每个 Release 必须上传以下文件：

- `MusicPlayer-vX.Y(.Z).dmg`（Apple Silicon / M 系列）
- `MusicPlayer-vX.Y(.Z)-intel.dmg`（Intel）
- `SHA256SUMS.txt`（至少包含上面两个 DMG 的 sha256）

### 3) Releases 页面保留策略

为避免页面被 patch 版本刷屏：

- **中版本（x.y）**：全部保留（例如 `v3.5`、`v3.6`、`v3.7`）。
- **小版本（x.y.z）**：全仓库页面上**只保留最新的 1 个**。
  - 例如：发布 `v1.2.5` 后，应删除页面上旧的 `v1.2.4 / v1.2.3 / v1.2.2 ...`。
- 删除旧 patch 时：默认**只删 Release，不删 Git tag**（除非用户明确要求清理 tag）。

### 4) 发布后检查（必须）

每次发布后都要检查：

- `Latest` 是否指向目标版本。
- 资产是否齐全（M 芯片 + Intel + SHA256SUMS）。
- 是否残留旧 `x.y.z` Release（若有立即删除旧的）。

建议命令：

```bash
gh release list -R lueluelue2006/macOS_MusicPlayer --limit 100
gh release view vX.Y.Z -R lueluelue2006/macOS_MusicPlayer --json assets,url
# 删除旧 patch release（保留 tag）
gh release delete vOLD -R lueluelue2006/macOS_MusicPlayer --yes
```

### 5) 发布细节规范（必须）

- Release 文案必须使用 `--notes-file`（或 `--notes-file` + 本地 markdown 文件），避免 `\n` 字面量导致页面格式错乱。
- 上传资产前必须校验架构：
  - Apple Silicon 包内可执行文件应为 `arm64`
  - Intel 包内可执行文件应为 `x86_64`
  - 建议命令：`file MusicPlayer.app/Contents/MacOS/MusicPlayer`、`file MusicPlayer-intel.app/Contents/MacOS/MusicPlayer`
- `SHA256SUMS.txt` 必须覆盖当次发布的两个 DMG（M 芯片 + Intel）。
- 发布后必须复查 Release 页面展示（文案格式、资产数量、文件名）。

### 6) 发布产物与仓库卫生

- DMG、`SHA256SUMS.txt` 等发布产物默认不提交到源码仓库（除非用户明确要求）。
- 发现仅用于发布流程的临时产物，应及时清理或加入忽略策略，避免污染工作区。

