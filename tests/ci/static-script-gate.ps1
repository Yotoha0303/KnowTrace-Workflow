<#
.SYNOPSIS
    静态语法门：仓库内所有运维脚本必须至少能被各自的解析器读懂。

.DESCRIPTION
    背景（M5 三跳链 03 环阻断项 G-6）：
    `backup-all.sh` / `verify-restore.sh` / `security-check.sh` / `log_analyzer.py` /
    `monthly-ops.sh` / 备份恢复 `.ps1` 在 `.github/workflows/` 里**调用 0 处** ——
    它们从来没有被任何自动化门执行过。本脚本是第一层（**低风险静态门**）：
    只做语法解析，不执行脚本、不需要 Docker / 数据库 / curl。

    覆盖：
      *.sh   -> `bash -n`（不执行，只解析）
      *.py   -> `python -m py_compile`（写 __pycache__；CI 是临时工作区，可接受）
      *.ps1  -> PowerShell AST 解析器（`[Parser]::ParseFile`，不执行）

    行为契约（可证伪）：
      * 任一文件解析失败 -> 打印 `FAIL <file>` + 解析器原文 -> 退出码 1；
      * 扫描到的文件数为 0 -> **失败**（空分母不得当作通过，AGENTS.md D3）；
      * 全部通过 -> 退出码 0。

    负向验证（本机实测，见 docs/changes/2026-10-19-M5修复-F9-CI判据.md）：
      往 `scripts/linux/prune-backups.sh` 尾部注入 `if [[ 1 -eq 1 ]`
        -> `bash -n` exit 2 -> 本脚本 exit 1
      往 `scripts/ops/scripts/log_analyzer.py` 尾部注入 `def broken(:`
        -> `py_compile` exit 1 -> 本脚本 exit 1
      往 `services/go-user-system/scripts/ops/backup-postgres.ps1` 尾部注入 `function Broken {`
        -> AST 解析 1 个错误 -> 本脚本 exit 1
      还原后三者均 exit 0。

.NOTES
    在 CI 的 ubuntu runner 上由 `pwsh` 执行（Windows PowerShell 5.1 与 PowerShell 7 都可跑）。
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
}
else {
    $RepositoryRoot = (Resolve-Path $RepositoryRoot).Path
}

# 构建产物与工具产物目录 —— 它们不属于仓库内容，扫描时要跳过。
# 刻意用**名字匹配**而不是 gitignore 解析：本门不依赖 git 是否可用。
$excludedDirectoryNames = @(
    ".git", "node_modules", ".next", "coverage", "test-results",
    "playwright-report", "playwright-report-auth", ".ua", "__pycache__"
)

function Test-ExcludedPath {
    param([string]$FullName)

    $relative = $FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/')
    foreach ($segment in ($relative -split '[\\/]')) {
        if ($excludedDirectoryNames -contains $segment) { return $true }
        # playwright-repeat-*/ 是诊断产物（见 .gitignore）
        if ($segment -like "playwright-repeat-*") { return $true }
    }
    return $false
}

function Get-RepositoryScripts {
    param([string]$Extension)

    $results = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($RepositoryRoot)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $items = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            if ($item.PSIsContainer) {
                if (-not (Test-ExcludedPath -FullName $item.FullName)) {
                    $stack.Push($item.FullName)
                }
            } else {
                if ($item.Extension -eq $Extension -and -not (Test-ExcludedPath -FullName $item.FullName)) {
                    $results.Add($item.FullName)
                }
            }
        }
    }

    $sorted = @($results)
    [Array]::Sort($sorted)
    return $sorted
}

function Invoke-NativeCheck {
    # 为什么要包一层：本脚本是 `$ErrorActionPreference = "Stop"`，而 PowerShell 会把
    # **原生命令的 stderr** 包装成 ErrorRecord；一旦它进了 `2>&1` 管道，就会被当成
    # **终止性错误**抛出，脚本在打印汇总前就死掉（本机实测：注入语法错时只看到
    # NativeCommandError，看不到「受检 N 个 / 失败 M 个」）。
    # 门要的是「**聚合**所有失败后统一报」，不是「撞到第一个就崩」——故在此局部降级。
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $lines
    }
}

function Resolve-BashCommand {
    # 为什么不能直接 `Get-Command bash`：Windows 上 PATH 里的 `bash` 是 **WSL 的存根**
    # （C:\Windows\system32\bash.exe），未装发行版时它对任何输入都返回 exit 1 并打印
    # 「适用于 Linux 的 Windows 子系统没有已安装的分发版」—— 那会把 32 个文件全判成语法错，
    # 是**门自己坏了**而不是脚本坏了（本机实测踩到）。
    #
    # 故逐个**探针**：候选必须真的报告 "GNU bash"。CI（ubuntu-latest）上第一个候选即命中；
    # Windows 本机会跳过 WSL 存根、落到 Git for Windows 的 bash。
    $candidates = New-Object System.Collections.Generic.List[string]
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $onPath) { $candidates.Add($onPath.Source) }
    foreach ($guess in @(
            "$env:ProgramFiles\Git\bin\bash.exe",
            "$env:ProgramFiles\Git\usr\bin\bash.exe",
            "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
            "D:\Git\bin\bash.exe",
            "D:\Git\usr\bin\bash.exe"
        )) {
        if (-not [string]::IsNullOrWhiteSpace($guess) -and (Test-Path -LiteralPath $guess)) {
            $candidates.Add($guess)
        }
    }

    foreach ($candidate in $candidates) {
        # 探针本身也是原生命令：WSL 存根把「未安装发行版」写到 stderr，
        # 必须走同一个降级包装，否则 EAP=Stop 会把它当终止性错误（同上）。
        $probe = Invoke-NativeCheck -Executable $candidate -Arguments @("--version")
        if ($probe.ExitCode -eq 0 -and ($probe.Output -join " ") -match "GNU bash") {
            return $candidate
        }
        # Write-Host 而不是 Write-Output：本函数**返回**的是路径，任何进管道的行都会污染返回值
        # （本机实测：返回变成「诊断行 + 路径」两行，后续 & 调用拿整串当命令名）。
        Write-Host ("   (跳过不是 GNU bash 的候选: {0})" -f $candidate)
    }
    return $null
}

function Resolve-PythonCommand {
    # ubuntu-latest 上 python3 一定在；python 不一定。两者都试，并**把选中的那个打印出来**，
    # 免得「用了哪个解释器」变成推断（AGENTS.md D1）。
    foreach ($candidate in @("python", "python3")) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}

$failures = New-Object System.Collections.Generic.List[string]
$checked = 0

Write-Output "== 静态脚本语法门 =="
Write-Output ("仓库根: {0}" -f $RepositoryRoot)

# ---------------------------------------------------------------- shell
$shellScripts = Get-RepositoryScripts -Extension ".sh"
Write-Output ("`n-- bash -n: {0} 个 .sh --" -f $shellScripts.Count)
if ($shellScripts.Count -eq 0) {
    Write-Output "FAIL 扫描到的 .sh 文件数为 0 —— 空分母不得判绿"
    $failures.Add("空分母: .sh")
}

$bashCommand = Resolve-BashCommand
if ($null -eq $bashCommand) {
    Write-Output "FAIL 找不到可用的 GNU bash —— 缺前置必须失败，不得静默跳过"
    $failures.Add("缺 bash")
}
else {
    Write-Output ("   bash: {0}" -f $bashCommand)
    foreach ($script in $shellScripts) {
        $result = Invoke-NativeCheck -Executable $bashCommand -Arguments @("-n", $script)
        if ($result.ExitCode -ne 0) {
            Write-Output ("FAIL {0} (bash -n exit={1})" -f $script, $result.ExitCode)
            $result.Output | ForEach-Object { Write-Output ("     | {0}" -f $_) }
            $failures.Add($script)
        }

        # UTF-8 BOM 会**通过 bash -n**：内核只认文件头的 `#!` 两个字节，
        # 前面多了 EF BB BF 就不再是有效的解释器路径，在 Linux 上表现为
        # `./x.sh: cannot execute: required file not found` —— 而本机（Git Bash）
        # 与 `bash -n` 都不会报错。2026-10-19 实测踩到：run-criteria.sh 带 BOM，
        # bash -n 与自检全绿，只有真正 `./run-criteria.sh` 才炸。
        # 判据：受检的 .sh 前 3 字节不得是 EF BB BF。
        $head = [System.IO.File]::ReadAllBytes($script)
        if ($head.Length -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            Write-Output ("FAIL {0} (带 UTF-8 BOM：Linux 上 shebang 失效，bash -n 看不见)" -f $script)
            $failures.Add($script)
        }
        $checked += 1
    }
}

# ---------------------------------------------------------------- python
$pythonScripts = Get-RepositoryScripts -Extension ".py"
Write-Output ("`n-- python -m py_compile: {0} 个 .py --" -f $pythonScripts.Count)
if ($pythonScripts.Count -eq 0) {
    Write-Output "FAIL 扫描到的 .py 文件数为 0 —— 空分母不得判绿"
    $failures.Add("空分母: .py")
}

$pythonCommand = Resolve-PythonCommand
if ($null -eq $pythonCommand -and $pythonScripts.Count -gt 0) {
    Write-Output "FAIL 找不到 python / python3"
    $failures.Add("缺 python")
}
elseif ($pythonScripts.Count -gt 0) {
    Write-Output ("   python: {0}" -f $pythonCommand)
    foreach ($script in $pythonScripts) {
        $result = Invoke-NativeCheck -Executable $pythonCommand -Arguments @("-m", "py_compile", $script)
        if ($result.ExitCode -ne 0) {
            Write-Output ("FAIL {0} (py_compile exit={1})" -f $script, $result.ExitCode)
            $result.Output | Select-Object -Last 10 | ForEach-Object { Write-Output ("     | {0}" -f $_) }
            $failures.Add($script)
        }
        $checked += 1
    }
}

# ---------------------------------------------------------------- powershell
$powershellScripts = Get-RepositoryScripts -Extension ".ps1"
Write-Output ("`n-- PowerShell AST 解析: {0} 个 .ps1 --" -f $powershellScripts.Count)
if ($powershellScripts.Count -eq 0) {
    Write-Output "FAIL 扫描到的 .ps1 文件数为 0 —— 空分母不得判绿"
    $failures.Add("空分母: .ps1")
}
else {
    Write-Output ("   host: {0} {1}" -f $PSVersionTable.PSVersion, (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue))
    foreach ($script in $powershellScripts) {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            Write-Output ("FAIL {0} (AST 解析错误 {1} 个)" -f $script, $parseErrors.Count)
            foreach ($parseError in $parseErrors) {
                Write-Output ("     | 第 {0} 行第 {1} 列: {2}" -f `
                        $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
            }
            $failures.Add($script)
        }
        $checked += 1
    }
}

# ---------------------------------------------------------------- 汇总
Write-Output ("`n== 汇总: 受检 {0} 个文件，失败 {1} 个 ==" -f $checked, $failures.Count)
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Output ("FAILED {0}" -f $failure) }
    Write-Output "STATIC_SCRIPT_GATE=FAIL"
    exit 1
}

Write-Output "STATIC_SCRIPT_GATE=PASS"
exit 0
