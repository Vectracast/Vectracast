# Vectracast 0.7.0

- 新增插件目录：搜索公开仓库已打包的插件，查看权限并下载安装或更新。
- 新增检查更新：显示 GitHub 最新正式版本及更新说明，从公开 Release 下载 macOS 安装包。
- 支持分别配置应用和插件的 GitHub 公开仓库。
- 使用 Vectracast 自有 Logo 和单色菜单栏图标。

当前为 Apple Silicon 开发预览版，最低 macOS 13.3。安装包使用 ad-hoc 签名，尚未完成 Apple Developer ID 签名与公证。更新下载后需退出旧应用，手动替换应用；设置和插件数据保留。

- 插件商店作为独立插件发布：主窗口分类列表、全页详情与安装动作；底座保留通用目录、校验和安装能力。

- 插件商店固定连接 `hi-jian/Vectracast-Plugins`，移除换源设置并拒绝接口和构建参数覆盖。
