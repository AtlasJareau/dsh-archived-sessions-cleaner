# DSH 已归档对话清理工具

简体中文 | [English](README.en.md)

一个面向 Windows 的交互式脚本，用来**列出并删除 DeepSeek Harness（DSH）桌面端的“已归档对话”**。删除时会一并处理子代理会话、投影缓存、仅被这些会话引用的附件对象，以及 `workspace.json` 里的归档 / 固定 / 工作区引用。

> [!WARNING]
> 非官方工具，与 DeepSeek 无关。
> **删除不可恢复**：脚本会直接删除会话日志和附件，并且需要结束正在运行的 DSH 进程（未保存的编辑会丢失）。
> 请先备份，并且第一次使用时先加 `-DryRun` 预览。

## 功能

- 先列出全部已归档对话（标题、子会话数、附件数、大小、最后活动时间），再让你选择
- 支持单选、多选（`1,3` / `2-4`）、全部（`a`）、按会话 ID 前缀选择，随时 `q` 退出
- 递归带上子代理会话（沿 `parentSession` 子树）
- 附件只删“仅被选中会话引用”的对象，共享附件保留
- 自动从 `workspace.json` 的 `archivedSessionIds` / `pinnedSessionIds` / 各工作区 `sessionIds` 中摘除对应 id，改动前先备份
- DSH 仍在运行时先询问是否结束；确认进程完全退出后才动文件
- 删除后校验日志目录与注册表是否真的清理干净，失败项会逐条列出

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）或 PowerShell 7+
- 不需要单独安装 Node.js：优先使用 DSH 自带的运行时（`<DSH_HOME>\dsh-runtimes`），找不到时再回退到系统 `node`

## 快速开始

把仓库放到任意目录，**双击**：

```text
delete-archived-sessions.cmd
```

或在终端运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1"
```

第一次建议先预览（不改动任何文件，也不会结束 DSH）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1" -DryRun
```

> `.cmd` 只是包了一层 `powershell -ExecutionPolicy Bypass` 并在结束时 `pause`，方便双击运行。

## 交互示例

```text
  DSH 已归档对话清理
    DSH_HOME: C:\Users\you\.dsh
    检测到 DSH 桌面端正在运行（进程 1234, 5678）。确认删除时会询问是否结束它。

  已归档对话（共 3 个）
  #    标题                          子会话 附件 大小     最后活动         会话 ID
  -------------------------------------------------------------------------------
  1    修复登录页样式                 1      2    618 B    2026-10-02 20:11 01J9ABCD…
  2    重构数据库连接池               0      2    537 B    2026-10-02 19:48 01J9ABCE…
  3    （无标题）                     0      0    0 B      -                01J9ABCF…

  请输入要删除的编号（多选：1,3 或 2-4；a=全部；q=退出）: 1

  待删除会话（2 个，含子代理会话 1 个）
    • 修复登录页样式  01J9ABCD…
      └ 子代理任务  01J9ABCG…

  清理内容
    会话日志目录：2 个
    独占附件对象：1 个（被其他会话引用的会保留）
    workspace.json：archivedSessionIds 3 -> 2

  确认删除以上 2 个会话？删除后无法恢复。 [y/N]: y
  检测到 DSH 仍在运行，需要结束它才能安全删除。现在结束吗？ [Y/n]: y
    正在结束 DSH 进程…
    DSH 已退出。

  完成
    删除成功 4 项，会话 2 个。
    workspace.json 已备份：C:\Users\you\.dsh\storages\workspace.json.bak-20261023-201105
    校验通过：会话日志已从磁盘删除，workspace.json 中已无这些归档记录。
```

## 命令行参数

| 参数 | 说明 |
| --- | --- |
| `-DryRun` | 只预览：列出内容、不改任何文件、也不结束 DSH |
| `-SessionIds <id,...>` | 跳过菜单，直接指定会话（仍会二次确认） |
| `-SkipAttachments` | 不删附件对象，只删日志 / 缓存 / 注册表 |
| `-NoKill` | DSH 在运行时不结束进程，直接退出（退出码 5） |
| `-Yes` | 跳过所有询问：自动结束 DSH 并删除，适合脚本化调用 |
| `-IgnoreDshRunning` | ⚠️ 仅测试用：跳过“DSH 是否在运行”的检测 |

`.cmd` 会把参数原样传递，例如：

```bat
delete-archived-sessions.cmd -DryRun
delete-archived-sessions.cmd -SessionIds 01J9ABCD,01J9ABCE
```

## 它到底删了什么

以 `%DSH_HOME%`（默认 `%USERPROFILE%\.dsh`）为根：

| 位置 | 内容 |
| --- | --- |
| `sessions\<工作区>\<会话id>\` | 会话日志目录（`.jsonl` / `.jsonl.zstd`） |
| `storages\session_projcache\sessions\<会话id>.json` | 侧栏用的投影缓存 |
| `attachments\v1\objects\<前2位>\<sha256>` | 仅被选中会话引用的附件对象 |
| `storages\workspace.json` | `global.archivedSessionIds`、`global.pinnedSessionIds`、各工作区 `sessionIds` 中的对应 id |

删除前会把 `workspace.json` 复制为 `workspace.json.bak-<yyyyMMdd-HHmmss>`。

## 工作原理（简述）

1. 从 `workspace.json` 取得已归档会话 id；
2. 用一个内嵌的 Node 脚本扫描 `sessions` 目录，解码 zstd 分帧日志，读取会话头（`id` / `parentSession` / `title`）；标题按「投影缓存 → 日志头 → 首条用户消息」逐级回退；
3. 沿 `parentSession` 递归收集子代理会话；
4. 统计每个会话引用的附件，算出“只被选中会话引用”的对象；
5. 结束 DSH（如需要）→ 重新读取 `workspace.json` → 备份 → 删除 → 校验。

## 安全设计

- **拒绝在 DSH 内部运行**：检测父进程链，避免“结束 DSH 时把脚本一起杀掉、删到一半”的尴尬情况
- **先确认、再结束进程**：只有确认删除后才会询问是否结束 DSH
- **退出后重读**：DSH 退出时可能重写 `workspace.json`，脚本会重新读取后再修改，避免覆盖最新状态
- **删除前备份、删除后校验**，失败项重试 3 次并逐条列出
- **独占附件判定**：只要附件还被其他会话引用就不会删除

## 常见问题

**Q：删完了侧栏还显示？**
A：重启 DSH。脚本只处理磁盘和 `workspace.json`，运行中的进程内存里可能还留着旧状态（这也是要求先退出 DSH 的原因）。

**Q：提示找不到 node.exe？**
A：安装 Node.js，或确认 DSH 的运行时目录 `<DSH_HOME>\dsh-runtimes` 存在。

**Q：有文件删不掉（被占用）？**
A：确认 DSH 及其子进程已完全退出（任务管理器里没有 `DeepSeek Harness`），再运行一次并选择同一会话；脚本会重试并汇报失败项。

**Q：能撤销吗？**
A：会话日志和附件删除后不可恢复；`workspace.json` 有备份可以直接还原。

**Q：支持 macOS / Linux 吗？**
A：不支持。脚本针对 Windows 上 DSH 桌面端的目录结构和进程模型编写。

## 兼容性

在 Windows 11 + DSH 0.2.1 上测试通过。DSH 升级后如果会话日志格式或 `workspace.json` 结构发生变化，脚本可能需要调整。遇到问题时欢迎提 issue，并附上 `-DryRun` 的输出（请先移除其中的隐私信息）。

## 项目结构

```text
.
├── delete-archived-sessions.ps1   # 主脚本（交互式菜单、删除逻辑）
├── delete-archived-sessions.cmd   # 双击入口
├── README.md                      # 中文说明
├── README.en.md                   # English
├── LICENSE                        # MIT
└── .gitignore / .gitattributes
```

## 许可

[MIT](LICENSE)
