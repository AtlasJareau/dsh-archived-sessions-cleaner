# DSH Archived Sessions Cleaner

[简体中文](README.md) | English

An interactive Windows script that **lists and deletes archived conversations of DeepSeek Harness (DSH)**. It also removes delegated (sub-agent) sessions, the sidebar projection cache, attachment objects referenced *only* by those sessions, and the corresponding ids in `workspace.json`.

> [!WARNING]
> Unofficial tool, not affiliated with DeepSeek.
> **Deletion is permanent**: the script removes session logs and attachments from disk, and it has to stop the running DSH process first (unsaved editor state will be lost).
> Back up your data, and always try `-DryRun` first.

The interactive UI and prompts are in Chinese; this file documents the same behaviour in English.

## Features

- Lists all archived conversations (title, delegated-session count, attachment count, size, last activity) before asking what to delete
- Single pick, multiple picks (`1,3`, `2-4`), everything (`a`), or a session-id prefix; `q` to quit
- Recursively includes delegated sessions (the `parentSession` subtree)
- Deletes an attachment only when no other session references it
- Removes ids from `archivedSessionIds`, `pinnedSessionIds` and every workspace's `sessionIds`, with a timestamped backup first
- If DSH is still running, asks before stopping it; waits until the process tree is really gone
- Verifies afterwards that the logs are gone and the registry entries were removed

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- No standalone Node.js needed: the script prefers the runtime bundled with DSH (`<DSH_HOME>\dsh-runtimes`) and falls back to the system `node`

## Quick start

Put the repository anywhere, then **double-click**:

```text
delete-archived-sessions.cmd
```

Or run it from a terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1"
```

Preview first (changes nothing, does not stop DSH):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1" -DryRun
```

> The `.cmd` wrapper just calls `powershell -ExecutionPolicy Bypass` and adds `pause`, so the window stays open.

## Parameters

| Parameter | Description |
| --- | --- |
| `-DryRun` | Preview only: list what would go, touch nothing, do not stop DSH |
| `-SessionIds <id,...>` | Skip the menu and target specific sessions (still asks for confirmation) |
| `-SkipAttachments` | Keep attachment objects; delete only logs / cache / registry entries |
| `-NoKill` | If DSH is running, exit instead of stopping it (exit code 5) |
| `-Yes` | Skip all prompts: stop DSH and delete without asking (for automation) |
| `-IgnoreDshRunning` | ⚠️ Testing only: skip the "is DSH running" check |

The `.cmd` forwards arguments as-is:

```bat
delete-archived-sessions.cmd -DryRun
delete-archived-sessions.cmd -SessionIds 01J9ABCD,01J9ABCE
```

## What exactly gets deleted

Relative to `%DSH_HOME%` (default `%USERPROFILE%\.dsh`):

| Path | Content |
| --- | --- |
| `sessions\<workspace>\<session-id>\` | Session log directory (`.jsonl` / `.jsonl.zstd`) |
| `storages\session_projcache\sessions\<session-id>.json` | Sidebar projection cache |
| `attachments\v1\objects\<first-2-chars>\<sha256>` | Attachment objects referenced only by the selected sessions |
| `storages\workspace.json` | Matching ids in `global.archivedSessionIds`, `global.pinnedSessionIds`, and each workspace's `sessionIds` |

Before editing, `workspace.json` is copied to `workspace.json.bak-<yyyyMMdd-HHmmss>`.

## How it works

1. Reads the archived session ids from `workspace.json`.
2. Runs an embedded Node helper that scans `sessions/`, decodes zstd-framed log files, and reads each session header (`id`, `parentSession`, `title`). Titles fall back through: projection cache → log header → first user message.
3. Walks `parentSession` to collect the full delegated-session subtree.
4. Counts attachment references and keeps only objects that no remaining session uses.
5. Stops DSH when needed → re-reads `workspace.json` → backs it up → deletes files → verifies.

## Safety notes

- **Refuses to run from inside DSH**: it walks its own parent-process chain, because stopping DSH would kill the script mid-deletion.
- **Confirmation before the kill**: DSH is only stopped after you confirm the deletion.
- **Re-read after exit**: DSH may rewrite `workspace.json` on shutdown, so the script re-reads it before modifying.
- **Backup + verification**, with up to 3 retries per file and a per-item failure report.
- **Exclusive-attachment check** prevents deleting files still used by other sessions.

## FAQ

**The sidebar still shows the chat after deleting?**
Restart DSH. The script only changes disk state and `workspace.json`; the running process may still hold the old state in memory — which is why DSH must be closed first.

**"node.exe not found"?**
Install Node.js, or make sure `<DSH_HOME>\dsh-runtimes` exists (DSH ships its own runtime).

**Some files cannot be deleted (in use)?**
Make sure DSH and its child processes are fully gone (no `DeepSeek Harness` in Task Manager), then run again and select the same session; the script retries and reports failures.

**Can I undo it?**
Session logs and attachments are gone for good. `workspace.json` has a backup that can be restored manually.

**macOS / Linux?**
Not supported. The script targets the Windows DSH desktop layout and process model.

## Compatibility

Tested on Windows 11 with DSH 0.2.1. Future DSH releases may change the log format or the `workspace.json` schema; issues are welcome, ideally including `-DryRun` output with private data removed.

## License

[MIT](LICENSE)
