# Codex Window Keeper (Windows)

Mantém a janela de 5 horas do Codex sempre ativa. Um agendamento verifica a quota real a cada 5 minutos via `codex app-server` e envia um ping mínimo (GPT-5.6 Luna, reasoning `none`) quando a janela real expirou ou está vazia; se a quota estiver indisponível, usa fallback local de 4h55.

## Requisitos

- Windows com PowerShell
- `codex` CLI instalado e no PATH

## Instalação / atualização

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-CodexWindowKeeper.ps1
```

Cria a tarefa agendada **Codex Window Keeper** e copia o script para `%LOCALAPPDATA%\CodexWindowKeeper`. A tarefa roda via `wscript.exe`, sem abrir janela de console.

## Arquivos gerados

| Arquivo | Descrição |
|---|---|
| `%LOCALAPPDATA%\CodexWindowKeeper\keeper.log` | Log das execuções |
| `%LOCALAPPDATA%\CodexWindowKeeper\state.json` | Último ping (fallback) |

## Teste manual

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexWindowKeeper\CodexWindowKeeper.ps1"
```

## Desinstalar

```powershell
schtasks /Delete /TN "Codex Window Keeper" /F
Remove-Item "$env:LOCALAPPDATA\CodexWindowKeeper" -Recurse -Force
```
