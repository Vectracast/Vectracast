# GitHub 仓库与发布

Vectracast 使用两个 Public 仓库。主仓库为 `Vectracast/Vectracast`，插件仓库为 `Vectracast/Vectracast-Plugins`。

| 仓库 | 内容 | Release 附件 |
| --- | --- | --- |
| `Vectracast` | macOS 应用、SDK、CLI、测试和开发文档 | macOS ZIP、SHA-256 校验文件、签名的 appcast.xml |
| `Vectracast-Plugins` | 插件源码、说明和插件发布流程 | `index.json`、全部插件安装包、校验文件 |

主仓库通过 `extensions/` Git submodule 固定一个插件仓库提交。数据服务同步插件仓库的最新正式 Release，应用通过服务读取目录，不依赖本地 submodule 是否已更新。因此发布新插件不要求重新发布应用。

## 1. 在 GitHub 创建仓库

两个公开仓库已创建。以下为重新部署时的建仓说明：打开 [新建仓库](https://github.com/new) 创建空仓库。

- Owner 选择自己的账号或组织。
- Visibility 选择 **Public**。
- 不添加 README、`.gitignore` 或 License，本地已经准备好了这些文件。
- 点击 Create repository，记下两个 HTTPS 地址。

例如：`https://github.com/Vectracast/Vectracast.git` 和 `https://github.com/Vectracast/Vectracast-Plugins.git`。

## 2. 先上传插件仓库

在当前 Vectracast 项目根目录执行导出。目标目录必须不存在；导出只复制插件源码，不移动现有文件，也不包含构建产物。

```sh
node scripts/prepare-plugin-repository.mjs ../Vectracast-Plugins
cd ../Vectracast-Plugins
git init -b main
git remote add origin https://github.com/Vectracast/Vectracast-Plugins.git
git add .
git diff --cached --stat
git commit -m "feat: initialize plugin repository"
git push -u origin main
```

导出的仓库已包含六个插件（含插件商店）、MIT License、README 和 `.github/workflows/release.yml`。

## 3. 在主仓库接入 submodule

回到 Vectracast 项目根目录。先确认插件仓库已上传成功，再执行以下命令。保留旧插件目录作为迁移备份：

```sh
git rm -r --cached --ignore-unmatch extensions
test ! -e ../Vectracast-extensions-backup && mv extensions ../Vectracast-extensions-backup
git submodule add -b main https://github.com/Vectracast/Vectracast-Plugins.git extensions
```

将根目录 `distribution.json` 的 `appRepository` 改为实际主仓库名称；`pluginRepository` 已固定，不可改动：

```json
{
  "appRepository": "Vectracast/Vectracast",
  "pluginRepository": "Vectracast/Vectracast-Plugins",
  "apiBaseURL": "https://vectracast-api.fix030.com"
}
```

然后检查并提交主仓库。若已有 `origin`，先用 `git remote -v` 确认，不要重复添加。

```sh
git branch -M main
git remote add origin https://github.com/Vectracast/Vectracast.git
git status --short
git add .
git diff --cached --stat
git commit -m "feat: initialize Vectracast"
git push -u origin main
```

以后克隆主仓库要带子模块：

```sh
git clone --recurse-submodules https://github.com/Vectracast/Vectracast.git
```

已克隆的仓库执行 `git submodule update --init --recursive` 即可补齐插件。

## 4. 配置 Actions

在各仓库的 **Settings → Secrets and variables → Actions → Variables** 中添加普通仓库变量：

| 所属仓库 | 变量 | 值 |
| --- | --- | --- |
| 插件仓库 | `VECTRACAST_REPOSITORY` | `Vectracast/Vectracast` |
| 插件仓库 | `VECTRACAST_REF` | 宿主工具链的固定版本，例如 `v0.7.2`，或完整提交 SHA |

工作流使用 GitHub 提供的 `GITHUB_TOKEN`，不需要个人访问令牌。发布作业请求 `contents: write`；若组织策略限制 Actions，需要在组织中允许该工作流运行。仅推送版本标签触发发布，普通 PR 不发布。

常规自动发布先发布主仓库工具链版本，再发布插件目录。首次空仓库接入使用文末的本地引导流程，插件验证通过后才上传主仓库。两边 checkout 均不持久保存令牌。

## 客户端插件分发协议

宿主插件目录使用 `GET /v2/plugins`。设置页通过 `POST /v2/plugins/updates` 提交宿主版本和已安装插件的 ID、版本；不提交开发插件、用户配置或搜索内容。服务端返回独立插件更新，客户端再次检查版本递增、兼容性和下载目标。

下载地址必须精确匹配 `/v2/plugins/{id}/versions/{version}/download`，仅访问官方 HTTPS 服务，不接受重定向。安装前校验 SHA-256、包声明与目录声明，保留下载进度及失败后的原版本。`GET /v2/plugins/{id}/versions` 用于读取版本历史，不自动降级。

目录缓存为 `catalog/official-v2.json`，与旧发行批次缓存隔离；缓存最长保留七天，五分钟后后台刷新。内容变化即生成新的安装句柄，不以批次标签判定是否更新。设置页更新检查直接请求服务器，部分更新结果不覆盖完整目录缓存。后台撤回版本后，即使客户端还显示缓存条目，下载也会失败并提示刷新。

商店搜索和展示仍由插件负责，SDK 的 `catalog.list` / `catalog.install` 接口保持兼容。App 自更新仍使用签名 appcast，与插件协议独立。

## 5. 发布应用

1. 修改 `package.json` 的 `version` 和 `buildNumber`，同步 lockfile 版本。`npm version 0.7.2 --no-git-tag-version` 可以更新两个版本字段；`buildNumber` 另行递增。
2. 更新根目录 `RELEASE_NOTES.md`，描述此版本的变化。
3. 检查、提交并推送改动，然后推送同名版本标签。

首个版本示例（当前 package.json 为 0.7.2）：

```sh
git tag v0.7.2
git push origin v0.7.2
```

Actions 在 Apple Silicon macOS runner 上检查类型、构建并运行测试，生成 `Vectracast-0.7.2-macOS-arm64.zip` 和 `SHA256SUMS`。附件全部上传到草稿后才正式发布。版本标签必须与 package.json 一致；已发布版本不覆盖，后续修改使用新版本号。

如果上传期间失败，可到 Releases 检查留下的草稿；客户端只读取正式 Release。修复失败后处理草稿再重跑，不要改写已公开发行版的附件。

应用的「关于 → 检查更新」和菜单栏「检查更新…」使用 Sparkle 2.10.0，读取数据服务 `/v1/appcast.xml` 返回的签名清单。点击「更新并重启」后显示下载进度，验证签名、解压、替换应用并重新启动；下载可以取消，失败可重新检查。系统目录权限不足时由 Sparkle 请求 macOS 授权。设置和插件数据在应用包外，更新不会覆盖它们。

更新包优先从数据服务下载；服务器下载缓慢时仍可重定向到同一正式版本的 GitHub 附件，客户端继续验证 Ed25519 签名。0.8.0 及更早版本没有安装器，需手动替换一次，之后才能使用应用内安装。

### 更新签名与首次部署

`assets/update-signing.json` 只保存公钥、清单地址和钥匙串账户名。私钥保存在本机登录钥匙串的 `Vectracast` 账户；CI 从主仓库 Secret `SPARKLE_PRIVATE_KEY` 读取，必须与应用内公钥一致。禁止把私钥加入 Git、安装包或数据服务器。私钥丢失时，当前 ad-hoc 分发无法靠 Developer ID 轮换密钥，请保留加密备份。

构建脚本下载固定版本的 Sparkle 并检查固定 SHA-256，保留框架内辅助程序的签名、权限和符号链接。运行 `node scripts/package-app-release.mjs` 会生成 ZIP、SHA256SUMS 和签名的 `appcast.xml`；本地首次签名时按 macOS 提示授权钥匙串访问。CI 没有密钥或签名与公钥不匹配时停止发布。

首次上线顺序：先部署私有服务仓库中支持 `/v1/appcast.xml` 的版本，再发布主应用。清单尚未发布时接口返回 503，不生成未签名的替代清单。服务逐字节转发清单，不改写 XML 或下载地址。首次用户安装需要从 Releases 手动下载 0.9.0；用后续版本验证实际升级。

本机端到端验证：

```sh
npm run build
node scripts/qa/verify-updater.mjs
```

验证脚本使用独立应用标识、临时签名密钥和本机 HTTP 服务，检查篡改清单、篡改 ZIP 的拒绝行为及正常安装和重启，不替换已安装的 Vectracast。运行时需要解锁桌面。

当前工作流使用 ad-hoc 签名，尚未配置 Developer ID 签名和 Apple 公证。下载的应用可能受到 Gatekeeper 限制；正式面向普通用户发行前应接入签名与公证流程。不要通过关闭系统安全机制处理这个问题。

## 6. 发布新插件或插件更新

每个插件是一个一级目录，包含 `extension.json`、`src/` 和 README。可选 `catalog.json` 的 `categories` 数组声明 `productivity`、`developer`、`language` 分类；目录构建会同时记录源目录，用于 README 和源代码链接。新功能经审核合入插件仓库主分支后，更新插件仓库的 `RELEASE_NOTES.md`，推送新的目录版本标签：

```sh
git tag plugins-v0.1.0
git push origin plugins-v0.1.0
```

插件目录标签与单个插件的版本号是两回事。更新插件内容必须提高该插件的 `extension.json` 版本；相同版本内容变化或版本倒退会使构建失败。工作流会将全部插件打包为同一个目录快照，发布 `index.json`、安装包和 SHA-256 校验文件。

用户打开「设置 → 扩展 → 发现插件」，首次自动安装随附的商店插件，之后使用 `store`、`plugins` 或“插件商店”进入。商店负责名称、ID、命令、关键词检索、分类和详情；详情中展示权限，点击安装或更新后直接执行，不重复确认。客户端下载同一 Release 中的安装包，检查文件大小、SHA-256、manifest 和 SDK，再调用现有安装机制；安装失败保留原版本。更新后的插件仍可在已安装列表中回滚。

商店固定信任 `Vectracast/Vectracast-Plugins` 与 HTTPS 发布渠道。插件、用户偏好和构建环境变量均不能更换商店来源；SHA-256 检查包与索引是否一致，不代表独立的发布者数字签名。

主仓库需要跟进新的插件源码时，更新并提交 submodule 指针：

```sh
git submodule update --remote extensions
git add extensions
git commit -m "chore: update bundled plugin sources"
git push
```

## 配置与验证边界

数据服务从 `Vectracast/Vectracast` 同步应用版本，从 `Vectracast/Vectracast-Plugins` 同步插件目录。客户端固定请求 `https://vectracast-api.fix030.com`，不提供来源输入项；旧的仓库偏好值不参与请求。首次切换前必须完成服务器 HTTPS、目录及插件包下载验证，再发布客户端版本。

本地构建、包校验测试和打包成功不等于线上发布成功。首次发布后应确认：两个 Actions 成功、Release 附件齐全、干净数据目录可以发现并安装插件、旧版本应用能读取新版本及更新内容。

接口与配置依据：[GitHub Release API](https://docs.github.com/en/rest/releases/releases)、[创建仓库](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)、[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。


## 首次发布：先验证插件，再上传主仓库

两个空仓库首次接入时，插件 Actions 尚不能取得宿主工具链。先提交插件源码并推送 `main`，使用本地已经通过测试的宿主工具打包：

```sh
GITHUB_REPOSITORY=Vectracast/Vectracast-Plugins node scripts/fetch-previous-index.mjs build/previous-index.json
node scripts/build-plugin-release.mjs extensions build/plugin-release build/previous-index.json
```

先通过 GitHub CLI 以已推送的完整源码提交 SHA 为目标创建 `plugins-v0.1.0` draft Release，上传完整目录和全部安装包，再公开发布。GitHub 可能同时触发标签工作流；首次尚无宿主工具链时该工作流会在配置检查处失败，不影响已校验的手动引导包。随后在应用内检查列表、详情、安装权限与安装后的命令。

验证通过后才推送主仓库及 `extensions/` 子模块引用，设置插件仓库的 `VECTRACAST_REPOSITORY`、`VECTRACAST_REF` Actions 变量。手动运行一次插件 Actions，确认目录打包与已发布版本校验通过；从下一个 `plugins-v*` 标签开始走自动发布。
