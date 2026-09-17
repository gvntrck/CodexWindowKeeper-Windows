# Install-CodexWindowKeeper.ps1 - v2.4

$ErrorActionPreference = "Stop"

$TaskName = "Codex Window Keeper"
$InstallDir = Join-Path $env:LOCALAPPDATA "CodexWindowKeeper"
$SourceScript = Join-Path $PSScriptRoot "CodexWindowKeeper.ps1"
$TargetScript = Join-Path $InstallDir "CodexWindowKeeper.ps1"
$LogFile = Join-Path $InstallDir "keeper.log"

if (-not (Test-Path $SourceScript)) {
    throw "Nao encontrei $SourceScript. Mantenha os arquivos na mesma pasta."
}

try {
    $codex = Get-Command codex -ErrorAction Stop
    Write-Host "Codex encontrado em: $($codex.Source)"
    Write-Host "Versao:"
    & $codex.Source --version
}
catch {
    throw "O comando 'codex' nao foi encontrado no PATH."
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item $SourceScript $TargetScript -Force

$VbsLauncher = Join-Path $InstallDir "CodexWindowKeeper.vbs"
$vbsContent = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""$TargetScript""", 0, False
"@
Set-Content -Path $VbsLauncher -Value $vbsContent -Encoding ASCII

$taskCommand = "wscript.exe `"$VbsLauncher`""

Write-Host ""
Write-Host "Criando/atualizando tarefa '$TaskName'..."
Write-Host "A quota real sera verificada a cada 5 minutos."

& schtasks.exe /Create `
    /TN $TaskName `
    /SC MINUTE `
    /MO 5 `
    /TR $taskCommand `
    /F

if ($LASTEXITCODE -ne 0) {
    throw "Falha ao criar/atualizar a tarefa. Codigo: $LASTEXITCODE"
}

Write-Host "Tarefa criada/atualizada."
Write-Host "Executando uma verificacao agora..."

$before = if (Test-Path $LogFile) { (Get-Item $LogFile).LastWriteTimeUtc } else { [DateTime]::MinValue }

& schtasks.exe /Run /TN $TaskName | Out-Null

# schtasks /Run apenas dispara a tarefa e retorna imediatamente.
# Espera alguns segundos para mostrar o resultado da verificacao ao usuario.
$deadline = (Get-Date).AddSeconds(20)
$updated = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $LogFile) {
        $mtime = (Get-Item $LogFile).LastWriteTimeUtc
        if ($mtime -gt $before) {
            $updated = $true
            break
        }
    }
}

Write-Host ""
Write-Host "Instalacao/atualizacao concluida."
Write-Host "Script: $TargetScript"
Write-Host "Estado: $(Join-Path $InstallDir 'state.json')"
Write-Host "Log:    $LogFile"

if ($updated) {
    Write-Host ""
    Write-Host "Ultimas linhas do log:"
    Get-Content $LogFile -Tail 12
}
else {
    Write-Warning "O log ainda nao foi atualizado em 20 segundos."
    Write-Host "Execute manualmente para diagnostico:"
    Write-Host "powershell -NoProfile -ExecutionPolicy Bypass -File `"$TargetScript`""
}
