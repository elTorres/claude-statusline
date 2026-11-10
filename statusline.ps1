# Based on: https://github.com/daniel3303/ClaudeCodeStatusLine
# Line 1: [account label |] Model (effort) | dir@branch scratchpad | tokens (%used) | cache TTL countdown [· 🫀 autostop (interval)] | 5h[↑] @reset | 7d[↑] @reset | scoped | extra | CLI version
# Line 2: [session name |] full current working directory
param(
    [string]$Refresh,
    [long]$Now,
    [string]$CliVersion
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$invariant = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false
$isWindowsHost = $env:OS -eq 'Windows_NT'

$esc = [string][char]27
$reset = $esc + '[0m'
$dim = $esc + '[2m'
$blue = $esc + '[38;2;0;153;255m'
$orange = $esc + '[38;2;255;176;85m'
$green = $esc + '[38;2;0;160;0m'
$cyan = $esc + '[38;2;46;149;153m'
$red = $esc + '[38;2;255;85;85m'
$yellow = $esc + '[38;2;230;200;0m'
$purple = $esc + '[38;2;167;139;250m'
$white = $esc + '[38;2;220;220;220m'
$pink = $esc + '[38;2;255;121;198m'
$sep = ' ' + $dim + '|' + $reset + ' '

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$cacheDir = Join-Path ([IO.Path]::GetTempPath()) 'claude'
$usageCache = Join-Path $cacheDir ('statusline-usage-' + ($configDir -replace '[^A-Za-z0-9]', '_') + '.cache')
$releaseCache = Join-Path $cacheDir 'statusline-claude-code-releases.cache'
$releaseTtl = 3600
$idleRenderTtl = 60
$liveCacheTtl = 0
$checkUpdates = $env:STATUSLINE_CHECK_UPDATES -ne 'false'

function Get-Value($Value, $Default) {
    if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) { return $Default }
    $Value
}

function Read-Text([string]$Path) {
    try {
        if ([IO.File]::Exists($Path)) { return [IO.File]::ReadAllText($Path) }
    } catch { }
    ''
}

function Read-Cache([string]$Path) {
    $text = Read-Text $Path
    $time = [long]0
    $newline = $text.IndexOf("`n")
    if ($newline -lt 0) {
        [void][long]::TryParse($text.Trim(), [ref]$time)
        return @{ Time = $time; Body = '' }
    }
    [void][long]::TryParse($text.Substring(0, $newline).Trim(), [ref]$time)
    @{ Time = $time; Body = $text.Substring($newline + 1) }
}

function Write-Cache([string]$Path, [long]$Time, [string]$Body) {
    try {
        if (-not [IO.Directory]::Exists($cacheDir)) { [void][IO.Directory]::CreateDirectory($cacheDir) }
        $temporary = $Path + '.' + $PID
        [IO.File]::WriteAllText($temporary, [string]$Time + "`n" + $Body, $utf8)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } catch { }
}

function ConvertFrom-JsonText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { ConvertFrom-Json -InputObject $Text } catch { $null }
}

function ConvertTo-RoundedInteger($Value) {
    [long][math]::Round([double](Get-Value $Value 0), [MidpointRounding]::AwayFromZero)
}

function ConvertTo-Epoch($Value) {
    if ($null -eq $Value) { return [long]0 }
    if ($Value -is [datetime]) { return ([DateTimeOffset]$Value.ToUniversalTime()).ToUnixTimeSeconds() }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUnixTimeSeconds() }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, $invariant, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToUnixTimeSeconds()
    }
    [long]0
}

function ConvertTo-VersionParts([string]$Text) {
    $parts = @(0, 0, 0)
    $pieces = $Text.TrimStart('v') -split '\.'
    for ($i = 0; $i -lt 3 -and $i -lt $pieces.Count; $i++) {
        $number = 0
        if ([int]::TryParse($pieces[$i], [ref]$number)) { $parts[$i] = $number }
    }
    $parts
}

function Test-NewerVersion([string]$Candidate, [string]$Current) {
    $candidateParts = ConvertTo-VersionParts $Candidate
    $currentParts = ConvertTo-VersionParts $Current
    for ($i = 0; $i -lt 3; $i++) {
        if ($candidateParts[$i] -gt $currentParts[$i]) { return $true }
        if ($candidateParts[$i] -lt $currentParts[$i]) { return $false }
    }
    $false
}

function Get-UsageColor([long]$Percent) {
    if ($Percent -ge 90) { return $red }
    if ($Percent -ge 70) { return $orange }
    if ($Percent -ge 50) { return $yellow }
    $green
}

function Format-Segment([string]$Label, [long]$Percent) {
    $sep + $white + $Label + $reset + ' ' + (Get-UsageColor $Percent) + $Percent + '%' + $reset
}

function Format-PaceArrow($Percent, [long]$ResetsAt, [long]$Window) {
    if ($ResetsAt -le 0 -or $null -eq $Percent) { return '' }
    $expected = [math]::Min(100, [math]::Max(0, ($Window - ($ResetsAt - $now)) * 100 / $Window))
    if ([double]$Percent -gt $expected) { return $red + [char]0x2191 + $reset }
    ''
}

function Format-LimitSegment([string]$Label, $Percent, [long]$ResetsAt, [long]$Window) {
    (Format-Segment $Label (ConvertTo-RoundedInteger $Percent)) + (Format-PaceArrow $Percent $ResetsAt $Window)
}

function Format-Hyperlink([string]$Path, [string]$Text) {
    $url = ([Uri]$Path).AbsoluteUri
    $esc + ']8;;' + $url + $esc + '\' + $Text + $esc + ']8;;' + $esc + '\'
}

function Resolve-ScratchpadDir([string]$ProjectDir, [string]$SessionId) {
    if (-not $ProjectDir -or -not $SessionId) { return $null }
    if ($isWindowsHost) {
        # Windows: %TEMP%\claude\<project hash>\<session id>\scratchpad
        if ($SessionId -notmatch '^[A-Za-z0-9-]+$') { return $null }
        # Same order as Node's os.tmpdir() (TEMP before TMP), not .NET's GetTempPath() (TMP first)
        $base = @($env:CLAUDE_CODE_TMPDIR, $env:TEMP, $env:TMP, [IO.Path]::GetTempPath()) | Where-Object { $_ } | Select-Object -First 1
        if ($base -match '^/([A-Za-z])(/|$)') { $base = $Matches[1].ToUpper() + ':\' + $base.Substring(3) }
        $parent = Join-Path $base 'claude'
        if (-not [IO.Directory]::Exists($parent)) { return $null }
        foreach ($project in [IO.Directory]::GetDirectories($parent)) {
            $candidate = [IO.Path]::Combine($project, $SessionId, 'scratchpad')
            if ([IO.Directory]::Exists($candidate)) { return $candidate }
        }
        return $null
    }
    $uid = if ($isWindowsHost) { '0' } else { ((& id -u 2>$null) -join '').Trim() }
    $bases = @($env:CLAUDE_CODE_TMPDIR, '/tmp', [IO.Path]::GetTempPath()) | Where-Object { $_ }
    $sanitized = $ProjectDir -replace '[^a-zA-Z0-9]', '-'
    foreach ($base in $bases) {
        foreach ($root in @(('claude-' + $uid), 'claude')) {
            $parent = Join-Path $base $root
            if (-not [IO.Directory]::Exists($parent)) { continue }
            if ($sanitized.Length -le 200) {
                $candidate = [IO.Path]::Combine($parent, $sanitized, $SessionId, 'scratchpad')
                if ([IO.Directory]::Exists($candidate)) { return $candidate }
                continue
            }
            foreach ($project in [IO.Directory]::GetDirectories($parent, $sanitized.Substring(0, 200) + '-*')) {
                $candidate = [IO.Path]::Combine($project, $SessionId, 'scratchpad')
                if ([IO.Directory]::Exists($candidate)) { return $candidate }
            }
        }
    }
    $null
}

function Format-CacheSegment([string]$TranscriptPath) {
    if (-not $TranscriptPath -or -not [IO.File]::Exists($TranscriptPath)) { return '' }
    $lines = @(Get-Content -LiteralPath $TranscriptPath -Tail 400 -Encoding UTF8)
    $lastEpoch = [long]0
    $ttl = [long]0
    for ($i = $lines.Count - 1; $i -ge 0 -and ($lastEpoch -eq 0 -or $ttl -eq 0); $i--) {
        if ($lines[$i] -notmatch '"type"\s*:\s*"assistant"') { continue }
        $entry = ConvertFrom-JsonText $lines[$i]
        if ($null -eq $entry -or $entry.type -ne 'assistant' -or $entry.isSidechain -eq $true) { continue }
        if ($null -eq $entry.message.usage -or $entry.message.model -eq '<synthetic>') { continue }
        if ($lastEpoch -eq 0) { $lastEpoch = ConvertTo-Epoch $entry.timestamp }
        $creation = $entry.message.usage.cache_creation
        if ([long](Get-Value $creation.ephemeral_1h_input_tokens 0) -gt 0) { $ttl = 3600 }
        elseif ([long](Get-Value $creation.ephemeral_5m_input_tokens 0) -gt 0) { $ttl = 300 }
    }
    if ($lastEpoch -le 0) { return '' }
    if ($ttl -eq 0) { $ttl = 300 }
    $remaining = $lastEpoch + $ttl - $now
    if ($remaining -le 0) { return $sep + $white + 'cache TTL' + $reset + ' ' + $red + 'expired' + $reset }
    $script:liveCacheTtl = $ttl
    $color = if ($remaining * 4 -gt $ttl) { $green } else { $orange }
    $countdown = if ($ttl -gt 300) { [string][math]::Ceiling($remaining / 60) + 'm' }
        else { [string]::Format($invariant, '{0}:{1:00}', [math]::Floor($remaining / 60), $remaining % 60) }
    $sep + $white + 'cache TTL' + $reset + ' ' + $color + $countdown + $reset
}

function Format-CachebeatSegment([string]$SessionId, [bool]$FollowsCacheSegment) {
    if ($SessionId -notmatch '^[A-Za-z0-9-]+$') { return '' }
    $tempDir = if ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
    $stateFile = Join-Path $tempDir ('cachebeat-' + $SessionId)
    $fields = (Read-Text $stateFile).Trim() -split '\s+'
    $idleMinutes = [long]0
    $deadline = [long]0
    if ($fields.Count -lt 3 -or -not [long]::TryParse($fields[1], [ref]$idleMinutes) -or -not [long]::TryParse($fields[2], [ref]$deadline)) { return '' }
    $remaining = $deadline - $now
    if ($remaining -le 0) { return '' }
    $color = $dim
    $timerPid = 0
    if ($isWindowsHost) { $color = $green }
    elseif ([int]::TryParse((Read-Text ($stateFile + '.pid')).Trim(), [ref]$timerPid) -and (Get-Process -Id $timerPid)) { $color = $green }
    $minutes = [long][math]::Ceiling($remaining / 60)
    $countdown = if ($minutes -ge 60) { [string]::Format($invariant, '{0}h{1:00}m', [math]::Floor($minutes / 60), $minutes % 60) }
        else { [string]$minutes + 'm' }
    $prefix = if ($FollowsCacheSegment) { ' ' + $dim + [char]0x00B7 + $reset + ' ' } else { $sep }
    $prefix + [char]::ConvertFromUtf32(0x1FAC0) + ' ' + $color + $countdown + $reset + ' ' + $dim + '(' + $reset + $white + [string]$idleMinutes + 'm' + $reset + $dim + ')' + $reset
}

function Format-Placeholder([string]$Label) {
    $sep + $white + $Label + $reset + ' ' + $dim + '-' + $reset
}

function Format-Tokens([double]$Count) {
    if ($Count -ge 1000000) {
        $millions = [math]::Round($Count / 100000, [MidpointRounding]::AwayFromZero) / 10
        return $millions.ToString($invariant) + 'm'
    }
    if ($Count -ge 1000) { return [string](ConvertTo-RoundedInteger ($Count / 1000)) + 'k' }
    ([long]$Count).ToString($invariant)
}

function Format-Money($Cents) {
    [string]::Format($invariant, '{0:0.00}', [double](Get-Value $Cents 0) / 100)
}

function Format-Reset([long]$Epoch, [string]$Pattern) {
    if ($Epoch -le 0) { return '' }
    ' ' + $dim + '@' + [DateTimeOffset]::FromUnixTimeSeconds($Epoch).ToLocalTime().ToString($Pattern, $invariant) + $reset
}

function Get-AccessToken([string]$Text) {
    if ($Text -match '"accessToken"\s*:\s*"([^"]+)"') { return $Matches[1] }
    ''
}

function Resolve-OAuthToken {
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) { return $env:CLAUDE_CODE_OAUTH_TOKEN }
    if (Get-Command security -ErrorAction SilentlyContinue) {
        $service = 'Claude Code-credentials'
        if ($env:CLAUDE_CONFIG_DIR) {
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = -join ($sha.ComputeHash($utf8.GetBytes($env:CLAUDE_CONFIG_DIR)) | ForEach-Object { $_.ToString('x2') })
            $service += '-' + $hash.Substring(0, 8)
        }
        $token = Get-AccessToken ((& security find-generic-password -s $service -w 2>$null) -join "`n")
        if ($token) { return $token }
    }
    $token = Get-AccessToken (Read-Text (Join-Path $configDir '.credentials.json'))
    if ($token) { return $token }
    if (Get-Command secret-tool -ErrorAction SilentlyContinue) {
        return Get-AccessToken ((& secret-tool lookup service 'Claude Code-credentials' 2>$null) -join "`n")
    }
    ''
}

function Invoke-HttpGet([string]$Uri, [hashtable]$Headers, [int]$TimeoutSeconds, [string]$UserAgent) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = @{ Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSeconds; UseBasicParsing = $true }
        if ($UserAgent) { $request.UserAgent = $UserAgent }
        $response = Invoke-WebRequest @request
        if ($response.Content -is [byte[]]) { return $utf8.GetString($response.Content) }
        [string]$response.Content
    } catch { '' }
}

function Start-Refresh([string]$Kind, [long]$Time) {
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Refresh', $Kind, '-Now', $Time)
    if ($cliVersion) { $arguments += @('-CliVersion', $cliVersion) }
    $executable = (Get-Process -Id $PID).Path
    if ($isWindowsHost) {
        Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden
    } else {
        Start-Process -FilePath $executable -ArgumentList $arguments `
            -RedirectStandardOutput '/dev/null' -RedirectStandardError (Join-Path $cacheDir 'statusline-refresh.err')
    }
}

function Resolve-GitDir([string]$Start) {
    $dir = $Start
    while ($dir) {
        $candidate = Join-Path $dir '.git'
        if ([IO.Directory]::Exists($candidate)) { return $candidate }
        if ([IO.File]::Exists($candidate)) {
            $pointer = (Read-Text $candidate).Trim()
            if ($pointer.StartsWith('gitdir: ')) {
                $path = $pointer.Substring(8)
                if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $dir $path }
                return $path
            }
        }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    $null
}

function Format-GitSegment([string]$Directory) {
    $gitDir = Resolve-GitDir $Directory
    if (-not $gitDir) { return '' }
    $head = (Read-Text (Join-Path $gitDir 'HEAD')).Trim()
    if (-not $head) { return '' }
    $branch = if ($head.StartsWith('ref: refs/heads/')) { $head.Substring(16) } else { 'HEAD' }
    $segment = $dim + '@' + $reset + $green + $branch + $reset
    $summary = ''
    try { $summary = (& git --no-optional-locks -C $Directory diff --shortstat 2>$null) -join ' ' } catch { }
    $added = 0
    $removed = 0
    if ($summary -match '(\d+) insertion') { $added = [int]$Matches[1] }
    if ($summary -match '(\d+) deletion') { $removed = [int]$Matches[1] }
    if ($added + $removed -gt 0) {
        $segment += ' ' + $dim + '(' + $reset + $green + '+' + $added + $reset + ' ' + $red + '-' + $removed + $reset + $dim + ')' + $reset
    }
    $segment
}

if ($Refresh -eq 'usage') {
    $token = Resolve-OAuthToken
    if ($token) {
        $headers = @{ 'Accept' = 'application/json'; 'Authorization' = 'Bearer ' + $token; 'anthropic-beta' = 'oauth-2025-04-20' }
        $response = Invoke-HttpGet 'https://api.anthropic.com/api/oauth/usage' $headers 10 ('claude-code/' + (Get-Value $CliVersion '2.1.34'))
        if ($response -match '"limits"|"five_hour"') { Write-Cache $usageCache $Now $response }
    }
    exit 0
}

if ($Refresh -eq 'releases') {
    $response = Invoke-HttpGet 'https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags' @{} 5 ''
    if ($response -match '"latest"') { Write-Cache $releaseCache $Now $response }
    exit 0
}

$stdout = [Console]::OpenStandardOutput()
function Write-Utf8Text([string]$Text) {
    $bytes = $utf8.GetBytes($Text)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$inputText = $reader.ReadToEnd()
$renderCache = ''
if ($inputText -match '"session_id"\s*:\s*"([A-Za-z0-9-]+)"') {
    $renderCache = Join-Path $cacheDir ('statusline-render-' + $Matches[1])
    $renderState = Read-Cache ($renderCache + '.out')
    $renderAge = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $renderState.Time
    if ($renderState.Time -gt 0 -and $renderAge -lt $idleRenderTtl -and (Read-Text ($renderCache + '.in')) -ceq $inputText) {
        Write-Utf8Text $renderState.Body
        exit 0
    }
}
$status = ConvertFrom-JsonText $inputText
if ($null -eq $status) {
    Write-Utf8Text 'Claude'
    exit 0
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$usageState = Read-Cache $usageCache
$usage = ConvertFrom-JsonText $usageState.Body
$releaseState = if ($checkUpdates) { Read-Cache $releaseCache } else { @{ Time = [long]0; Body = '' } }
$settings = ConvertFrom-JsonText (Read-Text (Join-Path $configDir 'settings.json'))
$accountFile = Join-Path (Get-Value $env:CLAUDE_CONFIG_DIR $HOME) '.claude.json'
$account = ConvertFrom-JsonText (Read-Text $accountFile)

$model = [string](Get-Value $status.model.display_name 'Claude') -replace ' *\(([0-9.]*[kKmM]*) context\)', ' $1'
$effort = [string](Get-Value $status.effort.level (Get-Value $env:CLAUDE_CODE_EFFORT_LEVEL (Get-Value $settings.effortLevel 'medium')))
switch ($effort) {
    'low' { $effortColor = $dim; $effortLabel = 'low' }
    'medium' { $effortColor = $orange; $effortLabel = 'med' }
    'high' { $effortColor = $green; $effortLabel = 'high' }
    'xhigh' { $effortColor = $purple; $effortLabel = 'xhigh' }
    'max' { $effortColor = $red; $effortLabel = 'max' }
    default { $effortColor = $green; $effortLabel = $effort }
}

$size = [double](Get-Value $status.context_window.context_window_size 200000)
if ($size -eq 0) { $size = 200000 }
$currentUsage = $status.context_window.current_usage
$current = [double]([long]$currentUsage.input_tokens + [long]$currentUsage.cache_creation_input_tokens + [long]$currentUsage.cache_read_input_tokens)
$percentUsed = [long][math]::Floor($current * 100 / $size)

$builtinFiveHour = $status.rate_limits.five_hour
$builtinSevenDay = $status.rate_limits.seven_day
$hasBuiltin = ($null -ne $builtinFiveHour.used_percentage) -or ($null -ne $builtinSevenDay.used_percentage)
$useBuiltin = $hasBuiltin -and (
    (ConvertTo-RoundedInteger $builtinFiveHour.used_percentage) -ne 0 -or
    (ConvertTo-RoundedInteger $builtinSevenDay.used_percentage) -ne 0 -or
    [double](Get-Value $builtinFiveHour.resets_at 0) -ne 0 -or
    [double](Get-Value $builtinSevenDay.resets_at 0) -ne 0)
$apiAvailable = ($null -ne $usage) -and (($null -ne $usage.limits) -or ($null -ne $usage.five_hour))

function Get-ApiLimit([string]$Kind, [string]$Bucket, [string]$Field) {
    $entry = @($usage.limits).Where({ $null -ne $_ -and $_.kind -eq $Kind -and $null -ne $_.resets_at }, 'First')
    if ($entry.Count -gt 0 -and $null -ne $entry[0].$Field) { return $entry[0].$Field }
    $flatField = if ($Field -eq 'percent') { 'utilization' } else { $Field }
    $usage.$Bucket.$flatField
}

function Format-ScopedLimits {
    $segments = ''
    foreach ($limit in @($usage.limits)) {
        if ($null -ne $limit -and $limit.kind -eq 'weekly_scoped') {
            $segments += Format-Segment ([string](Get-Value $limit.scope.model.display_name 'scoped')) (ConvertTo-RoundedInteger $limit.percent)
        }
    }
    $segments
}

function Format-ExtraUsage {
    $extra = $usage.extra_usage
    if ($null -eq $extra -or $extra.is_enabled -ne $true) { return '' }
    $percent = ConvertTo-RoundedInteger $extra.utilization
    $sep + $white + 'extra' + $reset + ' ' + (Get-UsageColor $percent) + '$' + (Format-Money $extra.used_credits) + '/$' + (Format-Money $extra.monthly_limit) + $reset
}

$timePattern = 'HH:mm'
$dateTimePattern = 'ddd MMM d, HH:mm'
if ($useBuiltin) {
    $limits = ''
    if ($null -ne $builtinFiveHour.used_percentage) {
        $fiveReset = [long](Get-Value $builtinFiveHour.resets_at 0)
        $limits += (Format-LimitSegment '5h' $builtinFiveHour.used_percentage $fiveReset 18000) + (Format-Reset $fiveReset $timePattern)
    }
    if ($null -ne $builtinSevenDay.used_percentage) {
        $sevenReset = [long](Get-Value $builtinSevenDay.resets_at 0)
        $limits += (Format-LimitSegment '7d' $builtinSevenDay.used_percentage $sevenReset 604800) + (Format-Reset $sevenReset $dateTimePattern)
    }
    $limits += (Format-ScopedLimits) + (Format-ExtraUsage)
} elseif ($apiAvailable) {
    $fiveReset = ConvertTo-Epoch (Get-ApiLimit 'session' 'five_hour' 'resets_at')
    $sevenReset = ConvertTo-Epoch (Get-ApiLimit 'weekly_all' 'seven_day' 'resets_at')
    $limits = (Format-LimitSegment '5h' (Get-Value (Get-ApiLimit 'session' 'five_hour' 'percent') 0) $fiveReset 18000) +
        (Format-Reset $fiveReset $timePattern) +
        (Format-LimitSegment '7d' (Get-Value (Get-ApiLimit 'weekly_all' 'seven_day' 'percent') 0) $sevenReset 604800) +
        (Format-Reset $sevenReset $dateTimePattern) +
        (Format-ScopedLimits) + (Format-ExtraUsage)
} else {
    $limits = (Format-Placeholder '5h') + (Format-Placeholder '7d')
}

$cwd = [string](Get-Value $status.cwd '')
$cliVersion = [string](Get-Value $status.version '')

$sessionName = [string](Get-Value $status.session_name '') -replace '[\x00-\x1f\x7f]', ''
$displayName = [string](Get-Value $account.oauthAccount.displayName '')
$accountEmail = [string](Get-Value $account.oauthAccount.emailAddress '')
$accountLabel = if ($env:STATUSLINE_ACCOUNT_LABEL) { $env:STATUSLINE_ACCOUNT_LABEL }
    elseif ($displayName) { $displayName }
    elseif ($accountEmail.Contains('@')) { $accountEmail.Substring($accountEmail.IndexOf('@') + 1) }
    else { '' }
$accountLabel = $accountLabel -replace '[\x00-\x1f\x7f]', ''
$line = if ($accountLabel) { $pink + $accountLabel + $reset + $sep } else { '' }
$line += $blue + $model + $reset + ' ' + $dim + '(' + $reset + $effortColor + $effortLabel + $reset + $dim + ')' + $reset
if ($cwd) {
    $line += $sep + (Format-Hyperlink $cwd ($cyan + [IO.Path]::GetFileName($cwd.TrimEnd('\', '/')) + $reset)) + (Format-GitSegment $cwd)
    $scratchpadDir = Resolve-ScratchpadDir ([string](Get-Value $status.workspace.project_dir $cwd)) ([string](Get-Value $status.session_id ''))
    if ($scratchpadDir) { $line += ' ' + (Format-Hyperlink $scratchpadDir ($dim + $cyan + 'scratchpad' + $reset)) }
}
$line += $sep + $orange + (Format-Tokens $current) + '/' + (Format-Tokens $size) + $reset + ' ' + $dim + '(' + $reset + $green + $percentUsed + '%' + $reset + $dim + ')' + $reset
$cacheSegment = Format-CacheSegment ([string](Get-Value $status.transcript_path ''))
$line += $cacheSegment + (Format-CachebeatSegment ([string](Get-Value $status.session_id '')) ([bool]$cacheSegment)) + $limits
if ($cliVersion) { $line += $sep + $orange + 'v' + $cliVersion + $reset }
$secondLine = @()
if ($sessionName) { $secondLine += $white + $sessionName + $reset }
if ($cwd) { $secondLine += $dim + $cwd + $reset }
if ($secondLine) { $line += "`n" + ($secondLine -join $sep) }

if ($checkUpdates -and $cliVersion) {
    $releases = ConvertFrom-JsonText $releaseState.Body
    $channel = [string](Get-Value $settings.autoUpdatesChannel 'latest')
    $available = [string](Get-Value $releases.$channel '')
    if ($available -and (Test-NewerVersion $available $cliVersion)) {
        $line += "`n" + $dim + 'Claude Code update available: v' + $cliVersion + ' ' + [char]0x2192 + ' ' + $orange + 'v' + $available + $reset + $dim + ' (run: claude update)' + $reset
    }
}

Write-Utf8Text $line

if ($renderCache) {
    if ($liveCacheTtl -eq 0 -or $liveCacheTtl -gt 300) {
        try {
            if (-not [IO.Directory]::Exists($cacheDir)) { [void][IO.Directory]::CreateDirectory($cacheDir) }
            [IO.File]::WriteAllText($renderCache + '.in', $inputText, $utf8)
        } catch { }
        Write-Cache ($renderCache + '.out') $now $line
    } else {
        Remove-Item -LiteralPath ($renderCache + '.out') -Force
    }
}

$usageTtl = if ($hasBuiltin) { 300 } else { 60 }
$customTtl = 0
if ($env:STATUSLINE_USAGE_TTL -and [int]::TryParse($env:STATUSLINE_USAGE_TTL, [ref]$customTtl)) { $usageTtl = $customTtl }

if ($now - $usageState.Time -ge $usageTtl) {
    Write-Cache $usageCache $now $usageState.Body
    Start-Refresh 'usage' $now
}

if ($checkUpdates -and $now - $releaseState.Time -ge $releaseTtl) {
    Write-Cache $releaseCache $now $releaseState.Body
    Start-Refresh 'releases' $now
}

exit 0
