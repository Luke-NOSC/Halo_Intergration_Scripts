<#
.SYNOPSIS
    Halo PowerShell Integration script for Blackpoint Cyber "Cloud
    Response" alert emails (e.g. Microsoft 365 login-from-unapproved-
    country alerts). Extracts the affected client name from the
    "Customer Name" row of the alert's details table and reassigns the
    ticket's Client to match.

.DESCRIPTION
    Field Mappings: only Ticket ID -> TicketId is needed (see
    Set-HaloClient-M365Alert.ps1 for the full explanation - same pattern,
    including why this takes -EncodedJson rather than a plain -TicketId).

    Blackpoint's alert is an HTML table, but confirmed via the debug log
    (Halo-Script-Debug.log) that on this Halo instance the ticket body's
    HTML-to-text conversion collapses ALL line/cell breaks, producing one
    run-on string with NO separators at all, e.g.:

        ...Login from Unapproved CountryCustomer NameSunshine Coast Oral,
        Facial & Implant SpecialistIP Address203.125.195.181City...

    So unlike the M365/Cloudally scripts (which rely on the value sitting
    on its own line after the label), this one bounds the value between
    two known labels - "Customer Name" and the next field, "IP Address" -
    since there's no line break to anchor on.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$EncodedJson
)

$CommonLibPath = "C:\ProgramData\Halo Integrator\Scripts\HaloCommon.ps1"

function Write-FallbackLog {
    param([string]$Message)
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
        Add-Content -Path "C:\ProgramData\Halo Integrator\Scripts\Halo-Script-Debug.log" -Value $line -Encoding UTF8
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

    Write-Log "Blackpoint alert script started for ticket $TicketId"
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
    # Confirmed via the debug log that on this instance the body comes
    # through as one run-on string with no separators, e.g.:
    #     ...Customer NameSunshine Coast Oral, Facial & Implant
    #     SpecialistIP Address203.125.195.181City...
    #
    # So the value is bounded between "Customer Name" and the NEXT known
    # label in Blackpoint's table, "IP Address" - non-greedy capture of
    # everything in between, trimmed.
    $orgName = $null
    if ($plainText -match '(?i)Customer Name\s*(.*?)\s*IP Address') {
        $orgName = $Matches[1]
    }
    Write-Log "Regex match result: '$orgName'"
    # -----------------------------------------------------

    Invoke-HaloClientReassignFromExtractedName -Token $token -Ticket $ticket -TicketId $TicketId `
        -ExtractedName $orgName -SourceDescription "Blackpoint Cyber alert"
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}