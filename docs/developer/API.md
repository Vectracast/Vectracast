# SDK 0.1 API 参考

接口定义：`packages/sdk/src/index.ts`。宿主仅接受结构化列表，尚无 React、DOM 或自定义 HTML。

宿主 0.3 增加 `ctx.search.sensitivity`（`low | medium | high`），向插件传递用户选择的匹配严格程度。匹配与排名仍由插件实现；兼容旧宿主时使用 `ctx.search?.sensitivity ?? "medium"`。低灵敏度可以提供更多模糊结果，高灵敏度应收紧匹配，不能将此值解释为防抖延迟。

## Manifest

```json
{
  "manifestVersion": 1,
  "id": "local.example",
  "name": "示例",
  "version": "0.1.1",
  "description": "查询示例",
  "runtime": "standard-js",
  "sdk": "0.1",
  "icon": "textformat",
  "entry": "src/index.ts",
  "commands": [{"id": "search", "title": "搜索", "keywords": ["demo"], "debounceMs": 150}],
  "permissions": {"clipboard": ["write"], "network": ["https://example.com"]},
  "preferences": [
    {"name": "token", "title": "服务密钥", "type": "secret", "required": true},
    {"name": "language", "title": "语言", "type": "dropdown", "options": ["en", "zh-CHS"], "defaultValue": "en"}
  ]
}
```

- ID 为 `publisher.name` 两段小写字母、数字、短横线，各段以字母开头。版本使用数字 `major.minor.patch`。
- 命令 ID 与入口导出的命令对应，关键词全局唯一；冲突时拒绝安装或启用。
- `debounceMs` 为 0–5000；底座对关键词和无关键词入口统一使用至少 200ms 的尾沿防抖，实际等待为 `max(200, debounceMs)`，未填写时为 200ms。连续输入重新计时，较长的插件等待时间（如翻译 500ms）保留；最多 20 个命令。
- `inputMode` 可选 `keyword`（默认）或 `query`。`query` 允许无需关键词执行，`keywords` 可为空，也可保留如 `calc` 的显式入口。安装界面会说明该扩展可读取主搜索输入；升级新增此入口必须重新接受权限。
- 权限支持 `network`、`clipboard` 和 `applications`；不支持的权限拒绝安装。`applications` 可声明 `read` / `open`，其中 `open` 必须同时声明 `read`。
- 网络声明为精确 HTTPS origin，推荐不带末尾斜杠；不支持端口、通配符或重定向。
- 配置类型 `text`、`secret`、`dropdown`。secret 不会进入普通 preferences。
- 图标为 SF Symbols 名称，目前不支持外部图片。

## 查询和结果

`defineExtension({commands})` 和 `defineSearchCommand({id, query})` 提供 TypeScript 类型约束。`query(ctx)` 返回 `Promise<{items: ResultItem[]}>`。每次查询使用新 JSContext，无跨查询模块状态。

| 字段/接口 | 实际行为 |
| --- | --- |
| `ctx.query` | 关键词入口为去掉关键词后的文本；无关键词入口为完整输入 |
| `ctx.rawInput` | 主窗口原始输入；CLI query 使用所传 query |
| `ctx.preferences` | 默认值与已保存配置合并，均为字符串 |
| `ctx.secrets.get(name)` | 异步读取本扩展声明为 secret 的字段；未保存返回空字符串，未声明拒绝 |
| `ctx.network.fetch(url, options?)` | 返回 `{status, body}`，body 为文本，需要自行 JSON.parse |
| `ctx.applications.list()` | 异步读取应用目录，需要 applications read；返回不含文件路径的应用元数据 |
| `ctx.crypto.sha256(text)` | SHA-256 UTF-8 字符串，返回小写十六进制 |
| `ctx.crypto.uuid()` | 随机 UUID，用于请求盐值等 |

网络只支持 GET/POST；允许 Content-Type、Accept、Authorization 请求头；单次查询最多 6 个请求，请求体小于 100KB，响应最多约 2MB。请求超时 10 秒、资源总超时 12 秒。重定向不跟随，HTTP 错误状态由扩展处理。原生网络错误返回通用错误，不把正文和密钥写入日志。

`ResultItem` 包含 `id`、`title`、可选 `subtitle/icon/detail/applicationId`、`actions`。id 应在结果批次内唯一。最多展示 50 条，title 最多 12000 个 Swift Character；当前只展示 title、subtitle 和 icon，detail 字段保留但尚无详情面板。

`copyAction(text)` 返回 `{id:"copy",title:"复制结果",type:"clipboard.copy",text}`。需要声明 clipboard write。实际剪贴板写入仅在用户回车或点击动作后由宿主执行，查询阶段没有直接写剪贴板 API。未知动作被过滤。

`ctx.applications.list()` 返回 `{id, name, bundleIdentifier, searchTerms}[]`，搜索匹配与排序由插件实现。底座扫描 `/Applications`、`/System/Applications`、`~/Applications` 并包含 Finder；目录最多 2000 项，缓存 60 秒。`id` 是宿主发放的应用标识，`searchTerms` 提供文件名及拉丁转写。

`openApplicationAction(application)` 创建 `application.open` 动作，需要 applications open。结果同时设置 `applicationId: application.id`；宿主只接受本次查询通过目录接口获得的标识，并检查动作目标与结果一致。实际路径由宿主解析，插件提交的 `applicationPath` 会被丢弃。用户回车或点击动作时再次检查插件启用状态和权限，随后打开应用；查询阶段不能直接启动应用。示例见 `extensions/applications`。

输入改变会取消旧网络请求、作废旧回调。SDK 0.1 **尚无 AbortSignal 和流式结果接口**；不能主动中止正在运行的同步 JS。执行 watchdog 在 15 秒后终止超时服务，客户端有 16 秒兜底。不要在查询里做长时间同步计算。

### 无需关键词的扩展

```json
{"id":"calculate","title":"计算与进制转换","keywords":["calc"],"inputMode":"query","debounceMs":80}
```

已启用的 `query` 命令接收非空、未被显式关键词入口接管的输入。`up hello` 等已匹配命令优先，不广播给无关键词扩展。扩展不匹配当前输入时返回 `{items:[]}`，例如计算器遇到 `Safari` 时不返回任何结果。命令仍使用同一 SDK 和沙箱 XPC 执行，不在宿主中内置计算逻辑。

多个扩展各自去抖和执行，按扩展 ID、manifest 命令顺序合并；结果 ID 加入扩展/命令命名空间，避免互相覆盖。输入改变或窗口关闭时取消所有旧请求，旧回调不能更新新查询。等待期间保留上一批列表并置灰，禁用旧结果动作；首个非空结果或全部命令完成后更新。尚未完成时不显示“没有匹配结果”，清空输入立即收起，输入法组词期间不执行查询。命令运行失败记入现有诊断日志，不阻断其他插件。应用搜索本身也是同一路由下的插件。空搜索不执行这些扩展。

`inputMode:query` 扩展会接触未被关键词接管的搜索输入，应在声明和说明中如实说明用途；网络和密钥权限仍依 manifest 管理。本地计算器只声明用户选择后的剪贴板写入，不申请网络或密钥权限。

调试：`npm run platform -- search "0xff03"` 查询已安装的无关键词扩展，输出结构化 JSON；显式命令仍可用 `platform query local.calculator calculate "0xff03"`。示例实现在 `extensions/calculator`。

## 运行时和权限边界

扩展执行于启用 App Sandbox 的 JavaScriptCore XPC 服务，默认无直接网络与宿主文件访问权限。没有 Node.js、require、process、fs、child_process、浏览器 DOM、fetch、setTimeout 等常规宿主对象；需要网络时调用 SDK 代理。

打包器拒绝 Node 内建模块，产物是 IIFE `Extension.default`。第三方纯 JavaScript 依赖可以被打包，但不能依赖浏览器或 Node 宿主环境。不要直接调用内部双下划线桥接函数；宿主仍会校验桥接请求权限。

当前只适合本地自编写/已审阅扩展。已经验证的隔离与尚未完成的资源、来源、网络安全加固见 [VALIDATION.md](VALIDATION.md)，不能据此宣称已满足公开商店不可信代码执行标准。

## 安装包与存储

`.launcher-extension` 是 JSON envelope：`format:1`、manifest、打包后的 source、source SHA-256。源代码小于 2MB、安装包小于 3MB。没有 zip 解压步骤，entry 仅用于构建；安装校验格式、兼容性和源码摘要。

摘要只检测源码意外损坏，**不是发布者签名**，不证明 manifest 或来源可信。商店额外校验官方仓库的 Release 来源与附件摘要，仍不代表独立的发布者数字签名。

SQLite 保存版本包、启用状态和非敏感配置，默认位于 `~/Library/Application Support/Launcher/launcher.sqlite`。为延续改名前的配置与已安装插件，数据目录继续使用原路径。密钥在钥匙串，以扩展 ID 和字段名隔离。`LAUNCHER_HOME` 可替换测试数据库/日志目录，但不替换钥匙串命名空间；测试请使用独立扩展 ID。卸载清除该扩展的版本、设置和凭据。未实现自定义存储 SDK。

## 剪贴板历史能力（宿主 0.3.1）

Manifest 的 `permissions.clipboard` 新增 `history`。启用后授权底座后台采集文本并按扩展 ID 隔离保存；SDK `ctx.clipboard.history()` 返回 `Promise<{id,text,source,timestamp}[]>`，timestamp 为 Unix 毫秒。查询再次检查启用状态和权限。插件不能读取其他扩展的历史文件，也不能在查询阶段删除历史。

`removeHistoryAction(entry)` 声明删除单条；宿主只接受本次历史读取发放的 ID。`clearHistoryAction()` 声明清空全部历史，执行前显示确认框。两者只在用户触发后执行，并再次验证启用状态及权限。复制仍用 `copyAction(entry.text)`，需 `write` 权限。

底座统一限额为 200 条、7 天、总 JSON 约 500KB、单条 UTF-8 10KB；去重使用完整原文。启用前内容不补采，停用停止采集，卸载删除该扩展历史。跳过敏感及临时标记，无标记密码无法自动判定。历史不进入配置备份/日志。完整示例与限制见 `extensions/clipboard-history/README.md`。

`commands[].acceptsEmptyQuery: true` 允许只输入完整关键词（如 `cb`）即执行空查询，无需先按回车或补空格；默认 false 保留现有翻译等命令的空输入提示。可用于历史列表等浏览型插件。

## 通用列表详情与图片历史（宿主 0.4.0）

命令可声明 `presentation: "detail"` 和 `filters: [{id,title}]`，获得左右分栏、返回按钮、筛选搜索与类型菜单。选择项通过 `ctx.filter` 传入；匹配、分类、分组与统计由插件实现。例子见剪贴板历史 0.2.0。未声明的命令保持原有单列展示。

结果新增可选字段：

- `group`: 分组标题。宿主插入不可执行的组标题行，方向键跳过标题。
- `preview: {text?: string, historyImageID?: string}`: 纯文字预览，或经授权的图片记录 ID。文字最多 20000 字符，不执行 HTML/脚本。
- `metadata: [{label,value}]`: 信息区，最多 10 项，每项标题 60 字符、值 200 字符。

`permissions.clipboard` 新增 `history-images`（需要 history）和 `paste`（需要 write）；升级权限需接受。未声明图片历史的旧插件仍只获得文本记录。`ctx.clipboard.history()` 图片条目提供 `kind:"image"`、`width`、`height`、`byteCount`，不提供磁盘路径或二进制数据；旧文本条目兼容缺省 kind。

`copyHistoryAction(entry)` 按 ID 恢复文字或 PNG；`pasteHistoryAction(entry)` 复制后尝试向上一应用粘贴，需要声明 paste 且系统辅助功能已授权。底座检查目标进程仍是前台，避免粘贴到其他应用。无授权时仅复制并提示，不自动变更权限。

图片预览、复制、粘贴、删除只接受本次历史读取发放的 ID，并在执行时再次检查插件状态与权限；查询阶段不能调用修改历史或粘贴接口。图片每个插件独立保存，过期、删除和卸载时清理，限额见示例 README。


## 命令入口（宿主 0.4.2）

主搜索识别命令的有效 `keywords`、`id` 和完整 `title`；单命令扩展也识别扩展 `name`。大小写不敏感，名称后以空白分隔查询内容。例如剪贴板插件的 `cb`、`history`、`剪贴板历史` 均进入相同命令，`history Safari` 带查询条件进入。

优先匹配最长完整名称，同长度时有效别名优先于 ID、命令名称和扩展名称。重名且优先级相同时只显示候选，用户选中回车进入指定命令；已停用扩展不参与。自定义别名替换 manifest 关键词，不影响 ID/名称入口。

显式进入详情页立即执行首查；页内输入仍遵守防抖。`acceptsEmptyQuery` 为 false 时空查询只提示输入，不调用扩展。该能力由底座实现，无需插件修改或升级。


### 应用搜索词（宿主 0.4.5）

`applications.list()` 的 `searchTerms` 包含文件名、原始名称，以及本地化显示名的连续拼音和分词拼音；汉字名称另提供拼音首字母。例如“微信开发者工具”包含 `weixinkaifazhegongju`、`wei xin kai fa zhe gong ju`、`wxkfzgj`。英文名称不额外生成拼音首字母。底座提供元数据；查询匹配、分隔符/声调归一化、排序和条数仍由插件控制。


### 应用文件与协议类型（宿主 0.4.6）

`Application` 新增可选 `urlSchemes?: string[]`、`documentTypes?: string[]`，分别来自应用 Info.plist 的 URL schemes，以及文档 UTI/文件扩展名。字段为去重小写数组；旧宿主可缺省。应用搜索插件结合 HTTP/HTTPS 与 HTML 声明判断浏览器类别，避免把只注册网页链接的其他工具误归类。读取这些元数据不会访问网页，也不会打开应用。

## 公开插件目录与全页详情

命令可声明 `presentation: "list"`、`searchPlaceholder` 和 `filters`，在主窗口显示有返回键的双行列表。结果的 `group` 由插件决定分组；`view.detail` 动作显示结果的 `preview.text` 与 `metadata`，隐藏列表并保留返回状态。详情页动作来自原结果，去除 `view.detail` 自身。现有 `presentation: "detail"` 仍为左右分栏预览。

- `ctx.catalog.list()`：需要 `permissions.catalog: ["read"]`。固定读取 `Vectracast/Vectracast-Plugins`，宿主拒绝携带 `repository` 的调用，返回已校验公开 Release 的目录快照、元数据、已安装版本、来源链接和不透明 `handle`。目录缓存 5 分钟，插件自行匹配和排序。
- `catalog.install` 动作：需要 `catalog: ["read", "install"]`；结果 `catalogID` 和动作 `text` 必须使用本次查询签发的同一个 handle。仅用户触发后允许下载，校验后仍须确认被安装插件的权限。查询阶段无安装 API。
- `catalog.refresh` 动作：需要 `catalog.read`，使目录缓存失效并重新查询。
- `url.open` 动作：需要 `permissions.browser: ["open"]`，仅用户选择后打开无用户名、密码或自定义端口的 HTTPS URL。

商店插件见 `extensions/plugin-store`。目录格式和发布流程见 [RELEASING.md](RELEASING.md)。现阶段详情不编造作者、下载次数或截图；缺失的发布元数据不显示。
