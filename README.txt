Codex Window Keeper v2.2 - Windows

Correcao da v2.2
----------------
Corrige um erro de parsing do PowerShell na mensagem:
    "Erro JSON-RPC id=$Id: ..."

No PowerShell, dois-pontos logo apos uma variavel interpolada podem ser
interpretados como parte da referencia da variavel. Agora usa:
    "Erro JSON-RPC id=${Id}: ..."

Mantem as melhorias anteriores:
- log imediato ao iniciar;
- consulta de quota real via `codex app-server --stdio`;
- account/rateLimits/read;
- ping apenas quando a janela de 5 horas tiver expirado;
- GPT-5.6 Luna com reasoning none;
- state.json como fallback.

Atualizar
---------
Extraia os arquivos e execute:

powershell -ExecutionPolicy Bypass -File .\Install-CodexWindowKeeper.ps1

Teste manual
------------
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexWindowKeeper\CodexWindowKeeper.ps1"
