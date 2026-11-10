# Claude Code status line

Basada en [daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine) (MIT). Licencia: [MIT](LICENSE).

```text
[cuenta |] Modelo (esfuerzo) | dir@rama scratchpad | tokens (%usado) | cache TTL 42m · 🫀 2h15m (50m) | 5h[↑] @reinicio | 7d[↑] @reinicio | scoped | extra | versión
[sesión |] /ruta/completa/del/directorio
```

- `statusline.sh`: macOS, Linux y Windows con Git Bash (requiere `jq`, `curl` y `git`). En Windows es la opción recomendada por ser más rápida; `curl` y `git` vienen con Git for Windows y `jq` se instala con `winget install jqlang.jq`.
- `statusline.ps1`: Windows / PowerShell, sin dependencias externas.

## Instalación

Clona el repo en `~/.claude/statusline`:

```sh
git clone https://github.com/elTorres/claude-statusline.git ~/.claude/statusline
```

En Windows:

```powershell
git clone https://github.com/elTorres/claude-statusline.git "$HOME\.claude\statusline"
```

Para actualizar, `git -C ~/.claude/statusline pull`.

Después, en el `settings.json` de cada directorio de configuración:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline/statusline.sh",
    "refreshInterval": 10
  }
}
```

`refreshInterval` vuelve a ejecutar el script cada 10 s para que la cuenta atrás de la caché avance aunque no haya actividad. Si la entrada no ha cambiado y el TTL es de 1 h (o la caché ya caducó), el script devuelve su última salida durante 60 s sin recalcular, así que en la práctica se actualiza cada minuto con TTL de 1 h y cada 10 s con TTL de 5 min.

En Windows, con Git Bash:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline/statusline.sh",
    "refreshInterval": 10
  }
}
```

O con PowerShell:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\.claude\\statusline\\statusline.ps1",
    "refreshInterval": 10
  }
}
```

## Segmentos

| Segmento | Origen |
| --- | --- |
| Sesión | `session_name` del JSON de Claude Code (solo si la sesión se nombró con `/rename`) |
| Cuenta | `STATUSLINE_ACCOUNT_LABEL` → `oauthAccount.displayName` ("What should Claude call you?") → dominio de `oauthAccount.emailAddress` |
| Carpeta y scratchpad | Enlaces OSC 8 (`file://`) a `cwd` y a la carpeta de trabajo de la sesión (`<tmp>/claude-<uid>/<project_dir saneado>/<session_id>/scratchpad`; en Windows, `%TEMP%\claude\<hash>\<session_id>\scratchpad` o bajo `CLAUDE_CODE_TMPDIR`; solo si existe). Al pulsarlos se abren en Finder o Explorer, según el terminal (iTerm2: Cmd+clic) |
| cache TTL | Tiempo hasta que caduca la caché de prompts: última respuesta del `transcript_path` + TTL (1 h si escribió `ephemeral_1h`, si no 5 min). Con TTL de 1 h se muestra en minutos (`42m`); con 5 min, en `m:ss`. Naranja en el último 25 %, `expired` al caducar |
| 🫀 | Solo con [cachebeat](https://github.com/ARahim3/cachebeat) armado en la sesión: tiempo hasta su auto-stop y, entre paréntesis, el umbral de inactividad tras el que lanza cada latido, leído de `$TMPDIR/cachebeat-<session_id>`. Verde si su temporizador está vivo; atenuado si está armado pero sin temporizador en marcha (p. ej. se retiró porque la caché ya había caducado, o la sesión se reanudó sin volver a ejecutar `/cachebeat`) |
| 5h / 7d | `rate_limits` del JSON de Claude Code o, en su defecto, la API de uso de Anthropic (en caché). `↑` en rojo cuando el porcentaje usado supera el tiempo transcurrido de la ventana |

Los datos de la cuenta se leen de `$CLAUDE_CONFIG_DIR/.claude.json`, o de `~/.claude.json` si `CLAUDE_CONFIG_DIR` no está definida.

## Variables de entorno

| Variable | Por defecto | Efecto |
| --- | --- | --- |
| `STATUSLINE_ACCOUNT_LABEL` | — | Texto fijo para el segmento de cuenta |
| `STATUSLINE_USAGE_TTL` | `300` con límites integrados, `60` sin ellos | Segundos entre consultas a la API de uso |
| `STATUSLINE_CHECK_UPDATES` | `true` | `false` desactiva el aviso de nueva versión |

## Varias suscripciones

Cada suscripción necesita su propio directorio de configuración. `CLAUDE_CONFIG_DIR` separa credenciales, `settings.json`, historial y la caché de uso de la status line, así que los porcentajes de 5h/7d corresponden siempre a la cuenta activa.

### 1. Crear la segunda configuración

La primera cuenta sigue usando la configuración por defecto (`~/.claude`). Para la segunda:

```sh
mkdir -p ~/.claude-personal
cat > ~/.claude-personal/settings.json <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline/statusline.sh"
  }
}
JSON
```

El script se comparte: basta con apuntar a la misma ruta desde ambos `settings.json`.

### 2. Iniciar sesión en la segunda cuenta

```sh
CLAUDE_CONFIG_DIR=~/.claude-personal claude
```

Dentro de Claude Code, ejecuta `/login` con la cuenta de la segunda suscripción. Las credenciales quedan guardadas aparte (en macOS, en una entrada del llavero propia de ese directorio).

### 3. Alias

En `~/.zshrc` (o `~/.bashrc`):

```sh
alias claude='STATUSLINE_ACCOUNT_LABEL=TRABAJO claude'
alias claude-personal='CLAUDE_CONFIG_DIR=~/.claude-personal STATUSLINE_ACCOUNT_LABEL=PERSONAL claude'
```

Resultado:

```txt
TRABAJO | Opus (high) | proyecto@main | ...
PERSONAL | Opus (high) | proyecto@main | ...
```

`STATUSLINE_ACCOUNT_LABEL` es opcional: sin ella se muestra el nombre de "What should Claude call you?" de cada cuenta, o el dominio del correo.

No definas `CLAUDE_CONFIG_DIR=~/.claude` para la cuenta por defecto: Claude Code trata cualquier valor explícito como una configuración distinta y pediría iniciar sesión de nuevo.

### PowerShell

```powershell
function claude {
    $env:STATUSLINE_ACCOUNT_LABEL = 'TRABAJO'
    & (Get-Command claude -CommandType Application | Select-Object -First 1) @args
    Remove-Item Env:STATUSLINE_ACCOUNT_LABEL
}
function claude-personal {
    $env:CLAUDE_CONFIG_DIR = "$HOME\.claude-personal"
    $env:STATUSLINE_ACCOUNT_LABEL = 'PERSONAL'
    & (Get-Command claude -CommandType Application | Select-Object -First 1) @args
    Remove-Item Env:CLAUDE_CONFIG_DIR, Env:STATUSLINE_ACCOUNT_LABEL
}
```
