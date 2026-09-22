<#
.SYNOPSIS
    Halo PowerShell Integration script for Leader Cloud subscription
    renewal notification emails. Extracts the actual affected client
    (the "Customer" field) and reassigns the ticket's Client/Site to
    match - deliberately leaves the ticket's end-user/contact alone.

.DESCRIPTION
    Field Mappings: only Ticket ID -> TicketId is needed (see
    Set-HaloClient-M365Alert.ps1 for the full explanation - same pattern,
    including why this takes -EncodedJson rather than a plain -TicketId).

    IMPORTANT: unlike the alert scripts, these tickets land under a
    Leader Cloud notification "requester" (End-User) rather than a
    generic client - that end-user is correct and should NOT be
    changed. Only Client and Site need correcting. This is already how
    Invoke-HaloClientReassignFromExtractedName / Set-HaloTicketClient
    behave (they only ever set client_id/site_id on the ticket, never
    the requesting user), so no changes to HaloCommon.ps1 were needed
    for this - it's reused exactly as-is.

    The email greets the RESELLER by name ("Dear NETWORK OFFICE
    SUNSHINE COAST PTY LTD...") near the top - that is NOT the client to
    use, it's your own MSP. The actual affected client is the "Customer"
    field further down the body, e.g.:

        Customer:      Yandina Vet Clinic
        Email:         techsupport@networkofficesc.com.au
        Subscription:  Yandina Vet Clinic - M365 - Microsoft 365 ...

    Extraction:
      1. Primary: bounded between "Customer:" and the next label,
         "Email:" - same bounding technique as the Blackpoint/Cloudally
         scripts, since this Halo instance can flatten table cells with
         no line breaks between them.
      2. Fallback: the "Subscription:" field also repeats the client
         name as its own leading segment before " - ", e.g.
         "Yandina Vet Clinic - M365 - ..." -> "Yandina Vet Clinic".
         Used only if the Customer field extraction comes back empty.
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

    Write-Log "Leader Cloud renewal script started for ticket $TicketId"
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
    $orgName = $null

    # 1. Preferred: the "Customer:" field, bounded by the next label,
    #    "Email:" - not the "Dear <RESELLER>" greeting near the top,
    #    which names your own MSP, not the affected client.
    if ($plainText -match '(?i)Customer:?\s*(.*?)\s*Email:?') {
        $orgName = $Matches[1].Trim()
        Write-Log "Extracted name from Customer field: '$orgName'"
    }

    # 2. Fallback: the "Subscription:" field repeats the client name as
    #    its leading segment before " - ", e.g. "Yandina Vet Clinic -
    #    M365 - Microsoft 365 Business Premium (New Commerce)".
    if ([string]::IsNullOrWhiteSpace($orgName)) {
        if ($plainText -match '(?i)Subscription:?\s*(.*?)\s*-\s*.+?Description:?') {
            $orgName = $Matches[1].Trim()
            Write-Log "Extracted name from Subscription field (fallback): '$orgName'"
        }
    }

    Write-Log "Final extracted name: '$orgName'"
    # -----------------------------------------------------

    Invoke-HaloClientReassignFromExtractedName -Token $token -Ticket $ticket -TicketId $TicketId `
        -ExtractedName $orgName -SourceDescription "Leader Cloud subscription renewal notification"
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}