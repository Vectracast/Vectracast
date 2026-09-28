# Vectracast 0.7.1

- 插件商店独立为插件，支持分类列表、名称和命令搜索、全页详情、安装与更新。
- 商店固定连接 `hi-jian/Vectracast-Plugins`，安装前校验目录、包摘要和权限，不允许换源。
- 应用检查 `hi-jian/Vectracast` 的最新正式版本，显示更新内容并打开公开安装包地址。
- 主仓库通过 `extensions/` 子模块引用插件源码，两个仓库独立发布。
- 修正沙箱验证对外部 DNS 的依赖，使用本机 socket 的权限拒绝结果验证网络隔离。
- 使用 Vectracast 自有 Logo 和单色菜单栏图标。

当前为 Apple Silicon 开发预览版，最低 macOS 13.3。安装包使用 ad-hoc 签名，尚未完成 Apple Developer ID 签名与公证。更新下载后需退出旧应用，手动替换应用；设置和插件数据保留。
