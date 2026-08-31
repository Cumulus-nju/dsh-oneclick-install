# DeepSeek Harness TUI 一键安装器（One-Click Installer）

> 针对 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 官方连接 DeepSeek API 的方式 + 官方公众号收录的 [dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI) 终端界面（默认稳定版 0.9.3，可选 `latest` 尝鲜 beta），做成的 Windows 一键安装/配置脚本。
> 双击 `install.bat` → 在弹出的窗口里粘贴你的 DeepSeek API Key → 自动完成剩余全部步骤，并启动终端 TUI。

[English](#english)

> 📖 **使用说明**：安装过程详解 + TUI 指令速查（`/btw`、`/resume`、`/model` 等斜杠指令全集、快捷键、鼠标、环境变量、常见问题）见 **[docs/使用说明.md](docs/使用说明.md)**。

---

## 它做了什么

| 步骤 | 说明 |
|---|---|
| 1. 检测 Node.js | 要求 `^22.19 || >=24`（dsh-tui 的 engines）；缺失/过旧则自动安装最新 LTS 便携版（免管理员，不动现有 Node） |
| 2. 安装 Harness + TUI | `npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui@<版本>`（官方 CLI + TUI 前端；TUI 默认稳定版 0.9.3，可选 `latest` 尝鲜） |
| 3. 安装 pnpm | 需要 `>=10`（`dsh plugin` 装 profile 依赖用；pnpm 9 会启动即退，见上游 issue #60） |
| 4. 创建 TUI profile | `dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui@<版本>`（`dsh-tui` 命令 = `dsh --profile dsh-tui`；版本与步骤 2 一致） |
| 5. 校验 API Key | 用你填写的 Key 请求 `GET {baseURL}/models`，失败显示具体原因 |
| 6. 写入凭证 | `~/.dsh/.credentials.yaml` 中的 `DEEPSEEK_API_KEY`（官方凭证层，每次请求实时解析，改完立即生效） |
| 7. 写入设置 | 需要时写入 `~/.dsh/settings.yaml` 的 `llm-deepseek` 段（`baseURL` / `reasoningEffort`） |
| 8. 流畅模式 | 写入 `~/.dsh/profiles/dsh-tui/cordis.patch.yml` 性能优化覆盖层（见下） |
| 9. 快捷方式 | 复制启动器并创建桌面快捷方式，启动 TUI |

## 面向新电脑 / 别人电脑的适配

- **无需管理员权限**：Node.js 用便携版装到用户目录；npm 全局包、凭证、profile 全在用户目录下。
- **路径全部动态解析**：不写死任何机器路径（node/npm/pnpm/dsh-tui 均按实际安装位置查找，兼容系统 Node 与便携 Node 两种布局）。
- **兼容 Windows 10/11 + PowerShell 5.1**：脚本只用了 5.1 语法；显式启用 TLS 1.2（老系统 PowerShell 的 https 请求默认会失败）；入口 bat 自带 `-ExecutionPolicy Bypass`，双击即可，无需改系统执行策略。
- **联网环境零准备**：Node 缺失自动下载最新 LTS；`tools/` 放离线包则免下载（见下文）。
- 安装失败会给出具体原因（日志窗口 + 弹窗），不会静默退出。

## TUI 卡顿？已经帮你优化了

你反馈的卡顿主要来自**版本太旧**（旧版 `dsh-cc-tui` 0.3.3 已停止维护）与**状态行高频重绘**。本安装器做了三层处理：

1. **升级到最新版**：安装 `@deepseek-harness-tui/dsh-tui`（默认稳定版 0.9.3；`-TuiVersion latest` 可装尝鲜 beta 0.10.0-beta.1，含 `/vim` 编辑、`/resume` 大改、插件生态等新特性），上游主打「低资源占用、长会话稳定可靠」，并修复了大量渲染与响应性问题（如 ESC 打断卡死等），体验与旧版是两代差距。
2. **流畅模式（默认开启）**：向 TUI profile 写入性能优化覆盖层：
   - `working-activity.publishIntervalMs`: `500 → 1500`（工作状态行刷新率从 2Hz 降到 ~0.7Hz，这是重绘开销大头）
   - `dsh-tui.activityFrames`: `claude → dots`（轻量动画帧）
   - 其余字段按上游文档重写为默认值，不改变行为
   - 覆盖层带标记注释，删掉文件即恢复默认；若你自己改过 `cordis.patch.yml`，安装器**不会**覆盖，会在日志中提示。
3. **可调项**：窗口里可关闭流畅模式；`/settings`（TUI 内）与 `~/.dsh-tui` 下还可用 `DSH_TUI_DISABLE_MOUSE` 等环境变量进一步减负（见上游[配置文档](https://github.com/ccch1mneyyy/dsh-TUI/blob/main/docs/configuration.md)）。

> 其他社区 TUI 项目（如 [tomowang/dsh-tui](https://github.com/tomowang/dsh-tui)、[dsh-claude-tui](https://www.npmjs.com/package/dsh-claude-tui)）可作为备选方案，但 dsh-TUI 是 star 最多（2.6k+）、被官方公众号收录、迭代最活跃的主流选择，本项目以它为准。

## 使用方法

### 一键安装（TUI）

1. 下载本仓库（绿色按钮 `Code → Download ZIP`，或 `git clone`）
2. 双击 **`install.bat`**
3. 在弹出的窗口中填写：
   - **DeepSeek API Key**（必填）：在 [platform.deepseek.com](https://platform.deepseek.com) → API Keys 创建，`sk-` 开头
   - **接口地址 Base URL**（可选）：默认官方 `https://api.deepseek.com`；使用 OpenAI 兼容网关/中转时改成自己的地址（如 `https://api.deepseek.com/v1`）
   - **推理强度 Reasoning Effort**（可选）：`off / low / high / max`，默认不改动
   - **默认模型 Model**（可选）：默认 `deepseek-v4-flash`，可下拉选 `deepseek-v4-pro` / `deepseek-v4-flash-vision-exp`，也可直接输入任意模型名
   - **TUI 版本**（默认稳定版 0.9.3）：可切「尝鲜版 latest」（当前上游 beta 0.10.0-beta.1，含新特性）
   - **流畅模式**（默认勾选）：降低状态行刷新率、轻量动画帧
   - 勾选是否创建桌面快捷方式、是否安装后自动启动
4. 点 **一键安装**，等日志走完即完成 ✅

完成后终端里出现 dsh-TUI 界面（像素鲸鱼顶栏 + 状态行），直接输入问题即可。

### 启动方式

- 桌面快捷方式「DeepSeek Harness TUI」
- 终端运行 `dsh-tui`；恢复上次会话：`dsh-tui --resume`

### 修改配置

换 API Key / 改接口地址：双击 **`configure.bat`**（只改配置，不重新安装），保存后立即生效。

### 命令行模式（自动化/CI）

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Headless `
  -ApiKey "sk-xxxxxxxx" -BaseUrl "https://api.deepseek.com" -ReasoningEffort high -Model deepseek-v4-pro -SmoothMode $true -TuiVersion 0.9.3
```

常用参数：`-ConfigureOnly`（只写配置）、`-TuiVersion <版本>`（`0.9.3` 稳定版默认 / `latest` 尝鲜 beta）、`-NoShortcut`、`-NoLaunch`、`-SkipNodeCheck`、`-SkipNpmInstall`、`-SkipTuiSetup`、`-NoValidate`、`-SmoothMode:$false`（关闭流畅模式）、`-DshHome <路径>`（自定义家目录，测试用）。

### 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1                      # 移除快捷方式与启动器
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveAll           # 连全局包与 profile 一起卸载
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveAll -PurgeHome # 彻底删除（含凭证）
```

## 离线安装

把 Node.js 安装包放进 `tools/` 目录即可离线安装（安装器自动检测，优先 zip，免管理员）：

- `node-v22.x.y-win-x64.zip`（推荐，便携版，解压即用）
- 或 `node-v22.x.y-x64.msi`

> `tools/` 下的安装包已被 `.gitignore` 忽略，不会提交到仓库。dsh / dsh-tui 的 npm 包仍需要联网安装。

## 常见问题

- **执行策略被限制？** 入口 `install.bat` 已带 `-ExecutionPolicy Bypass`，双击即可，无需改系统策略。
- **Key 校验失败（HTTP 401）？** 检查 Key 是否完整、是否有 `sk-` 前缀、账户是否有余额；或在 `platform.deepseek.com` 重新生成。
- **启动后立刻退回 shell？** 大概率是 pnpm 版本过低（需 ≥10）：`npm install -g pnpm@latest` 后重跑安装器。
- **提示 `dsh-tui requires an interactive terminal`？** TUI 必须在真实终端里运行，不要把输出重定向/管道。
- **想升级 TUI？** 重跑 `install.bat`（默认装稳定版 0.9.3，不会擅自升到 beta；想尝鲜在窗口选「尝鲜版 latest」或加 `-TuiVersion latest`），或 TUI 内执行 `/update`；全局命令用 `npm install -g @deepseek-harness-tui/dsh-tui@latest`。
- **为什么装的是 0.9.3 而不是最新？** `@deepseek-harness-tui/dsh-tui` 的 npm `latest` 标签当前指向 beta（0.10.0-beta.1）。本安装器默认钉扎稳定版 0.9.3，避免静默装 beta；要尝鲜用「尝鲜版 latest」选项。
- **想用 Web UI？** `dsh web` 即可（官方自带），本安装器只做 TUI 目标。
- **换电脑/重装？** 凭证只存在本机 `~/.dsh/.credentials.yaml`，备份该文件即可迁移。

## 安全说明

- API Key **只写入本机** `~/.dsh/.credentials.yaml`（Harness 官方凭证文件），**不会上传到任何地方**。
- 安装器不做任何遥测；Harness 遥测可用环境变量 `DSH_TELEMETRY_DISABLED` 关闭（任意非空值即关闭）。

## 文件结构

```
dsh-oneclick-install/
├── install.bat           # 一键安装入口（双击）
├── install.ps1           # 主脚本：GUI 配置窗口 + 安装流程（含 Headless 模式）
├── configure.bat         # 重新配置入口（双击）
├── uninstall.ps1         # 卸载脚本
├── launchers/dsh-tui.bat # TUI 启动器（安装时复制到 ~/.dsh/launchers/）
├── assets/deepseek.ico   # 快捷方式图标
├── docs/使用说明.md       # 安装过程 + TUI 指令速查（/btw 等）
├── tools/                # 可选：放 Node.js 离线安装包
└── README.md
```

## 致谢 / 许可

- 上游：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（MIT）、[ccch1mneyyy/dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI)（MIT）
- 本仓库：MIT License；图标来自 DeepSeek Harness。

---

## English

A Windows one-click installer for DeepSeek Harness with the [dsh-TUI](https://github.com/ccch1mneyyy/dsh-TUI) terminal front-end, mirroring the official way of connecting to the DeepSeek API (credentials in `~/.dsh/.credentials.yaml` as `DEEPSEEK_API_KEY`, optional `llm-deepseek` settings in `~/.dsh/settings.yaml`).

**Usage:** download the repo, double-click `install.bat`, paste your DeepSeek API key into the popup window, click install. It installs Node.js (≥22.19) if needed, runs `npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui`, sets up pnpm (≥10), creates the `dsh-tui` profile, validates your key against `GET {baseURL}/models`, writes credentials/settings, and optionally writes a **performance overlay** (smooth mode: working-activity `publishIntervalMs` 500→1500ms, lighter animation frames) to fix TUI lag — then launches `dsh-tui`. The TUI is pinned to stable `0.9.3` by default (the npm `latest` tag currently points to a beta); pass `-TuiVersion latest` to try the beta.

Headless: `powershell -ExecutionPolicy Bypass -File install.ps1 -Headless -ApiKey "sk-..." -TuiVersion 0.9.3`.

The key is only written to the local credentials file — nothing is uploaded anywhere.
