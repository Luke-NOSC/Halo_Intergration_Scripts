<#
.SYNOPSIS
    Halo PowerShell Integration script for Microsoft 365 vulnerability
    notification emails. Extracts the client name from the "Organization"
    field and reassigns the ticket's Client to match.

.DESCRIPTION
    Field Mappings (Configuration > Integrations > PowerShell > this
    script > Field Mappings) - only one field needed:
        Ticket ID -> TicketId

    IMPORTANT: Halo's PowerShell integration (per its "Method for passing
    parameters" setting - the recommended Option 3) does NOT call this
    script with a plain -TicketId parameter. It calls it with a SINGLE
    -EncodedJson parameter containing a base64-encoded JSON object whose
    keys are whatever you named in Field Mappings. This script decodes
    that and pulls TicketId out of it.

    Everything else (ticket body, current client) is fetched by the
    script itself via the Halo API.

    To add support for a DIFFERENT alert email layout, copy this file,
    rename it, and change only the regex in the "EXTRACT THE NAME" section
    below to match that vendor's label. Everything else (auth, client
    lookup, reassignment, audit note) is shared via HaloCommon.ps1.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$EncodedJson
)

# Self-locating: derives paths from wherever THIS script actually lives,
# rather than a hardcoded folder - so moving the Integrator to a
# different computer or renaming the Scripts folder does not break it.
# Falls back to the original fixed path only if $PSScriptRoot is somehow
# unavailable.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\ProgramData\Halo Integrator\Scripts" }
$CommonLibPath = Join-Path $ScriptDir "HaloCommon.ps1"

# Minimal standalone logger for use ONLY if HaloCommon.ps1 itself fails to
# load (so we still get a record of that failure on disk).
function Write-FallbackLog {
    param([string]$Message)
    try {
        $logPath = Join-Path $ScriptDir "Halo-Script-Debug.log"
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
        if (-not (Test-Path $ScriptDir)) { New-Item -Path $ScriptDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
        Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

try {
    if (-not (Test-Path $CommonLibPath)) {
        Write-FallbackLog "FATAL: HaloCommon.ps1 not found at $CommonLibPath"
        throw "HaloCommon.ps1 not found at $CommonLibPath"
    }
    . $CommonLibPath
}
catch {
    Write-FallbackLog "FATAL: failed to load HaloCommon.ps1 - $($_.Exception.Message)"
    return
}

try {
    Write-FallbackLog "Raw EncodedJson received: $EncodedJson"
    $decodedJsonText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($EncodedJson))
    $paramsObj = $decodedJsonText | ConvertFrom-Json
    Write-Log "Decoded params: $decodedJsonText"

    if (-not $paramsObj.TicketId) {
        throw "Decoded JSON has no 'TicketId' property. Check the Field Mappings tab uses the exact name 'TicketId'. Decoded content: $decodedJsonText"
    }
    $TicketId = [int]$paramsObj.TicketId

    Write-Log "M365 alert script started for ticket $TicketId"
    $token  = Get-HaloToken
    $ticket = Get-HaloTicket -Token $token -TicketId $TicketId
    $plainText = Get-PlainTextBody -Ticket $ticket

    Write-Log "----- Plain text extracted from ticket body (for debugging) -----"
    Write-Log $plainText
    Write-Log "----- End of extracted body text -----"

    if ([string]::IsNullOrWhiteSpace($plainText)) {
        throw "Ticket $TicketId returned no details/details_html content - nothing to search."
    }

    # ----------------- EXTRACT THE NAME -----------------
    # Two different M365-related alert layouts route through this script:
    #
    #   1. The "vulnerabilities notification" layout:
    #          Organization
    #          Glasshouse Country Care
    #      i.e. the label sits alone on its own line, the value is the
    #      very next non-blank line. NOTE: no "^" line-start anchor here -
    #      HTML tag stripping sometimes leaves "Organization" glued
    #      directly onto the end of the preceding line (e.g.
    #      "...notificationOrganization"), so anchoring to line start
    #      caused this to never match even though the value itself is
    #      cleanly on its own line right after.
    #
    #   2. The Microsoft Defender for Endpoint alert layout ("Account
    #      information" section), where label and value are on the same
    #      line with a colon between them:
    #          Organization name: Greenhalgh Pickard
    #      Tried second, only if the first pattern didn't match, since
    #      this is the newer/less common of the two.
    $orgName = $null
    if ($plainText -match '(?im)Organization\s*\r?\n\s*(.+?)\s*\r?\n') {
        $orgName = $Matches[1]
        Write-Log "Matched layout 1 (Organization / value on next line): '$orgName'"
    }
    if ([string]::IsNullOrWhiteSpace($orgName) -and $plainText -match '(?im)Organization name\s*:\s*(.+?)\s*\r?\n') {
        $orgName = $Matches[1]
        Write-Log "Matched layout 2 (Defender 'Organization name:' field): '$orgName'"
    }
    Write-Log "Regex match result: '$orgName'"
    # -----------------------------------------------------

    Invoke-HaloClientReassignFromExtractedName -Token $token -Ticket $ticket -TicketId $TicketId `
        -ExtractedName $orgName -SourceDescription "Microsoft 365 vulnerability alert"
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}