# SDK、CLI 与开发文档规格

状态：完整接口设计目标。仓库内已实现 SDK 0.1 和 CLI 子集，尚未发布 npm 包；`@platform/ui` 等后续接口尚未实现。可运行接口以 [SDK 0.1 参考](../developer/API.md) 为准，不要直接使用本设计文档中的未来 API。

## 1. 开发体验目标

开发者不需要了解 Swift、IPC 或窗口管理，编写一个查询函数就能将结果送入主搜索框。完整界面、系统操作和后台能力按需学习。

官方内置工具也使用相同的公开协议与组件；系统专属能力通过宿主适配器实现，不给官方扩展保留不可解释的隐藏 UI 接口。

## 2. 扩展结构与 manifest

```text
my-extension/
  extension.json
  package.json
  src/index.ts
  assets/icon.png
  tests/query.test.ts
  README.md
  CHANGELOG.md
  LICENSE
```

```json
{
  "$schema": "./node_modules/@platform/sdk/extension.schema.json",
  "manifestVersion": 1,
  "id": "example.text-tools",
  "name": "Text Tools",
  "version": "0.1.0",
  "engines": { "host": ">=0.1.0 <1.0.0", "sdk": "^0.1.0" },
  "runtime": "standard-js",
  "entry": "src/index.ts",
  "icon": "assets/icon.png",
  "commands": [
    {
      "id": "uppercase",
      "title": "转为大写",
      "kind": "search",
      "keywords": ["up"],
      "description": "在主搜索框直接转换文字",
      "query": { "minLength": 1, "debounceMs": 0 }
    }
  ],
  "permissions": { "clipboard": ["write"] },
  "preferences": []
}
```

约束：扩展 ID 在商店中由发布者命名空间验证，不能仅相信包内作者字段；本地未签名包使用独立的本地身份。命令 ID 在扩展内唯一。入口、图标和资源都必须在包根目录内。关键词是安装时的建议值，实际别名归用户管理。

有道扩展的 manifest 额外声明 `network: ["https://openapi.youdao.com"]`，以及应用 ID、密钥两个偏好字段；密钥使用 `secret` 类型。具体请求签名由有道适配器实现，不能把密钥拼进日志或 query URL。

## 3. 实时查询 API

拟议核心类型：

```ts
type ResultAction =
  | { id: string; title: string; type: "clipboard.copy"; text: string }
  | { id: string; title: string; type: "clipboard.paste"; text: string }
  | { id: string; title: string; type: "url.open"; url: string }
  | { id: string; title: string; type: "custom"; handler: string; payload?: JsonValue };

interface ResultItem {
  id: string;
  title: string;
  subtitle?: string;
  icon?: AssetRef | SystemIcon;
  accessories?: Accessory[];
  preview?: Preview;
  actions: ResultAction[];
}

interface QueryBatch {
  items: ResultItem[];
  update?: "replace" | "append";
  nextCursor?: string;
}

interface QueryContext {
  query: string;             // 去掉关键词后的参数原文
  rawInput: string;          // 完整输入，供本地解析使用
  signal: AbortSignal;
  cursor?: string;
  preferences: PreferencesReader;
  secrets: ScopedSecretsReader;
  network: ScopedNetwork;
  storage: ScopedStorageReader;
  cache: EphemeralCache;
  log: RedactingLogger;
}

interface SearchCommand {
  id: string;
  query(context: QueryContext): Promise<QueryBatch> | AsyncIterable<QueryBatch>;
}
```

`JsonValue / AssetRef / SystemIcon / Accessory / Preview` 等辅助类型由 SDK 导出并配套 JSON Schema，不允许跨进程传入任意对象、函数或原生句柄。预览优先采用文本、Markdown 子集、受控图片资源；不执行 HTML 或 JavaScript。

一个完整的最小查询示例：

```ts
import { defineExtension, defineSearchCommand } from "@platform/sdk";

export default defineExtension({
  commands: [defineSearchCommand({
    id: "uppercase",
    async query({ query, signal }) {
      signal.throwIfAborted();
      if (!query.trim()) return { items: [] };
      const result = query.toLocaleUpperCase();
      return {
        items: [{
          id: "uppercase-result",
          title: result,
          subtitle: "回车复制",
          actions: [{ id: "copy", title: "复制结果", type: "clipboard.copy", text: result }]
        }]
      };
    }
  })]
});
```

输入 `up hello` 时，宿主调用 query；用户回车时，宿主才执行复制动作。这个例子不依赖外部网络，可作为 SDK 安装后的第一个测试。

### 查询契约

- query 可以被快速、重复调用，不能假设上一个请求已经结束。
- 接收取消信号后尽快终止工作；即使扩展忽略取消，宿主也会丢弃过期结果。
- 空查询由 manifest 决定是否支持；默认不发送空的外部请求。
- 分页 cursor 不跨查询复用；重复 item ID 更新同一项，不制造重复行。
- 联网状态使用宿主提供的加载提示；扩展可以提供空状态文案和可执行的修复入口。
- 列表标题用于显示；复制内容来自动作的 `text`，不从标题反向拼接。
- query 中不能执行写剪贴板、打开应用、删除文件等动作；类型限制之外还必须在运行时拒绝越权调用。

## 4. 动作、视图和其他扩展类型

| 类型 | 入口 | 适合场景 | 开放顺序 |
| --- | --- | --- | --- |
| Search Command | `query(context)` | 翻译、词典、书签、文件检索 | B |
| Action Command | `execute(context, input)` | 打开应用、文本处理、窗口动作 | B/C |
| View Command | 声明式视图 / React 组件 | 管理列表、详情、表单 | C/E |
| Background Task | 受预算限制的任务处理器 | 定时刷新和缓存 | F |
| Menu Bar Item | 状态输出与用户动作 | 计时器、服务状态 | E/F |
| AI Tool | 输入 schema + 执行处理器 | 供 AI 调用的显式能力 | F |

动作上下文包含宿主校验后的调用身份和用户触发信息；扩展只接收自身处理器的事件。危险操作可以声明确认文案，但宿主仍有最终判断和呈现职责。

## 5. SDK 能力面

| API 模块 | 内容 | 限制 |
| --- | --- | --- |
| Commands | 注册命令、查询、动作、导航 | 跨扩展调用需显式目标和许可 |
| Clipboard | 复制、粘贴、读取 | 读写分权，写操作不能在 query 阶段发生 |
| Preferences | 有类型的字段、校验、配置入口 | 用户管理；密钥字段不会出现在普通偏好快照中 |
| Secrets | 读写扩展自己的凭据 | Keychain namespace；无法枚举其他扩展 |
| Network | fetch 子集、取消、超时、响应限额 | 域名与重定向检查；上传行为可观察 |
| Storage / Cache | 持久数据、短期缓存 | 配额、迁移；默认不持久化搜索原文 |
| Files | 文件选择、读取、查询 | 只接受授权资源句柄或批准的范围 |
| Applications / Windows | 应用启动、窗口操作 | 通过原生宿主与系统授权 |
| UI | List、Detail、Form、Grid、ActionPanel | 版本化组件树，统一键盘操作 |
| Feedback | Toast、HUD、进度、错误 | 不允许无限刷通知 |
| OAuth | 系统浏览器登录、回调、令牌存储 | PKCE、state；凭据不进入日志 |
| Crypto | UUID、hash、HMAC 等选定操作 | 覆盖服务鉴权所需能力；不暴露任意原生代码 |
| AI | 文本生成、流式响应、工具调用 | 服务商与费用来源可见；F 阶段 |
| Testing | 假宿主、mock 服务、时钟和输入回放 | 不替代真实沙箱和原生 UI 测试 |

标准运行时的 Web API 兼容清单必须逐项发布，包括 URL、TextEncoder、AbortController、Timers、fetch、Streams。缺失项在打包或启动时明确报错，不能以「支持 JavaScript」暗示完整 Node / 浏览器环境。

## 6. React UI 设计

开发者可写熟悉的组件，但组件不是网页 DOM。SDK 将状态更新转换成受校验的 UI 树，由 macOS 宿主渲染原生控件。

第一批：`List / List.Item / List.Section / ActionPanel / Action / Detail / Form`；之后再加 Grid、菜单栏及复杂编辑器。

必须定义属性 schema、组件 key、事件 ID、更新批次、错误边界、导航栈、焦点恢复和异步动作状态。扩展不能通过 CSS 任意改变整个宿主布局，也不能伪造系统权限弹窗。React 性能与 state 生命周期在技术验证后才承诺兼容范围。

## 7. IPC 协议

拟采用版本化消息，传输由 XPC 桥接提供；开发 CLI 与宿主采用本地受认证连接。

| 消息 | 方向 | 内容 |
| --- | --- | --- |
| `hello` | 双向 | 协议版本、可用能力、会话信息 |
| `query.start` / `query.cancel` | 宿主 → 扩展 | commandId、queryId、generation、输入与配置版本 |
| `query.batch` / `query.done` | 扩展 → 宿主 | 当前批次、分页、结束状态 |
| `action.execute` | 宿主 → 扩展 | 校验后的动作处理器与 payload |
| `capability.call` / `capability.result` | 双向 | 受权限控制的宿主能力 |
| `view.patch` / `view.event` | 双向 | 声明式 UI 更新与用户事件 |
| `log` / `error` / `health` | 扩展 → 宿主 | 结构化诊断与存活信息 |

所有消息绑定宿主建立的真实连接身份；不信任消息体自行声称的 publisher 或 extension ID。请求包含唯一 ID；超时、重复回复、取消后的回复和畸形消息都有明确处理规则。

错误码至少包括：`CANCELLED`、`TIMEOUT`、`PERMISSION_DENIED`、`CONFIG_REQUIRED`、`NETWORK_ERROR`、`RATE_LIMITED`、`INVALID_RESPONSE`、`INCOMPATIBLE_RUNTIME`、`RESOURCE_LIMIT`。用户提示与开发堆栈分离。

## 8. CLI 目标

以下命令为拟议接口：

| 命令 | 行为 |
| --- | --- |
| `platform create` | 选择模板，生成项目、测试与文档 |
| `platform dev` | watch、编译、source map、注册开发版本、热重载 |
| `platform inspect` | 连接当前开发会话，打开调试入口 |
| `platform logs` | 按扩展/命令过滤日志，默认脱敏 |
| `platform doctor` | 检查宿主、SDK、运行时、权限和配置 |
| `platform test` | 运行 Testkit 与扩展测试 |
| `platform validate` | manifest、依赖、API 版本、资源、权限声明检查 |
| `platform pack` | 生成可安装包、内容清单和摘要 |
| `platform install <file>` | 安装本地包，展示权限和来源 |
| `platform publish` | 上传审核草稿，不直接公开上线 |

CLI 稳定退出码，CI 可读取 JSON 格式结果。开发者本地工具链与用户客户端分离：普通用户安装扩展不需要 npm、Node 或 Xcode。

## 9. 调试必须做到的程度

- 改保存的源码后热重载；出现编译错误保留上一个正常版本。
- 堆栈指向 TypeScript 源文件与行号，而不是只有打包后的行号。
- 能断点进入 query 与 action，查看变量和调用栈；优先验证 JavaScriptCore Web Inspector 链路。
- 在应用内显示查询输入、匹配原因、耗时、缓存命中、结果批次、权限拒绝和取消状态。
- 测试面板可模拟慢网、错误码、过期响应、空结果、缺少配置；真实输入回放由开发者显式开启。
- 调试连接默认只在本机、只在显式开发模式开放；生产包不开放远程检查入口。
- 标准模式开发时也遵守权限。不能「开发正常，商店版因沙箱全部失效」。

## 10. 完整文档体系

| 文档分区 | 必备内容 | 完成标准 |
| --- | --- | --- |
| 快速入门 | 环境安装、第一个实时查询、调试、打包、安装 | 新开发者从空目录可复现 |
| 概念 | query/action/view、关键词、结果、生命周期、权限 | 解释为何主框直出及何时执行副作用 |
| SDK 参考 | 每个导出类型、默认值、异常、权限、版本 | 与当前 SDK 自动生成并检查链接 |
| 组件库 | 状态示例、键盘行为、可访问性、事件 | 每个示例在真实宿主有验证记录 |
| 服务接入 | 有道、OAuth、自定义 AI、本地服务 | 明确凭据、网络与错误处理 |
| 调试 | CLI、断点、日志、source map、性能 | 可定位示例中的故意错误 |
| 测试 | Testkit、竞态、网络 mock、包安装测试 | 示例和文档片段在 CI 编译运行 |
| 分发 | manifest、权限、版本、审核、更新、回滚 | 包可通过真实仓库闭环 |
| 迁移 | Script Filter 数据与第三方扩展逻辑迁移 | 支持项与不支持项分别标明 |
| 版本 | changelog、弃用期、兼容表、迁移脚本 | 每次 SDK 变化同步发布 |

文档版本与 SDK 版本绑定；实验 API 使用独立命名与标记。0.x 期间可以调整接口，但必须给出变更记录；稳定 1.x 后遵守语义化版本与弃用策略。

## 11. 第三方生态兼容策略

Alfred：优先适配 Script Filter JSON 中的 title、subtitle、arg、icon 和修饰键动作。执行原工作流脚本仍属于本地可信脚本模式；兼容 JSON 不等于完整兼容工作流图。[Alfred 格式参考](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/)

第三方扩展需要将搜索逻辑迁移到 query，并按 Vectracast SDK 重新声明偏好、权限与动作。依赖 Node 内置模块或专有服务的代码须重写适配器；目前不提供外部 SDK 替代层。

### Vectracast 0.5.0：可搜索动作面板与插件状态

`Action` 新增可选 `icon`（SF Symbol）、`shortcut: { key, modifiers }` 和 `section`。`key` 为单个 ASCII 字符或 `return`，修饰键支持 `command/shift/option/control`；非 Return 必须有 Command 或 Control，避免抢占搜索输入。无效快捷键会被剥离。菜单按动作顺序显示，筛选标题或动作 ID，支持键盘和点击执行。

`application.reveal`、`application.info`、`application.contents` 和 `application.open` 一样必须声明 `applications: ["read", "open"]`，动作 `text` 必须等于同一结果的 `applicationId`，且该 ID 必须在本次查询中由宿主发放。路径只由 broker 注入，动作执行时复查插件启用状态和权限；查询阶段不能调用这些写操作。Finder 简介通过宿主固定操作请求，路径作为独立参数传入；不向插件开放任意脚本执行能力。

`ctx.storage.flags()` 返回本插件的 `Record<string, boolean>`。`storage.toggle` 动作以 `text` 指定键，仅用户执行时切换布尔状态。隔离目录由宿主根据扩展身份决定，不接受插件传入其他扩展 ID。键最多 256 UTF-8 字节，最多 10000 个置真项；原子落盘，取消置真时删除键。适用于插件自己的收藏、固定等轻量状态；查询阶段无法写入。无需额外权限，不提供跨插件读写。
