# 参与 Vectracast 开发

应用的构建和运行步骤见 [README](README.md#getting-started)。编写插件请先阅读 [开发入门](docs/developer/README.md) 和 [API 参考](docs/developer/API.md)。

## 提交问题

请说明期望行为、实际行为和复现步骤，附上 macOS 版本与 Vectracast 版本。界面问题可以附截图；截图和日志中请去除密钥、私人剪贴板内容等敏感信息。

## 修改与验证

在自己的 fork 或有写入权限的仓库中，为改动创建分支，例如：

```sh
git switch -c docs/improve-readme
```

让一次提交围绕一个问题展开。功能逻辑放在对应插件中；宿主与插件的职责见 [架构说明](docs/architecture/PLUGIN-FOUNDATION.md)。

修改代码后运行：

```sh
npm run check
npm run build
npm test
npm run platform -- doctor
```

先完成构建，再运行测试，避免读取到尚未签名完成的应用。涉及界面时，请检查输入焦点、键盘操作、浅色与深色外观。仅修改文档时，检查链接、图片和命令即可。

## 提交与 push

先检查改动，再按文件加入暂存区。以下以 README 为例：

```sh
git status --short
git diff
git add README.md
git diff --cached
git commit -m "docs: improve project overview"
```

新增文件不会出现在普通 `git diff` 中，也要检查 `git status` 列出的内容。构建产物、依赖目录和本地环境文件已由 `.gitignore` 排除。

确认 `origin` 指向自己的 fork 或有写入权限的仓库：

```sh
git remote -v
```

如果没有 `origin`，将下面的占位内容替换为实际地址后执行：

```sh
git remote add origin '你的仓库地址'
```

推送当前分支：

```sh
git push -u origin HEAD
```

随后在代码托管平台发起 Pull Request，说明解决的问题、修改后的行为和验证结果；界面改动附上截图。后续提交到同一分支可直接运行 `git push`。

## 协议

提交贡献时，请确保代码和资源可按项目的 [MIT License](LICENSE) 分发。引入第三方代码或资源时，保留其要求的版权与许可声明。
