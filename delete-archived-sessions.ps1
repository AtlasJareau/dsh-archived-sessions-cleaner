#Requires -Version 5.1
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    列出并删除 DSH 已归档对话（交互式菜单：单选 / 多选 / 全部）

.DESCRIPTION
    默认用法（双击“delete-archived-sessions.cmd”，或在终端运行本脚本）：
      1. 列出全部已归档对话：编号、标题、子代理会话数、附件数、大小、最后活动时间
      2. 输入编号选择要删除的会话（1,3 / 2-4 / a 全部 / q 退出），也可输入会话 ID 前缀
      3. 显示将删除的会话、附件数量和注册表变化，二次确认（默认 No）
      4. 如果 DSH 桌面端仍在运行，先询问是否结束它；确认后才真正删除
      5. 备份 workspace.json，删除日志目录、投影缓存、独占附件对象，并摘除注册表条目

    删除内容：
      - <DSH_HOME>\sessions\<工作区>\<会话id>\
      - <DSH_HOME>\storages\session_projcache\sessions\<会话id>.json
      - <DSH_HOME>\attachments\v1\objects\<前2位>\<sha256>（仅删“只被这些会话引用”的对象）
      - <DSH_HOME>\storages\workspace.json 里的 archivedSessionIds / pinnedSessionIds / sessionIds

.PARAMETER SessionIds
    跳过菜单，直接指定会话 ID（可多个）；仍会二次确认。

.PARAMETER SkipAttachments
    不动附件对象，只删日志 / 缓存 / 注册表条目。

.PARAMETER DryRun
    只预览：列出内容、不改动任何文件，也不会结束 DSH。

.PARAMETER Yes
    跳过所有询问（自动结束 DSH、自动确认删除），适合脚本化调用。

.PARAMETER NoKill
    DSH 在运行时不结束进程，直接退出。

.PARAMETER IgnoreDshRunning
    危险：跳过“DSH 是否在运行”的检测。仅供测试（例如指向测试用的 DSH_HOME），正常使用不要加。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1"

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\delete-archived-sessions.ps1" -DryRun
#>
[CmdletBinding()]
param(
    [string[]]$SessionIds,
    [switch]$SkipAttachments,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$NoKill,
    [switch]$IgnoreDshRunning
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径与常量
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$sessionsRoot = Join-Path $dshHome 'sessions'
$projCacheRoot = Join-Path $dshHome 'storages\session_projcache\sessions'
$workspaceFile = Join-Path $dshHome 'storages\workspace.json'
$objectsRoot = Join-Path $dshHome 'attachments\v1\objects'
$runtimesRoot = Join-Path $dshHome 'dsh-runtimes'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try { $Host.UI.RawUI.WindowTitle = 'DSH 已归档对话清理' } catch { }

# ---------------------------------------------------------------- 输出辅助
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
}

function Write-Step([string]$Text) { Write-Host ('    ' + $Text) }
function Write-Note([string]$Text) { Write-Host ('    ' + $Text) -ForegroundColor DarkGray }
function Write-WarnLine([string]$Text) { Write-Host ('    ' + $Text) -ForegroundColor Yellow }
function Write-OkLine([string]$Text) { Write-Host ('    ' + $Text) -ForegroundColor Green }

function Get-CharWidth([char]$Ch) {
    $c = [int]$Ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6) -or
        ($c -ge 0x20000 -and $c -le 0x3FFFD)) { return 2 }
    return 1
}

# 按“显示宽度”截断并右侧补空格，保证中文列对齐
function Format-Cell([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = '' }
    $clean = $Text -replace '[\r\n\t]+', ' '
    $builder = New-Object System.Text.StringBuilder
    $used = 0
    foreach ($ch in $clean.ToCharArray()) {
        $w = Get-CharWidth $ch
        if ($used + $w -gt $Width) { break }
        [void]$builder.Append($ch)
        $used += $w
    }
    if ($used -lt $Width) { [void]$builder.Append(' ' * ($Width - $used)) }
    return $builder.ToString()
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# 是 / 否 询问：空回车使用默认值
function Read-Confirm([string]$Prompt, [bool]$DefaultYes) {
    $hint = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host ($Prompt + ' ' + $hint)
        if ($null -eq $answer) { return $DefaultYes }
        $answer = $answer.Trim().ToLowerInvariant()
        if ($answer -eq '') { return $DefaultYes }
        if ($answer -in @('y', 'yes', '是', '好', '1')) { return $true }
        if ($answer -in @('n', 'no', '否', '不', '0')) { return $false }
        Write-WarnLine '请输入 y 或 n。'
    }
}

# ---------------------------------------------------------------- DSH 进程
function Get-DshProcess {
    @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
}

function Get-DshExePath {
    foreach ($p in (Get-DshProcess)) {
        try { if ($p.Path) { return $p.Path } } catch { }
    }
    return $null
}

# 当前脚本是否由 DSH 内部启动（结束 DSH 会连带结束自己）
function Test-UnderDsh {
    $current = $PID
    for ($i = 0; $i -lt 12; $i++) {
        $proc = $null
        try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $current" -ErrorAction Stop } catch { return $false }
        if (-not $proc) { return $false }
        if ($proc.Name -and $proc.Name -match '^DeepSeek Harness') { return $true }
        $parent = [int]$proc.ParentProcessId
        if ($parent -le 0 -or $parent -eq $current) { return $false }
        $current = $parent
    }
    return $false
}

function Stop-DshProcess {
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    foreach ($p in (Get-DshProcess)) {
        try { & $taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (Test-Path -LiteralPath $runtimesRoot) {
        Get-Process -Name 'node' -ErrorAction SilentlyContinue | ForEach-Object {
            $nodePath = $null
            try { $nodePath = $_.Path } catch { }
            if ($nodePath -and $nodePath.StartsWith($runtimesRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
    for ($i = 0; $i -lt 40; $i++) {
        if ((Get-DshProcess).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return ((Get-DshProcess).Count -eq 0)
}

# ---------------------------------------------------------------- Node：扫描会话
$ScanHelper = @'
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const [dshHome, outFile] = process.argv.slice(2);
const MAGIC = [0x28, 0xb5, 0x2f, 0xfd];
const errors = [];

function decodeFrames(buf) {
  const offsets = [];
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === MAGIC[0] && buf[i + 1] === MAGIC[1] && buf[i + 2] === MAGIC[2] && buf[i + 3] === MAGIC[3]) offsets.push(i);
  }
  const parts = [];
  let p = 0;
  while (p < buf.length) {
    let end = -1;
    for (const q of offsets) {
      if (q <= p) continue;
      try { zlib.zstdDecompressSync(buf.subarray(p, q)); end = q; break; } catch { }
    }
    if (end === -1) {
      try { parts.push(zlib.zstdDecompressSync(buf.subarray(p))); } catch { }
      break;
    }
    parts.push(zlib.zstdDecompressSync(buf.subarray(p, end)));
    p = end;
  }
  return Buffer.concat(parts).toString('utf8');
}

function readJsonFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function cacheTitle(id) {
  const j = readJsonFile(path.join(dshHome, 'storages', 'session_projcache', 'sessions', id + '.json'));
  const v = j && j.record && j.record.rows && j.record.rows.title && j.record.rows.title.val;
  return typeof v === 'string' && v.trim() ? v.trim() : null;
}

function userTextFromLog(text) {
  const head = text.length > 400000 ? text.slice(0, 400000) : text;
  const lines = head.split('\n');
  for (const line of lines) {
    const s = line.trim();
    if (s.length < 2 || s.charCodeAt(0) !== 123) continue;
    let obj;
    try { obj = JSON.parse(s); } catch { continue; }
    const stack = [[obj, 0]];
    let visited = 0;
    while (stack.length > 0) {
      const [node, depth] = stack.pop();
      if (++visited > 3000) break;
      if (!node || typeof node !== 'object') continue;
      if (Array.isArray(node)) {
        if (depth < 10) for (const v of node) stack.push([v, depth + 1]);
        continue;
      }
      if (node.role === 'user') {
        const c = node.content;
        if (typeof c === 'string' && c.trim()) return c.trim();
        if (Array.isArray(c)) {
          for (const part of c) {
            if (part && typeof part.text === 'string' && part.text.trim()) return part.text.trim();
          }
        }
        if (typeof node.text === 'string' && node.text.trim()) return node.text.trim();
      }
      if (depth < 10) for (const k of Object.keys(node)) stack.push([node[k], depth + 1]);
    }
  }
  return null;
}

const sessionsRoot = path.join(dshHome, 'sessions');
const records = [];
if (fs.existsSync(sessionsRoot)) {
  for (const wsDir of fs.readdirSync(sessionsRoot)) {
    const wsPath = path.join(sessionsRoot, wsDir);
    let wsStat;
    try { wsStat = fs.statSync(wsPath); } catch { continue; }
    if (!wsStat.isDirectory()) continue;
    for (const sid of fs.readdirSync(wsPath)) {
      const dir = path.join(wsPath, sid);
      let st;
      try { st = fs.statSync(dir); } catch { continue; }
      if (!st.isDirectory()) continue;
      let log = null;
      try { log = fs.readdirSync(dir).find((f) => /^session(\.v\d+)?\.jsonl(\.zstd)?$/.test(f)); } catch { }
      if (!log) continue;
      const logPath = path.join(dir, log);
      let raw;
      try { raw = fs.readFileSync(logPath); } catch (e) { errors.push({ file: logPath, message: String(e && e.message) }); continue; }
      let text = '';
      let decoded = false;
      try {
        text = log.endsWith('.zstd') ? decodeFrames(raw) : raw.toString('utf8');
        decoded = true;
      } catch (e) { errors.push({ file: logPath, message: String(e && e.message) }); }
      let header = {};
      let headerOk = false;
      try {
        const first = text.split('\n')[0];
        const parsed = JSON.parse(first);
        header = parsed && parsed.data && parsed.data.id ? parsed.data : parsed;
        headerOk = typeof header.id === 'string';
      } catch { }
      const attachments = new Set();
      for (const m of text.matchAll(/"attachmentId":"sha256:([0-9a-f]{64})"/g)) attachments.add(m[1]);
      let title = typeof header.title === 'string' && header.title.trim() ? header.title.trim() : null;
      if (!title) title = cacheTitle(headerOk ? header.id : sid);
      if (!title && text) title = userTextFromLog(text);
      let mtimeMs = null;
      try { mtimeMs = fs.statSync(logPath).mtimeMs; } catch { }
      records.push({
        wsDir: wsDir,
        dir: sid,
        log: log,
        id: headerOk ? String(header.id) : sid,
        idFromHeader: headerOk,
        parent: header.parentSession ?? null,
        depth: header.delegationDepth ?? 0,
        origin: header.origin ?? null,
        title: title ? String(title).slice(0, 200) : null,
        sizeBytes: raw.length,
        lastActivityMs: mtimeMs,
        decoded: decoded,
        attachments: [...attachments],
      });
    }
  }
}
fs.writeFileSync(outFile, JSON.stringify({ records, errors }, null, 2), 'utf8');
'@

function Resolve-Node {
    $candidates = @()
    $candidates += Get-ChildItem -Path $runtimesRoot -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\dependencies\node\bin\node.exe' } | Select-Object -ExpandProperty FullName
    $candidates += (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    foreach ($candidate in $candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate } }
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-SessionScan {
    $node = Resolve-Node
    if (-not $node) { throw '找不到 node.exe（DSH 自带运行时或系统 Node）。请安装 Node 或设置 PATH 后重试。' }
    $tempRoot = [System.IO.Path]::GetTempPath()
    $stamp = [guid]::NewGuid().ToString('N')
    $helperPath = Join-Path $tempRoot "dsh-cleanup-$stamp.mjs"
    $planPath = Join-Path $tempRoot "dsh-cleanup-$stamp.json"
    [System.IO.File]::WriteAllText($helperPath, $script:ScanHelper, $utf8NoBom)
    try {
        & $node $helperPath $dshHome $planPath
        if ($LASTEXITCODE -ne 0) { throw "解析会话日志失败（node 退出码 $LASTEXITCODE）" }
        $json = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8
        return ($json | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $helperPath, $planPath -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- workspace.json
function Read-Workspace {
    if (-not (Test-Path -LiteralPath $workspaceFile)) { throw "找不到 $workspaceFile" }
    return (Get-Content -LiteralPath $workspaceFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-CacheTitle([string]$Id) {
    $file = Join-Path $projCacheRoot ($Id + '.json')
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $value = $obj.record.rows.title.val
        if ($value -is [string] -and $value.Trim()) { return $value.Trim() }
    } catch { }
    return $null
}

function Set-GlobalIds($Workspace, [string]$Name, $Values) {
    $globalNode = $Workspace.global
    if ($globalNode.PSObject.Properties.Name -contains $Name) {
        $globalNode.$Name = @($Values)
    } else {
        $globalNode | Add-Member -NotePropertyName $Name -NotePropertyValue @($Values)
    }
}

# ---------------------------------------------------------------- 选择菜单
function Show-SessionTable($Items, [int]$TitleWidth) {
    $header = (Format-Cell '#' 4) + ' ' + (Format-Cell '标题' $TitleWidth) + ' ' +
        (Format-Cell '子会话' 6) + ' ' + (Format-Cell '附件' 4) + ' ' +
        (Format-Cell '大小' 8) + ' ' + (Format-Cell '最后活动' 16) + ' ' + '会话 ID'
    Write-Host ('  ' + $header) -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * ((Get-DisplaySafeWidth $header)))) -ForegroundColor DarkGray
    foreach ($item in $Items) {
        $last = if ($item.Last) { $item.Last.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        $line = (Format-Cell ([string]$item.Number) 4) + ' ' + (Format-Cell $item.Title $TitleWidth) + ' ' +
            (Format-Cell ([string]$item.Subs) 6) + ' ' + (Format-Cell ([string]$item.Atts) 4) + ' ' +
            (Format-Cell (Format-Size $item.Size) 8) + ' ' + (Format-Cell $last 16) + ' ' + $item.ShortId
        Write-Host ('  ' + $line)
        if (-not $item.OnDisk) { Write-Note ('     ^ 该会话在磁盘上已找不到日志，只会清理注册表条目') }
    }
}

# 粗略估算整行显示宽度（用于画分隔线）
function Get-DisplaySafeWidth([string]$Text) {
    $width = 0
    foreach ($ch in $Text.ToCharArray()) { $width += (Get-CharWidth $ch) }
    return $width
}

function Read-Selection($Items) {
    $max = $Items.Count
    while ($true) {
        Write-Host ''
        $raw = Read-Host '  请输入要删除的编号（多选：1,3 或 2-4；a=全部；q=退出）'
        if ($null -eq $raw) { return 'CANCEL' }
        $text = $raw.Trim()
        if ($text -eq '') { Write-WarnLine '输入为空，请重新输入。'; continue }
        $lower = $text.ToLowerInvariant()
        if ($lower -in @('q', 'quit', 'exit', '退出')) { return 'CANCEL' }
        if ($lower -in @('a', 'all', '*', '全部', '所有')) {
            return @($Items | ForEach-Object { [int]$_.Number })
        }
        $tokens = @($text -split '[,，;；\s]+' | Where-Object { $_ -ne '' })
        $picked = [System.Collections.Generic.List[int]]::new()
        $bad = $null
        foreach ($token in $tokens) {
            if ($token -match '^(\d+)\s*-\s*(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                if ($start -gt $end) { $tmp = $start; $start = $end; $end = $tmp }
                if ($start -lt 1 -or $end -gt $max) { $bad = "编号超出范围：$token（有效范围 1-$max）"; break }
                for ($i = $start; $i -le $end; $i++) { if (-not $picked.Contains($i)) { $picked.Add($i) } }
                continue
            }
            if ($token -match '^\d+$') {
                $n = [int]$token
                if ($n -lt 1 -or $n -gt $max) { $bad = "编号超出范围：$n（有效范围 1-$max）"; break }
                if (-not $picked.Contains($n)) { $picked.Add($n) }
                continue
            }
            if ($token.Length -lt 4) { $bad = "无法识别的输入：$token"; break }
            $matched = @($Items | Where-Object { $_.Id -like ($token + '*') })
            if ($matched.Count -eq 0) { $bad = "没有以 $token 开头的会话 ID"; break }
            if ($matched.Count -gt 1) { $bad = "ID 前缀 $token 匹配到多个会话，请改用编号"; break }
            $number = [int]$matched[0].Number
            if (-not $picked.Contains($number)) { $picked.Add($number) }
        }
        if ($bad) { Write-WarnLine $bad; continue }
        if ($picked.Count -eq 0) { Write-WarnLine '没有选择任何会话。'; continue }
        return @($picked | Sort-Object)
    }
}

# ---------------------------------------------------------------- 计划构建
function Build-Plan([string[]]$Targets) {
    $selected = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($t in $Targets) { if ($t) { [void]$selected.Add([string]$t) } }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($record in $script:Records) {
            $rid = [string]$record.id
            if ($selected.Contains($rid)) { continue }
            if ($record.parent -and $selected.Contains([string]$record.parent)) {
                [void]$selected.Add($rid)
                $grew = $true
            }
        }
    }

    # 按“目标 → 其子会话（深度优先）”顺序输出，子会话紧跟父会话
    $sessionItems = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    function Add-PlanNode([string]$nodeId) {
        if ($seen.Contains($nodeId)) { return }
        [void]$seen.Add($nodeId)
        $record = $script:BySessionId[$nodeId]
        if ($record) {
            [void]$sessionItems.Add([pscustomobject]@{
                    Id              = $nodeId
                    Title           = Get-SessionTitle $record
                    Parent          = $record.parent
                    IsChild         = [bool]$record.parent
                    Dir             = Join-Path (Join-Path $sessionsRoot $record.wsDir) $record.dir
                    AttachmentCount = @($record.attachments).Count
                    OnDisk          = $true
                })
            $kids = $script:ChildMap[$nodeId]
            if ($kids) {
                foreach ($child in $kids) { if ($child) { Add-PlanNode ([string]$child.id) } }
            }
        } else {
            [void]$sessionItems.Add([pscustomobject]@{
                    Id              = $nodeId
                    Title           = Get-CacheTitle $nodeId
                    Parent          = $null
                    IsChild         = $false
                    Dir             = $null
                    AttachmentCount = 0
                    OnDisk          = $false
                })
        }
    }

    foreach ($t in $Targets) { if ($t) { Add-PlanNode ([string]$t) } }

    # 只被选中会话引用的附件对象才可删
    $selectedAtt = [System.Collections.Generic.HashSet[string]]::new()
    $otherAtt = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($record in $script:Records) {
        if ($selected.Contains([string]$record.id)) { $bucket = $selectedAtt } else { $bucket = $otherAtt }
        foreach ($hash in @($record.attachments)) {
            if ($hash) { [void]$bucket.Add([string]$hash) }
        }
    }
    $deletableAtt = @($selectedAtt | Where-Object { -not $otherAtt.Contains($_) })

    return [pscustomobject]@{
        Selected    = $selected
        Sessions    = $sessionItems
        Attachments = $deletableAtt
        Missing     = @($sessionItems | Where-Object { -not $_.OnDisk } | ForEach-Object { $_.Id })
    }
}

function Get-SessionTitle($Record) {
    if ($Record.title) { return $Record.title }
    $cached = Get-CacheTitle ([string]$Record.id)
    if ($cached) { return $cached }
    return '（无标题）'
}

# ================================================================ 主流程
$running = @(Get-DshProcess)
$dshExe = Get-DshExePath

Write-Title 'DSH 已归档对话清理'
Write-Note ('DSH_HOME: ' + $dshHome)
if ($running.Count -gt 0) {
    $runningText = ($running | ForEach-Object { "$($_.Id)" }) -join ', '
    if ($IgnoreDshRunning) {
        Write-WarnLine ("注意：DSH 正在运行（进程 {0}），已用 -IgnoreDshRunning 跳过检测。" -f $runningText)
    } else {
        $notice = if ($DryRun) { '预览模式不会结束它。' } else { '确认删除时会询问是否结束它。' }
        Write-WarnLine ("检测到 DSH 桌面端正在运行（进程 {0}）。{1}" -f $runningText, $notice)
    }
}

# 防止在 DSH 内部启动：结束 DSH 会把脚本一起杀掉，删一半
if (-not $DryRun -and -not $IgnoreDshRunning -and (Test-UnderDsh)) {
    Write-Host ''
    Write-WarnLine '本脚本是从 DSH 内部启动的：结束 DSH 会同时结束本脚本，导致删除中断。'
    Write-WarnLine '请在 Windows Terminal 里运行，或直接双击“delete-archived-sessions.cmd”。'
    exit 4
}

$workspace = Read-Workspace
$archivedAll = @($workspace.global.archivedSessionIds | Where-Object { $_ })

$interactive = -not ($SessionIds -and @($SessionIds).Count -gt 0)
if ($interactive -and $archivedAll.Count -eq 0) {
    Write-Host ''
    Write-OkLine '当前没有已归档对话（archivedSessionIds 为空），无需清理。'
    exit 0
}

# ---------------------------------------------------------------- 扫描会话
try {
    $scan = Invoke-SessionScan
} catch {
    Write-Host ''
    Write-WarnLine ('扫描会话失败：' + $_.Exception.Message)
    exit 3
}

$script:Records = @($scan.records)
if ($scan.errors -and @($scan.errors).Count -gt 0) {
    Write-WarnLine ("有 {0} 个日志解析失败（仍会按目录删除）：" -f @($scan.errors).Count)
}

$script:BySessionId = @{}
$script:ChildMap = @{}
foreach ($record in $script:Records) {
    $rid = [string]$record.id
    if (-not $script:BySessionId.ContainsKey($rid)) { $script:BySessionId[$rid] = $record }
    $parentId = [string]$record.parent
    if ($parentId) {
        if (-not $script:ChildMap.ContainsKey($parentId)) {
            $script:ChildMap[$parentId] = [System.Collections.Generic.List[object]]::new()
        }
        $script:ChildMap[$parentId].Add($record)
    }
}

$script:ChildCountCache = @{}
function Get-DescendantCount([string]$Id) {
    if ($script:ChildCountCache.ContainsKey($Id)) { return $script:ChildCountCache[$Id] }
    $count = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Id)
    $guard = 0
    while ($stack.Count -gt 0 -and $guard -lt 10000) {
        $guard++
        $current = $stack.Pop()
        foreach ($child in @($script:ChildMap[$current])) {
            if ($child) { $count++; $stack.Push([string]$child.id) }
        }
    }
    $script:ChildCountCache[$Id] = $count
    return $count
}

# ---------------------------------------------------------------- 列出 / 选择
if ($interactive) {
    $order = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $archivedAll) { if ($id -and -not $order.Contains([string]$id)) { $order.Add([string]$id) } }

    $consoleWidth = 110
    try { $consoleWidth = [int]$Host.UI.RawUI.WindowSize.Width } catch { }
    if ($consoleWidth -lt 80) { $consoleWidth = 110 }
    $titleWidth = $consoleWidth - 60
    if ($titleWidth -lt 18) { $titleWidth = 18 }
    if ($titleWidth -gt 60) { $titleWidth = 60 }

    $items = [System.Collections.Generic.List[object]]::new()
    $number = 0
    foreach ($id in $order) {
        $number++
        $record = $script:BySessionId[[string]$id]
        $title = if ($record) { Get-SessionTitle $record } else { Get-CacheTitle ([string]$id) }
        if (-not $title) { $title = '（无标题）' }
        $subs = if ($record) { Get-DescendantCount ([string]$id) } else { 0 }
        $atts = if ($record) { @($record.attachments).Count } else { 0 }
        $size = if ($record) { [double]$record.sizeBytes } else { 0 }
        $last = $null
        if ($record -and $record.lastActivityMs) { $last = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$record.lastActivityMs).LocalDateTime }
        $shortId = if (([string]$id).Length -gt 12) { ([string]$id).Substring(0, 10) + '…' } else { [string]$id }
        $items.Add([pscustomobject]@{
                Number  = $number
                Id      = [string]$id
                Title   = $title
                Subs    = $subs
                Atts    = $atts
                Size    = $size
                Last    = $last
                ShortId = $shortId
                OnDisk  = [bool]$record
            })
    }

    Write-Title ("已归档对话（共 {0} 个）" -f $items.Count)
    Show-SessionTable $items $titleWidth

    $pickedNumbers = Read-Selection $items
    if ($pickedNumbers -is [string]) {
        Write-Host ''
        Write-Note '已退出，未做任何改动。'
        exit 0
    }
    $targets = @($pickedNumbers | ForEach-Object { $items[$_ - 1].Id } | Select-Object -Unique)
} else {
    $targets = @($SessionIds | Where-Object { $_ } | Select-Object -Unique)
    $items = $null
}

if (@($targets).Count -eq 0) {
    Write-Host ''
    Write-Note '没有要删除的会话，退出。'
    exit 0
}

# ---------------------------------------------------------------- 预览计划
$plan = Build-Plan $targets
$sessionCount = $plan.Sessions.Count
$childCount = @($plan.Sessions | Where-Object { $_.IsChild }).Count
$deletableAtt = @($plan.Attachments)
if ($SkipAttachments) { $deletableAtt = @() }

Write-Title ("待删除会话（{0} 个，含子代理会话 {1} 个）" -f $sessionCount, $childCount)
foreach ($session in $plan.Sessions) {
    $prefix = if ($session.IsChild) { '      └ ' } else { '    • ' }
    $titleText = $session.Title
    if ($null -eq $titleText) { $titleText = '（无标题）' }
    Write-Host ($prefix + $titleText) -NoNewline
    Write-Host ('  ' + $session.Id) -ForegroundColor DarkGray
}
if (@($plan.Missing).Count -gt 0) {
    Write-Note ("其中 {0} 个在磁盘上找不到日志，只会清理注册表条目。" -f @($plan.Missing).Count)
}

# 清理后的注册表状态（按当前读到的 workspace.json 估算）
$preArchived = @($workspace.global.archivedSessionIds | Where-Object { $_ })
$prePinned = @($workspace.global.pinnedSessionIds | Where-Object { $_ })
$deleteIds = @($plan.Sessions | ForEach-Object { [string]$_.Id })
$preArchivedKeep = @($preArchived | Where-Object { $deleteIds -notcontains $_ })

Write-Title '清理内容'
Write-Step ("会话日志目录：{0} 个" -f @($plan.Sessions | Where-Object { $_.OnDisk }).Count)
if ($SkipAttachments) {
    Write-Step '附件对象：已用 -SkipAttachments 跳过'
} else {
    Write-Step ("独占附件对象：{0} 个（被其他会话引用的会保留）" -f $deletableAtt.Count)
}
Write-Step ("workspace.json：archivedSessionIds {0} -> {1}" -f $preArchived.Count, $preArchivedKeep.Count)
if ($prePinned.Count -gt 0) { Write-Step ("pinnedSessionIds：{0} -> {1}" -f $prePinned.Count, (@($prePinned | Where-Object { $deleteIds -notcontains $_ }).Count)) }

if ($DryRun) {
    Write-Host ''
    Write-Host '  【预览模式 -DryRun】以上内容不会被删除，workspace.json 也不会改动。' -ForegroundColor Yellow
    Write-Host '  去掉 -DryRun（或直接双击 .cmd）即可真正执行。' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- 二次确认
Write-Host ''
if (-not $Yes) {
    if (-not (Read-Confirm ("确认删除以上 {0} 个会话？删除后无法恢复。" -f $sessionCount) $false)) {
        Write-Host ''
        Write-Note '已取消，未做任何改动。'
        exit 0
    }
}

# ---------------------------------------------------------------- 结束 DSH
$killedDsh = $false
if (-not $IgnoreDshRunning -and (Get-DshProcess).Count -gt 0) {
    if ($NoKill) {
        Write-Host ''
        Write-WarnLine 'DSH 仍在运行（-NoKill）：请先完全退出 DSH 后重试。'
        exit 5
    }
    if (-not $Yes) {
        Write-Host ''
        if (-not (Read-Confirm '检测到 DSH 仍在运行，需要结束它才能安全删除。现在结束吗？' $true)) {
            Write-Note '已取消：请手动退出 DSH 后重新运行本脚本。'
            exit 0
        }
    }
    Write-Step '正在结束 DSH 进程…'
    if (-not (Stop-DshProcess)) {
        Write-WarnLine 'DSH 进程没有完全退出，已中止，未删除任何文件。'
        exit 6
    }
    $killedDsh = $true
    Start-Sleep -Milliseconds 800
    # 重新读取，避免覆盖 DSH 退出时写回的最新状态
    try {
        $workspace = Read-Workspace
        $preArchived = @($workspace.global.archivedSessionIds | Where-Object { $_ })
        $prePinned = @($workspace.global.pinnedSessionIds | Where-Object { $_ })
        $preArchivedKeep = @($preArchived | Where-Object { $deleteIds -notcontains $_ })
    } catch {
        Write-WarnLine ('DSH 退出后重新读取 workspace.json 失败：' + $_.Exception.Message)
        exit 7
    }
    Write-OkLine 'DSH 已退出。'
}

# ---------------------------------------------------------------- 执行删除
$backup = "$workspaceFile.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -LiteralPath $workspaceFile -Destination $backup -Force

# 注册表：摘除 id
$removedWorkspaces = [System.Collections.Generic.List[string]]::new()
if ($workspace.tables -and $workspace.tables.workspaces) {
    foreach ($prop in $workspace.tables.workspaces.PSObject.Properties) {
        $ws = $prop.Value
        $existing = @($ws.sessionIds | Where-Object { $_ })
        $keep = @($existing | Where-Object { $deleteIds -notcontains $_ })
        if ($keep.Count -ne $existing.Count) {
            $removedWorkspaces.Add($prop.Name)
            $ws.sessionIds = @($keep)
            $ws.updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
    }
}
Set-GlobalIds $workspace 'archivedSessionIds' $preArchivedKeep
Set-GlobalIds $workspace 'pinnedSessionIds' @($prePinned | Where-Object { $deleteIds -notcontains $_ })

$json = $workspace | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($workspaceFile, $json, $utf8NoBom)

# 文件清单
$paths = [System.Collections.Generic.List[string]]::new()
foreach ($session in $plan.Sessions) {
    if ($session.Dir -and (Test-Path -LiteralPath $session.Dir)) {
        $paths.Add($session.Dir)
    }
    $cacheFile = Join-Path $projCacheRoot ($session.Id + '.json')
    if (Test-Path -LiteralPath $cacheFile) { $paths.Add($cacheFile) }
}
foreach ($hash in $deletableAtt) {
    $file = Join-Path (Join-Path $objectsRoot $hash.Substring(0, 2)) $hash
    if (Test-Path -LiteralPath $file) { $paths.Add($file) }
}

$deleted = 0
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $ok = $true
            $deleted++
        } catch {
            if ($attempt -lt 3) { Start-Sleep -Milliseconds 400 }
        }
    }
    if (-not $ok) { $failed.Add($path) }
}

# 清理空目录
foreach ($root in @($sessionsRoot, $objectsRoot)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = $_
        if (-not (Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- 校验
$remaining = @()
foreach ($session in $plan.Sessions) {
    if ($session.Dir -and (Test-Path -LiteralPath $session.Dir)) { $remaining += $session.Id }
}

$verifyOk = $true
try {
    $after = Read-Workspace
    $stillArchived = @($after.global.archivedSessionIds | Where-Object { $deleteIds -contains $_ })
    if ($stillArchived.Count -gt 0) { $verifyOk = $false }
} catch {
    $verifyOk = $false
}

Write-Title '完成'
Write-Step ("删除成功 {0} 项，会话 {1} 个。" -f $deleted, $sessionCount)
Write-Step ("workspace.json 已备份：{0}" -f $backup)
if ($removedWorkspaces.Count -gt 0) {
    Write-Step ("已从这些工作区的 sessionIds 中摘除：{0}" -f ($removedWorkspaces -join ', '))
}
if ($remaining.Count -gt 0) {
    Write-WarnLine ("有 {0} 个会话的日志目录仍存在：{1}" -f $remaining.Count, ($remaining -join ', '))
    Write-WarnLine '通常是文件被占用，可稍后重新运行（选择同一会话）再删一次。'
}
if ($failed.Count -gt 0) {
    Write-WarnLine ("有 {0} 项删除失败：" -f $failed.Count)
    foreach ($path in $failed) { Write-Note $path }
}
if ($remaining.Count -eq 0 -and $failed.Count -eq 0 -and $verifyOk) {
    Write-OkLine ("校验通过：会话日志已从磁盘删除，workspace.json 中已无这些归档记录。")
} elseif (-not $verifyOk) {
    Write-WarnLine '校验：workspace.json 里仍能找到这些归档 id，请检查上面的警告。'
}

$hasProblem = ($remaining.Count -gt 0) -or ($failed.Count -gt 0) -or (-not $verifyOk)

if ($killedDsh -and $dshExe) {
    Write-Host ''
    if ($Yes -or (Read-Confirm '是否现在重新启动 DSH？' $false)) {
        try {
            Start-Process -FilePath $dshExe
            Write-OkLine '已重新启动 DSH。'
        } catch {
            Write-WarnLine ('启动 DSH 失败：' + $_.Exception.Message)
        }
    }
}

if ($hasProblem) { exit 1 }
exit 0
