# ============================================================
#  LKM 统一开发服务器启动脚本 (单窗口并发实时日志)
#
#  用法 (由 dev.bat 转调, 也可直接运行):
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode front   # 仅 SSR 前端
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode site    # 仅静态官网
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode back    # 仅后端
#
#  注意: 本文件须以 UTF-8 带 BOM 保存, 否则 PS5.1 中文会乱码。
# ============================================================

param(
    [ValidateSet("all", "front", "site", "back")]
    [string]$Mode = "all"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrontDir  = Join-Path $RootDir "LKM-official-website"
$SiteDir   = Join-Path $RootDir "LKM-official-static"
$BackDir   = Join-Path $RootDir "LKM-service"

# 静态官网端口, 默认 4322 避免与 SSR 前端 4321 冲突; 可用环境变量 LKM_SITE_PORT 覆盖
$SitePort  = if ($env:LKM_SITE_PORT) { $env:LKM_SITE_PORT } else { 4322 }

function Write-Log {
    # 用 [Console] 直接写终端, 即使被管道/重定向捕获也可见(Write-Host 不会进管道)。
    param([string]$Msg)
    [Console]::WriteLine("[lkm] " + $Msg)
}

function Install-Front {
    # 只负责执行并保持 $LASTEXITCODE 有效, 不返回任何对象,
    # 避免 pnpm 的 stdout 被当作返回值污染上层判断。
    Write-Log "安装前端依赖 (pnpm install) ..."
    [Console]::WriteLine("")
    Push-Location $FrontDir
    & pnpm install
    Pop-Location
}

function Install-Site {
    Write-Log "安装静态官网依赖 (pnpm install) ..."
    [Console]::WriteLine("")
    Push-Location $SiteDir
    & pnpm install
    Pop-Location
}

function Install-Back {
    Write-Log "安装后端依赖 (uv sync) ..."
    [Console]::WriteLine("")
    Push-Location $BackDir
    & uv sync
    Pop-Location
}

Write-Log ("项目根目录: " + $RootDir)
Write-Log ("模式       : " + $Mode)
[Console]::WriteLine()

# ---------- 依赖 ----------
if ($Mode -ne "back") {
    Install-Front
    if ($LASTEXITCODE -ne 0) { [Console]::WriteLine("[lkm:error] 前端依赖安装失败。"); exit 1 }
}
if ($Mode -eq "site" -or $Mode -eq "all") {
    Install-Site
    if ($LASTEXITCODE -ne 0) { [Console]::WriteLine("[lkm:error] 静态官网依赖安装失败。"); exit 1 }
}
if ($Mode -ne "front") {
    Install-Back
    if ($LASTEXITCODE -ne 0) { [Console]::WriteLine("[lkm:error] 后端依赖安装失败。"); exit 1 }
}
[Console]::WriteLine()
Write-Log "依赖就绪。"

# ---------- 后端开发密钥 ----------
# 后端在非测试环境会强制校验 JWT/TOTP 密钥强且非默认, 否则拒绝启动。
# 若未通过环境变量(或 .env)提供, 这里自动生成开发用随机值并注入,
# 让一键启动即可跑通; 已有配置时则不改动。
function New-RandomSecret {
    param([int]$Length = 64)
    $chars = 65..90 + 97..122 + 48..57   # A-Z a-z 0-9
    -join ($chars | Get-Random -Count $Length | ForEach-Object { [char]$_ })
}

# 仅需后端时(back 或 all)才生成后端密钥; site/front 不起后端, 不生成。
if ($Mode -ne "front" -and $Mode -ne "site") {
    if ([string]::IsNullOrWhiteSpace($env:LKM_JWT_SECRET)) {
        $env:LKM_JWT_SECRET = New-RandomSecret 64
        Write-Log "已为开发环境生成 LKM_JWT_SECRET(未检测到配置)。"
    }
    if ([string]::IsNullOrWhiteSpace($env:LKM_TOTP_ENCRYPTION_KEY) -or
        $env:LKM_TOTP_ENCRYPTION_KEY -eq $env:LKM_JWT_SECRET) {
        $env:LKM_TOTP_ENCRYPTION_KEY = New-RandomSecret 64
        Write-Log "已为开发环境生成 LKM_TOTP_ENCRYPTION_KEY。"
    }
    if ([string]::IsNullOrWhiteSpace($env:LKM_VERIFICATION_CODE_PEPPER)) {
        $env:LKM_VERIFICATION_CODE_PEPPER = New-RandomSecret 64
        Write-Log "已为开发环境生成 LKM_VERIFICATION_CODE_PEPPER。"
    }
}

# ---------- 仅前端 / 仅静态官网 / 仅后端: 前台运行 ----------
if ($Mode -eq "front") {
    Write-Log "启动 SSR 前端: pnpm run dev"
    [Console]::WriteLine()
    Set-Location $FrontDir
    & pnpm run dev
    exit $LASTEXITCODE
}
if ($Mode -eq "site") {
    Write-Log "启动静态官网: pnpm run dev --port $SitePort"
    [Console]::WriteLine()
    Set-Location $SiteDir
    & pnpm run dev --port "$SitePort"
    exit $LASTEXITCODE
}
if ($Mode -eq "back") {
    Write-Log "启动后端: uvicorn main:app --reload --port 8000"
    [Console]::WriteLine()
    Set-Location $BackDir
    & uv run uvicorn main:app --reload --port 8000
    exit $LASTEXITCODE
}

# ---------- 同时启动: 三个后台作业, 实时交错打印日志 ----------
Write-Log "同时启动 SSR 前端、静态官网与后端(单窗口实时交错日志)。"
[Console]::WriteLine()
Write-Log "停止: 在本窗口按 Ctrl+C 即可同时结束全部服务。"

$frontJob = Start-Job -Name "lkm-frontend" -ScriptBlock {
    param($dir)
    Set-Location $dir
    # 2>&1 把 stderr 也并入输出流, 确保日志可被收到
    & pnpm run dev *>&1
} -ArgumentList $FrontDir

$siteJob = Start-Job -Name "lkm-static-site" -ScriptBlock {
    param($dir, $port)
    Set-Location $dir
    & pnpm run dev --port "$port" *>&1
} -ArgumentList $SiteDir, $SitePort

$backJob = Start-Job -Name "lkm-backend" -ScriptBlock {
    param($dir)
    Set-Location $dir
    & uv run uvicorn main:app --reload --port 8000 *>&1
} -ArgumentList $BackDir

# 简单取个别名便于在下面循环里打 tag
$frontJobTag = "lkm-frontend"
$siteJobTag  = "lkm-static-site"
$backJobTag  = "lkm-backend"

try {
    # 持续消费三个任务的输出并实时打印; 消费式(不带 -Keep)天然去重
    while ($true) {
        foreach ($job in @($frontJob, $siteJob, $backJob)) {
            $tag = switch ($job.Name) {
                $frontJobTag { "前端" }
                $siteJobTag  { "静态官网" }
                $backJobTag  { "后端" }
            }
            # Receive-Job 返回 stdout; 任务的 stderr 通过 -ErrorVariable 收集
            $err = $null
            Receive-Job $job -ErrorVariable err | ForEach-Object {
                [Console]::WriteLine("[" + $tag + "] " + $_)
            }
            foreach ($e in @($err)) {
                [Console]::WriteLine("[" + $tag + "][err] " + $e.Exception.Message)
            }
            if ($job.State -eq "Failed") {
                [Console]::WriteLine("[" + $tag + "][failed] " + $job.Name)
            }
        }
        # 三个任务都结束时退出
        if (($frontJob.State -in @("Completed", "Failed", "Stopped")) -and
            ($siteJob.State  -in @("Completed", "Failed", "Stopped")) -and
            ($backJob.State  -in @("Completed", "Failed", "Stopped"))) {
            break
        }
        Start-Sleep -Milliseconds 200
    }
}
finally {
    [Console]::WriteLine()
    Write-Log "退出中, 正在停止全部服务(前端/静态官网/后端)..."
    Stop-Job $frontJob, $siteJob, $backJob -ErrorAction SilentlyContinue
    Remove-Job $frontJob, $siteJob, $backJob -Force -ErrorAction SilentlyContinue
    Write-Log "已停止。"
}
