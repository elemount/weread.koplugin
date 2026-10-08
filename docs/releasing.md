# Releasing / 发布

GitHub Release 由版本 tag 驱动。推送 `vX.Y.Z` 后，GitHub Actions 会检查 tag
和 `_meta.lua` 版本一致、tag 指向 `main` 上的提交，然后并行运行 CI 与固定版
KOReader PluginLoader 集成检查。两者通过后，Actions 打包插件、生成 SHA-256，
并创建 GitHub Release。Release 附件是 ZIP 和 `.sha256` 文件。

发布包只含 KOReader 运行需要的文件：`_meta.lua`、`main.lua`、`weread/`、
`fonts/`、`README.md`、`LICENSE` 和 `NOTICE`。`.github/`、`docs/`、`scripts/`
和 `spec/` 等开发文件不会打进包里。ZIP 只有一个顶层 `weread.koplugin/`
目录，可直接解压到 KOReader 的 `plugins/` 目录。

## 发布步骤

1. 将 `_meta.lua` 和 `main.lua` 更新为相同的新版本 `X.Y.Z`。
2. 在 `CHANGELOG.md` 添加非空的 `## [X.Y.Z]` 小节，只写本次整理后的发布说明；
   Actions 会补上 `## 新功能与改进` 标题及 GitHub 自动生成的变更记录。
3. 运行本地检查并提交、推送到 `main`。
4. 在该提交创建并推送匹配 tag：

   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z"
   git push origin vX.Y.Z
   ```

5. 在 **Actions → Release** 查看工作流。成功后确认 Release 页面、ZIP 和校验和。

tag 推送是发布触发点。失败时可在 Actions 中重跑；如果需要改代码，先提交修复，
再使用新的版本号和 tag。不要移动或复用已经发布的版本 tag。

UI 和设备验收无法由 GitHub Actions 判断。根据改动范围，可使用
[macOS/KOReader 手动验收清单](macos-release-testing.md)和目标设备做补充检查，
并在发布记录中注明未执行或受阻的项目。

## 本地打包

```bash
bash scripts/package_release.sh
```

默认输出为 `dist/weread.koplugin-vX.Y.Z.zip`，版本来自 `_meta.lua`。也可以将
自定义输出路径作为第一个参数传入。
