# Codex 工作约定（重要）

## GitHub Releases 维护规则（强制）

为避免 Releases 页面被小版本刷屏：

- **大版本（x.y）**：永久保留（例如 `v3.6`、`v3.7`）。
- **小版本（x.y.z）**：全仓库 **最多只保留 1 个**（也就是“最新发布/最新更新”的那个小版本，例如只保留 `v3.6.4`，删除更旧的小版本 `v3.3.3` / `v3.6.1` / `v3.6.2` / `v3.6.3` 等）。
- 每次发布新的 `vX.Y.Z` 后，**必须立刻检查** Releases 页面是否还残留任何旧的小版本（`v*.**.*`）；如有，**删掉旧的小版本 Release**。
- 删除时默认 **只删 Release，不删 Git tag**（不要用 `--cleanup-tag`，除非明确要清理 tag）。

建议命令：

```bash
gh release list -R lueluelue2006/macOS_MusicPlayer --limit 100
gh release delete vX.Y.Z -R lueluelue2006/macOS_MusicPlayer --yes
```
