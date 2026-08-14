<#
.SYNOPSIS
    Sets up Inkwell for whichever of Claude Code / Codex is installed.

.DESCRIPTION
    Windows installer.
    1. Detects `claude` and/or `codex` on PATH.
    2. For each detected CLI, uses *its own* CLI to register the Inkwell MCP
       server and install the inkwell-hooks plugin (marketplace add + install).
    3. For each detected CLI, does the same follow-up regardless of which one
       it is: creates an `inkwell\` folder under that client's home dir holding
       INKWELL_SPEC.md + INKWELL_TEMPLATES.md, then wires it into that client's
       global instructions file - `@inkwell/INKWELL_SPEC.md` import for Claude
       Code's CLAUDE.md, or (Codex has no `@`-import) the resolved content
       inlined into Codex's AGENTS.md between idempotent markers.

    Best-effort: a failing CLI subcommand (docker missing, network fetch, a
    server/plugin that's already registered) prints a warning and the script
    keeps going - this is provisioning, not a transaction.

.PARAMETER ClaudeHome
    Root Claude Code config directory. Defaults to $env:USERPROFILE\.claude.

.PARAMETER CodexHome
    Root Codex config directory. Defaults to $env:USERPROFILE\.codex.

.EXAMPLE
    powershell -File scripts/install.ps1
#>
param(
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE ".claude"),
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex")
)

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$pluginSource = Join-Path $repoRoot "plugins\inkwell-hooks"

if (-not (Test-Path $pluginSource)) {
    throw "plugins/inkwell-hooks/ source folder not found at $pluginSource"
}

$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$hasCodex = [bool](Get-Command codex -ErrorAction SilentlyContinue)

if (-not $hasClaude -and -not $hasCodex) {
    Write-Error "Neither 'claude' nor 'codex' found on PATH - nothing to wire up. Install one of them first, then re-run this script."
    exit 1
}

Write-Host "Detected: claude=$hasClaude, codex=$hasCodex"

# --- 0b. If both are present, let the user pick which to install for --------

if ($hasClaude -and $hasCodex) {
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ""
        $selection = Read-Host "Both claude and codex found on PATH. Install for which? [claude/codex/both] (default: both)"
        if ([string]::IsNullOrWhiteSpace($selection)) { $selection = "both" }
        switch ($selection.ToLower()) {
            "claude" { $hasCodex = $false }
            "codex" { $hasClaude = $false }
            "both" { }
            default { Write-Warning "Unrecognized selection '$selection' - defaulting to both" }
        }
    } else {
        Write-Host "Non-interactive shell - installing for both detected CLIs."
    }
}

# --- 1. Knowledge base directory (shared, client-agnostic) ------------------

$knowledgeDir = Join-Path $env:USERPROFILE ".inkwell\knowledge"

if (-not (Test-Path $knowledgeDir)) {
    Write-Host "Creating knowledge base directory: $knowledgeDir"
    New-Item -ItemType Directory -Path $knowledgeDir -Force | Out-Null
} else {
    Write-Host "Knowledge base directory already exists: $knowledgeDir"
}

$mcpCommand = @("docker", "run", "-i", "--rm", "-v", "${knowledgeDir}:/knowledge", "foreigndmitryi/inkwell-memory")

# --- 2. Per-client MCP server + plugin install (each CLI's own commands) ----

if ($hasClaude) {
    Write-Host ""
    Write-Host "-- Claude Code --"
    & claude mcp add --transport stdio --scope user inkwell -- @mcpCommand
    if ($LASTEXITCODE -eq 0) { Write-Host "Registered inkwell MCP server" }
    else { Write-Warning "'claude mcp add' failed or inkwell is already registered - check with 'claude mcp list'" }

    & claude plugin marketplace add $repoRoot
    if ($LASTEXITCODE -eq 0) { Write-Host "Added inkwell-memory marketplace" }
    else { Write-Warning "'claude plugin marketplace add' failed" }

    & claude plugin install inkwell-hooks@inkwell-memory --scope user
    if ($LASTEXITCODE -eq 0) { Write-Host "Installed inkwell-hooks plugin" }
    else { Write-Warning "'claude plugin install' failed - try '/plugin install inkwell-hooks@inkwell-memory' inside a session" }
}

if ($hasCodex) {
    Write-Host ""
    Write-Host "-- Codex --"
    & codex mcp add inkwell -- @mcpCommand
    if ($LASTEXITCODE -eq 0) { Write-Host "Registered inkwell MCP server" }
    else { Write-Warning "'codex mcp add' failed or inkwell is already registered - check with 'codex mcp list'" }

    & codex plugin marketplace add (Join-Path $repoRoot "plugins")
    if ($LASTEXITCODE -eq 0) { Write-Host "Added inkwell-memory marketplace" }
    else { Write-Warning "'codex plugin marketplace add' failed" }

    & codex plugin add inkwell-hooks@inkwell-memory
    if ($LASTEXITCODE -eq 0) { Write-Host "Installed inkwell-hooks plugin" }
    else { Write-Warning "'codex plugin add' failed" }

    # Codex's plugin.json schema has no "agents" field, so the
    # inkwell-project-onboarder subagent doesn't ship through the plugin
    # install above - copy its Codex-native TOML into ~/.codex/agents/ by hand.
    $codexAgentsDir = Join-Path $CodexHome "agents"
    New-Item -ItemType Directory -Path $codexAgentsDir -Force | Out-Null
    Copy-Item -Path (Join-Path $pluginSource "agents\inkwell-project-onboarder.codex.toml") -Destination (Join-Path $codexAgentsDir "inkwell-project-onboarder.toml") -Force
    Write-Host "Installed inkwell-project-onboarder subagent -> $codexAgentsDir\inkwell-project-onboarder.toml"
}

# --- 3. Global instructions, same shape for both clients --------------------

if ($hasClaude) {
    Write-Host ""
    Write-Host "-- Claude Code global instructions --"
    $claudeInkwellDir = Join-Path $ClaudeHome "inkwell"
    New-Item -ItemType Directory -Path $claudeInkwellDir -Force | Out-Null
    Copy-Item -Path (Join-Path $pluginSource "INKWELL_SPEC.md") -Destination (Join-Path $claudeInkwellDir "INKWELL_SPEC.md") -Force
    Copy-Item -Path (Join-Path $pluginSource "INKWELL_TEMPLATES.md") -Destination (Join-Path $claudeInkwellDir "INKWELL_TEMPLATES.md") -Force
    Write-Host "Copied INKWELL_SPEC.md + INKWELL_TEMPLATES.md -> $claudeInkwellDir"

    $claudeMdPath = Join-Path $ClaudeHome "CLAUDE.md"
    $importLine = "@inkwell/INKWELL_SPEC.md"

    if (-not (Test-Path $claudeMdPath)) {
        Write-Host "Creating $claudeMdPath with $importLine"
        Set-Content -Path $claudeMdPath -Value $importLine -Encoding utf8
    } else {
        $existing = Get-Content -Path $claudeMdPath -Raw
        if ($existing -match [regex]::Escape($importLine)) {
            Write-Host "$claudeMdPath already references $importLine"
        } else {
            Write-Host "Adding $importLine to top of $claudeMdPath"
            Set-Content -Path $claudeMdPath -Value ($importLine + "`n`n" + $existing) -Encoding utf8
        }
    }
}

if ($hasCodex) {
    Write-Host ""
    Write-Host "-- Codex global instructions --"
    $codexInkwellDir = Join-Path $CodexHome "inkwell"
    New-Item -ItemType Directory -Path $codexInkwellDir -Force | Out-Null
    Copy-Item -Path (Join-Path $pluginSource "INKWELL_SPEC.md") -Destination (Join-Path $codexInkwellDir "INKWELL_SPEC.md") -Force
    Copy-Item -Path (Join-Path $pluginSource "INKWELL_TEMPLATES.md") -Destination (Join-Path $codexInkwellDir "INKWELL_TEMPLATES.md") -Force
    Write-Host "Copied INKWELL_SPEC.md + INKWELL_TEMPLATES.md -> $codexInkwellDir (reference copies; Codex reads the inlined block below, not these files)"

    # Codex's AGENTS.md has no @-import mechanism (unlike Claude Code's CLAUDE.md),
    # so the two files are concatenated here, with INKWELL_SPEC.md's own
    # "@INKWELL_TEMPLATES.md" import line replaced by the templates' actual content.
    $beginMarker = "<!-- BEGIN inkwell-memory -->"
    $endMarker = "<!-- END inkwell-memory -->"

    $specContent = Get-Content -Path (Join-Path $pluginSource "INKWELL_SPEC.md") -Raw
    $templatesContent = Get-Content -Path (Join-Path $pluginSource "INKWELL_TEMPLATES.md") -Raw
    $mergedContent = $specContent.Replace("@INKWELL_TEMPLATES.md", $templatesContent)

    $agentsMdPath = Join-Path $CodexHome "AGENTS.md"
    $block = "$beginMarker`n`n$mergedContent`n`n$endMarker"

    if (-not (Test-Path $agentsMdPath)) {
        Write-Host "Creating $agentsMdPath with the inkwell-memory block"
        Set-Content -Path $agentsMdPath -Value $block -Encoding utf8
    } else {
        $existing = Get-Content -Path $agentsMdPath -Raw
        if ($existing -match [regex]::Escape($beginMarker)) {
            Write-Host "Updating existing inkwell-memory block in $agentsMdPath"
            $pattern = [regex]::Escape($beginMarker) + "(?s).*?" + [regex]::Escape($endMarker)
            $rest = [regex]::Replace($existing, $pattern, "").TrimStart()
            Set-Content -Path $agentsMdPath -Value ($block + "`n`n" + $rest) -Encoding utf8
        } else {
            Write-Host "Adding inkwell-memory block to top of $agentsMdPath"
            Set-Content -Path $agentsMdPath -Value ($block + "`n`n" + $existing) -Encoding utf8
        }
    }
}

Write-Host ""
Write-Host "Done. Still manual:"
Write-Host "  - Disable Claude Code's built-in auto memory (see plugins/inkwell-hooks/README.md, step 3)"
Write-Host "  - Sanity-check the install (see plugins/inkwell-hooks/README.md)"
