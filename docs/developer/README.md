# Vectracast SDK 0.1 开发入门

这份教程描述已实现接口。[设计方案](../platform/SDK-SPEC.md)中还有未来 API，不能直接复制到 0.1 使用。

所有用户功能均以插件实现，先阅读[底座与插件的边界](../architecture/PLUGIN-FOUNDATION.md)。应用搜索、计算器、翻译和文本工具均使用同一套 SDK 与安装机制。

插件仓库、公开目录与 GitHub Actions 发布流程见 [仓库与发布](RELEASING.md)。

## 1. 准备宿主

在仓库根目录执行 `npm ci` 和 `npm run app:build`，用 Finder 打开 `build/Vectracast.app`。目前只构建 Apple Silicon 版本。

根目录 `npm run build`、`npm run check`、`npm test` 分别构建应用、检查 SDK 与插件类型、运行平台测试。`npm run dev -- <扩展目录> --accept-permissions` 用于监听指定插件，与 `platform dev` 使用同一入口。

## 2. 从空目录创建一个扩展

```sh
npm run platform -- create ./my-extension
```

目录包含 `extension.json`、`src/index.ts` 和 README。默认模板是离线文本工具。请在 manifest 中把关键词 `up` 改为 `demo`，避免与已安装的示例冲突；扩展 ID 已自动变为 `local.my-extension`。

```sh
npm run platform -- dev ./my-extension --accept-permissions
```

终端出现 `Reloaded` 后，在主窗口输入 `demo Hello`，无需按回车就能看到结果。修改 `src/index.ts` 并保存，CLI 会重新打包、更新本机安装；窗口在约 0.7 秒内重新加载注册表并查询。

编译失败保留上一个成功版本。首次安装必须明确接受权限；监听过程中增加权限会拒绝更新，应检查 manifest 后重新执行开发命令。`Control+C` 停止监听，不会卸载扩展。

已有普通安装不允许开发监听覆盖同版本不同内容。开发前换一个新 ID 或提高版本，再首次用 `dev` 安装；后续开发安装可以更新同版本。开发安装与发布安装目前共用 ID 空间，不要把开发扩展当作不可变发行版本。

## 3. 编写查询

```ts
import { defineExtension, defineSearchCommand, copyAction } from "@platform/sdk";

export default defineExtension({
  commands: [defineSearchCommand({
    id: "transform", // 必须与 manifest 命令 id 一致
    async query({ query }) {
      const text = query.trim();
      return {
        items: text ? [{
          id: "answer",
          title: text.toUpperCase(),
          subtitle: "大写转换",
          icon: "textformat",
          actions: [copyAction(text.toUpperCase())],
        }] : [],
      };
    },
  })],
});
```

这里的 `@platform/sdk` 由仓库 CLI 打包时解析；当前未发布 npm 包，也没有全局安装的 `platform` 命令。示例 TypeScript 类型检查由根目录 `tsconfig.platform.json` 提供；新目录可以加入其 `include`，或建立相同 `paths` 映射的项目配置。

## 4. 打包和安装

```sh
npm run platform -- pack ./my-extension
npm run platform -- install ./my-extension/dist/local.my-extension-0.1.1.launcher-extension --accept-permissions
npm run platform -- list
npm run platform -- query local.my-extension transform "Hello World"
```

安装文件名以 `pack` 输出为准。也可以在扩展管理中点击“安装扩展包”，查看权限后安装。`--accept-permissions` 表示接受包声明的全部能力，CLI 不会自动批准新能力。

更新时提高 `extension.json` 的数字版本号，重新打包安装。回滚使用：

```sh
npm run platform -- rollback local.my-extension
```

保留当前与上一个版本指针；回滚不会回滚偏好设置，也不支持扩展自定义数据库迁移。同版本不同内容在普通安装模式被拒绝。回滚若造成关键词冲突会被拒绝。

## 5. 有道扩展

`extensions/youdao` 使用有道官方文本翻译 API。配置在原生扩展管理中填写，不要写进源代码或提交到 Git。

- 应用 ID：普通配置；应用密钥：macOS 钥匙串。
- `auto`：中英自动互译；其他选项是有道语言代码。
- 输入 `yd 内容`；500ms 防抖，旧请求取消，过期结果不覆盖最新输入。
- 网络错误、额度错误和鉴权错误显示在列表中；`⌘R` 重试。
- 只显示实际返回的译文及可选释义，不补造候选。

接口来源：[有道文本翻译官方文档](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html)。SDK 示例和自动测试使用独立测试数据，不能替代真实凭据联调。

下一步阅读 [API 参考](API.md)、[调试指南](DEBUGGING.md)和[验证边界](VALIDATION.md)。

## 无需关键词执行

在 manifest 命令上声明 `inputMode: "query"`，即可接收非空且没有显式关键词命中的主搜索输入。不匹配时返回空 items。完整入口规则见 [API](API.md#无需关键词的扩展)。[计算器示例](../../extensions/calculator/README.md)包含精确整数运算、进制转换和安装命令。
