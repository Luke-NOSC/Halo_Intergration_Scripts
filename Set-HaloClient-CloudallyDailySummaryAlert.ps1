<#
.SYNOPSIS
    Halo PowerShell Integration script for Cloudally's per-client "Backup
    Summary Report" daily email (NOT the multi-account "Accounts Requiring
    Attention" digest - that's Set-HaloClient-CloudallyAlert.ps1, a
    different template). Extracts the client name and reassigns the
    ticket's Client to match.

.DESCRIPTION
    Field Mappings: only Ticket ID -> TicketId is needed (see
    Set-HaloClient-M365Alert.ps1 for the full explanation - same pattern,
    including why this takes -EncodedJson rather than a plain -TicketId).

    This Cloudally template is scoped to a single client already, and
    names it in two places:

      1. The email Subject (which becomes the ticket Summary), e.g.:
         "Cloudally Backup Summary - Total Business Partners, 2 Backup
         items Failed, 144 items Successful (Total Business Partners)"
         - the client name sits in parentheses at the very end, which is
           the most reliably delimited spot (no risk from a comma inside
           the client name itself).

      2. The body's "Account" field, e.g. "...Account Total Business
         Partners Mail tap@...". Used as a fallback if the Summary
         doesn't match for some reason - bounded between "Account" and
         the next label, "Mail", the same way Set-HaloClient-
         BlackpointAlert.ps1 bounds "Customer Name" and "IP Address",
         since this Halo instance flattens table cells with no line
         breaks.
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

    Write-Log "Cloudally daily summary script started for ticket $TicketId"
    $token  = Get-HaloToken
    $ticket = Get-HaloTicket -Token $token -TicketId $TicketId
    $plainText = Get-PlainTextBody -Ticket $ticket

    Write-Log "----- Plain text extracted from ticket body (for debugging) -----"
    Write-Log $plainText
    Write-Log "----- End of extracted body text -----"
    Write-Log "Ticket summary: '$($ticket.summary)'"

    # ----------------- EXTRACT THE NAME -----------------
    $orgName = $null

    # 1. Preferred: the parenthesised client name at the end of the
    #    Summary/Subject, e.g. "...144 items Successful (Total Business
    #    Partners)" -> "Total Business Partners". More reliable than
    #    splitting on the first comma, since a client name could itself
    #    contain a comma.
    if ($ticket.summary -and $ticket.summary -match '\(([^)]+)\)\s*$') {
        $orgName = $Matches[1].Trim()
        Write-Log "Extracted name from ticket Summary: '$orgName'"
    }

    # 2. Fallback: the body's "Account" field, bounded by the next label
    #    ("Mail") the same way the Blackpoint script bounds its fields -
    #    this Halo instance flattens HTML tables with no line breaks OR
    #    spacing at all, e.g. "...AccountTotal Business PartnersMailtap@...".
    #    NOTE: no "\b" after "Mail" - confirmed via the debug log that
    #    "Mail" is glued directly onto the following email address
    #    ("Mailtap@...") with no word boundary in between, so requiring
    #    one made this never match at all.
    if ([string]::IsNullOrWhiteSpace($orgName) -and $plainText) {
        if ($plainText -match '(?i)Account(.*?)Mail') {
            $orgName = $Matches[1].Trim()
            Write-Log "Extracted name from ticket body (Account field): '$orgName'"
        }
    }

    Write-Log "Final extracted name: '$orgName'"
    # -----------------------------------------------------

    Invoke-HaloClientReassignFromExtractedName -Token $token -Ticket $ticket -TicketId $TicketId `
        -ExtractedName $orgName -SourceDescription "Cloudally daily backup summary"
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}