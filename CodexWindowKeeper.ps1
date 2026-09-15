# CodexWindowKeeper.ps1 - v2
# Consulta a janela REAL de uso do Codex via `codex app-server`.
# So envia um ping quando a janela de 5 horas (300 min) ja terminou.
# O ping usa GPT-5.6 Luna + reasoning none e configuracao minima.

$ErrorActionPreference = "Stop"

$Version = "2.2.0"
$AppDir = Join-Path $env:LOCALAPPDATA "CodexWindowKeeper"
$StateFile = Join-Path $AppDir "state.json"
$LogFile = Join-Path $AppDir "keeper.log"

$Prompt = "Responda somente OK."
$TimeoutSeconds = 120
$FallbackInterval = [TimeSpan]::FromHours(5)

New-Item -ItemType Directory -Path $AppDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Write-Log "=== CodexWindowKeeper v$Version iniciado ==="

function Get-CodexPath {
    $cmd = Get-Command codex -ErrorAction Stop
    if (-not $cmd.Source) {
        throw "Nao foi possivel localizar o comando 'codex'."
    }
    return $cmd.Source
}

function Read-JsonRpcResponse {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$Id,
        [int]$TimeoutSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(
            1,
            ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        )

        $readTask = $Process.StandardOutput.ReadLineAsync()

        if (-not $readTask.Wait($remaining)) {
            throw "Timeout esperando resposta JSON-RPC id=$Id."
        }

        $line = $readTask.Result
        if ($null -eq $line) {
            throw "codex app-server encerrou antes da resposta id=$Id."
        }

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $obj = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($null -ne $obj.id -and [string]$obj.id -eq [string]$Id) {
            if ($obj.error) {
                throw "Erro JSON-RPC id=${Id}: $($obj.error | ConvertTo-Json -Compress)"
            }
            return $obj
        }
    }

    throw "Timeout esperando resposta JSON-RPC id=$Id."
}

function Get-CodexFiveHourWindow {
    param([string]$CodexPath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CodexPath
    $psi.Arguments = "app-server --stdio"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    # Nao precisamos capturar stderr para a consulta de quota. Deixa-lo sem
    # redirecionamento evita que um pipe de diagnostico cheio bloqueie o app-server.
    $psi.RedirectStandardError = $false

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Nao foi possivel iniciar codex app-server."
        }

        $initialize = @{
            id = 1
            method = "initialize"
            params = @{
                clientInfo = @{
                    name = "codex-window-keeper"
                    title = "Codex Window Keeper"
                    version = $Version
                }
                capabilities = @{
                    experimentalApi = $false
                }
            }
        } | ConvertTo-Json -Compress -Depth 8

        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()

        [void](Read-JsonRpcResponse -Process $process -Id 1 -TimeoutSeconds 20)

        $initialized = @{
            method = "initialized"
        } | ConvertTo-Json -Compress -Depth 4

        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.Flush()

        $request = @{
            id = 2
            method = "account/rateLimits/read"
        } | ConvertTo-Json -Compress -Depth 4

        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()

        $response = Read-JsonRpcResponse -Process $process -Id 2 -TimeoutSeconds 30
        $result = $response.result

        if (-not $result) {
            throw "account/rateLimits/read nao retornou result."
        }

        # Primeiro tenta o bucket explicito "codex", se existir.
        $snapshot = $null
        if ($result.rateLimitsByLimitId) {
            $codexProp = $result.rateLimitsByLimitId.PSObject.Properties["codex"]
            if ($codexProp) {
                $snapshot = $codexProp.Value
            }
        }

        # Fallback para a visualizacao historica/backward-compatible.
        if (-not $snapshot) {
            $snapshot = $result.rateLimits
        }

        $primary = $null
        if ($snapshot) {
            $primary = $snapshot.primary
        }

        # Se o bucket escolhido nao for o de 300 min, procura outro bucket de 300 min.
        if (
            $primary -and
            $null -ne $primary.windowDurationMins -and
            [int64]$primary.windowDurationMins -ne 300 -and
            $result.rateLimitsByLimitId
        ) {
            foreach ($prop in $result.rateLimitsByLimitId.PSObject.Properties) {
                $candidate = $prop.Value
                if (
                    $candidate -and
                    $candidate.primary -and
                    $null -ne $candidate.primary.windowDurationMins -and
                    [int64]$candidate.primary.windowDurationMins -eq 300
                ) {
                    $snapshot = $candidate
                    $primary = $candidate.primary
                    break
                }
            }
        }

        return [PSCustomObject]@{
            Success = $true
            Primary = $primary
            Snapshot = $snapshot
            OrdinaryUsageAllowed = $result.ordinaryUsageAllowed
        }
    }
    finally {
        try { $process.StandardInput.Close() } catch {}
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(3000) | Out-Null
            }
        } catch {}
        $process.Dispose()
    }
}

function Get-LastSuccessUtc {
    if (-not (Test-Path $StateFile)) {
        return $null
    }

    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($state.last_success_utc) {
            return [DateTime]::Parse(
                [string]$state.last_success_utc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
        }
    }
    catch {
        Write-Log "Nao foi possivel ler state.json: $($_.Exception.Message)"
    }

    return $null
}

function Save-SuccessState {
    param([string]$Model)

    @{
        version = $Version
        last_success_utc = [DateTime]::UtcNow.ToString("o")
        last_success_local = (Get-Date).ToString("o")
        model = $Model
    } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Invoke-CodexPing {
    param([string]$CodexPath)

    $model = "gpt-5.6-luna"

    # Mantemos o exec isolado para nao carregar hooks/regras/plugins desnecessarios.
    $args = @(
        "exec",
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--disable", "apps",
        "--disable", "plugins",
        "--model", $model,
        "--config", "model_reasoning_effort=none",
        "--config", "skills.bundled.enabled=false",
        "`"$Prompt`""
    ) -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CodexPath
    $psi.Arguments = $args
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Nao foi possivel iniciar o Codex."
        }

        # Importante para execucao nao interativa no Agendador.
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Codex excedeu o timeout de $TimeoutSeconds segundos."
        }

        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        $exitCode = $process.ExitCode

        if ($stdout) { Write-Log "Codex stdout: $stdout" }
        if ($stderr) { Write-Log "Codex stderr: $stderr" }

        if ($exitCode -ne 0) {
            throw "Codex terminou com codigo $exitCode."
        }

        Save-SuccessState -Model $model
        Write-Log "Ping concluido com sucesso usando $model / reasoning none."
    }
    finally {
        $process.Dispose()
    }
}

# Evita execucoes simultaneas.
$mutexName = "CodexWindowKeeper_" + [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($env:USERNAME)
).Replace("=", "").Replace("/", "_").Replace("+", "-")

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, ([ref]$createdNew))

if (-not $createdNew) {
    exit 0
}

try {
    $codexPath = Get-CodexPath
    $nowUtc = [DateTime]::UtcNow
    $shouldPing = $false
    $usedRealQuotaData = $false

    try {
        Write-Log "Consultando quota real via codex app-server --stdio..."
        $quota = Get-CodexFiveHourWindow -CodexPath $codexPath
        Write-Log "Consulta de quota concluida."

        if ($quota.Primary -and $null -ne $quota.Primary.windowDurationMins) {
            $duration = [int64]$quota.Primary.windowDurationMins

            if ($duration -eq 300 -and $null -ne $quota.Primary.resetsAt) {
                $usedRealQuotaData = $true
                $resetUnix = [int64]$quota.Primary.resetsAt
                $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $resetLocal = [DateTimeOffset]::FromUnixTimeSeconds($resetUnix).LocalDateTime
                $usedPercent = $quota.Primary.usedPercent

                if ($resetUnix -gt $nowUnix) {
                    Write-Log ("Janela real de 5h ainda ativa. Uso: {0}%. Reset: {1}." -f $usedPercent, $resetLocal.ToString("yyyy-MM-dd HH:mm:ss"))
                    $shouldPing = $false
                }
                else {
                    Write-Log ("Janela real de 5h expirou em {0}. Um novo ping sera enviado." -f $resetLocal.ToString("yyyy-MM-dd HH:mm:ss"))
                    $shouldPing = $true
                }
            }
        }
    }
    catch {
        Write-Log "Falha ao consultar quota real: $($_.Exception.Message). Usando fallback local."
    }

    if (-not $usedRealQuotaData) {
        $lastSuccessUtc = Get-LastSuccessUtc

        if (-not $lastSuccessUtc) {
            Write-Log "Quota real indisponivel e nao existe estado local. Executando um ping inicial."
            $shouldPing = $true
        }
        else {
            $elapsed = $nowUtc - $lastSuccessUtc
            if ($elapsed -ge $FallbackInterval) {
                Write-Log ("Fallback local: ultima chamada ha {0:N2} horas. Executando ping." -f $elapsed.TotalHours)
                $shouldPing = $true
            }
            else {
                Write-Log ("Fallback local: ultima chamada ha {0:N2} horas. Nada a fazer." -f $elapsed.TotalHours)
                $shouldPing = $false
            }
        }
    }

    if ($shouldPing) {
        Invoke-CodexPing -CodexPath $codexPath
    }
}
catch {
    Write-Log "ERRO: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($createdNew) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    $mutex.Dispose()
}
