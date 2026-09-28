# Vectracast Plugins

Vectracast 的公开插件仓库。每个一级目录是一个插件，包含 `extension.json`、`src/` 和使用说明。

用户在 Vectracast 的「设置 → 扩展 → 发现插件」中搜索安装，也可以从 Releases 下载 `.launcher-extension` 文件后本地安装，无需 Node.js。

## 提交插件

提交 Pull Request，包含插件源码、使用说明和权限用途。修改已发布插件时提高 `extension.json` 的版本号；相同版本的安装包内容不可改变。

## 发布

维护者更新 `RELEASE_NOTES.md`，将审核过的改动合入主分支，然后推送新的 `plugins-v*` 标签。Actions 会使用指定版本的宿主工具链构建全部插件，生成 `index.json`、校验文件和安装包，作为同一个 Release 发布。

首次使用在 Actions Variables 配置 `VECTRACAST_REPOSITORY`（宿主的 `用户名/仓库名`）和 `VECTRACAST_REF`（已发布的宿主版本标签或固定提交 SHA）。普通用户不需要这些配置。

此仓库的 Release 是完整插件目录快照。增加新插件后用户刷新目录即可发现，不需要重新发布宿主应用。

## 协议

仓库使用 MIT License。第三方依赖仍遵循各自协议。
