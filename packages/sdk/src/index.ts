/** SDK 0.1. Native host renders query results directly in the launcher. */
export interface Action { id: string; title: string; type: "view.detail" | "catalog.install" | "catalog.refresh" | "url.open" | "clipboard.copy" | "application.open" | "application.reveal" | "application.info" | "application.contents" | "storage.toggle" | "clipboard.history.remove" | "clipboard.history.clear" | "clipboard.history.copy" | "clipboard.history.paste"; text: string; icon?: string; shortcut?: { key: string; modifiers: ("command" | "shift" | "option" | "control")[] }; section?: string }
export interface ClipboardHistoryEntry { id: string; text: string; source: string; timestamp: number; kind?: "text" | "image"; width?: number; height?: number; byteCount?: number; sourceBundleID?: string }
export interface Application { id: string; name: string; bundleIdentifier: string; searchTerms: string[]; urlSchemes?: string[]; documentTypes?: string[] }
export interface ResultItem { id: string; title: string; subtitle?: string; icon?: string; detail?: string; preview?: { text?: string; historyImageID?: string }; metadata?: { label: string; value: string }[]; group?: string; catalogID?: string; applicationId?: string; actions: Action[] }
export interface QueryContext {
  catalog: { list(): Promise<CatalogSnapshot> };
  query: string;
  rawInput: string;
  filter: string;
  /** Matching strictness chosen by the user; plugins retain ownership of ranking. */
  search: { sensitivity: "low" | "medium" | "high" };
  preferences: Record<string, string>;
  secrets: { get(name: string): Promise<string> };
  clipboard: { history(): Promise<ClipboardHistoryEntry[]> };
  storage: { flags(): Promise<Record<string, boolean>> };
  applications: { list(): Promise<Application[]> };
  network: { fetch(url: string, options?: { method?: "GET" | "POST"; headers?: Record<string, string>; body?: string }): Promise<{ status: number; body: string }> };
  crypto: { sha256(value: string): string; uuid(): string };
}
export interface SearchCommand { id: string; query(ctx: QueryContext): Promise<{ items: ResultItem[] }> }
/** Manifest declaration. query commands also receive unclaimed nonempty root input. */
export interface CommandManifest {
  id: string;
  title: string;
  keywords: string[];
  inputMode?: "keyword" | "query";
  /** Run an exact keyword immediately, including when no query follows it. */
  acceptsEmptyQuery?: boolean;
  presentation?: "detail" | "list";
  searchPlaceholder?: string;
  filters?: { id: string; title: string }[];
  /** Trailing-edge delay; host enforces a 200ms minimum. Longer delays are preserved. */
  debounceMs?: number;
}
export interface Extension { commands: SearchCommand[] }
export function defineExtension(extension: Extension): Extension { return extension }
export function defineSearchCommand(command: SearchCommand): SearchCommand { return command }
export function copyAction(text: string): Action { return { id: "copy", title: "复制结果", type: "clipboard.copy", text } }
export function openApplicationAction(application: Application): Action { return { id: "open", title: "打开应用", type: "application.open", text: application.id, icon: "macwindow", shortcut: { key: "return", modifiers: [] } } }

export function removeHistoryAction(entry: ClipboardHistoryEntry): Action { return { id: "delete", title: "删除这条记录", type: "clipboard.history.remove", text: entry.id } }
export function clearHistoryAction(): Action { return { id: "clear", title: "清空全部历史…", type: "clipboard.history.clear", text: "" } }

export function copyHistoryAction(entry: ClipboardHistoryEntry): Action { return {id:"copy",title:entry.kind === "image" ? "复制图片" : "复制内容",type:"clipboard.history.copy",text:entry.id} }
export function pasteHistoryAction(entry: ClipboardHistoryEntry): Action { return {id:"paste",title:"粘贴到上一应用",type:"clipboard.history.paste",text:entry.id} }

/** Verified public catalog data; opaque handles are the only valid installation targets. */
export interface CatalogPlugin {
  handle: string;
  categories: string[];
  manifest: { id: string; name: string; version: string; description: string; icon: string; commands: { id: string; title: string; keywords: string[] }[] };
  permissions: string;
  minimumAppVersion: string;
  installedVersion?: string;
  compatible: boolean;
  sourceURL: string;
  readmeURL: string;
  releaseNotes: string;
}
export interface CatalogSnapshot { repository: string; plugins: CatalogPlugin[] }
export function showDetailAction(): Action { return {id:"details",title:"查看详情",type:"view.detail",text:"",icon:"rectangle.split.2x1",shortcut:{key:"return",modifiers:[]}} }
export function installPluginAction(plugin: CatalogPlugin): Action { return {id:"install",title:plugin.installedVersion ? "更新插件" : "安装插件",type:"catalog.install",text:plugin.handle,icon:"arrow.down.circle",shortcut:{key:"return",modifiers:["command"]}} }
export function openURLAction(id: string, title: string, url: string): Action { return {id,title,type:"url.open",text:url,icon:"globe"} }
