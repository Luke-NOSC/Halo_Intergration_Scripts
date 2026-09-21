<#
.SYNOPSIS
    Halo PowerShell Integration script for Veeam backup-failure alerts.
    Unlike the M365/Blackpoint alerts, these don't contain a client name
    anywhere in the text - only a short internal code - so this looks up
    that code against a manually maintained dictionary instead of
    matching on an organization name.

.DESCRIPTION
    Field Mappings: only Ticket ID -> TicketId is needed (see
    Set-HaloClient-M365Alert.ps1 for the full explanation - same pattern,
    including why this takes -EncodedJson rather than a plain -TicketId).

    Veeam alert Summaries come in two shapes:
      - "PFL-ZDISPENSER-MAR [Failed] Backup Configuration Job (1 objects)"
        - the code ("PFL") is a prefix right on the Summary.
      - "[Failed] 192.168.0.20 (1 objects) 1 failed"
        - no code on the Summary at all; the object is a bare IP or
          hostname with nothing to identify the client.

    For the second case, the actual client can usually still be
    identified from the ticket body - Veeam's job log includes full
    hostnames like "ATW-YDNA1-DC01.atw.local", where the AD domain
    suffix ("atw.local") reveals the client's code ("ATW") even when the
    Summary itself doesn't.

    All of the actual extraction/lookup logic lives in
    Get-VeeamAlertClientCode and Invoke-HaloVeeamAlertReassign in
    HaloCommon.ps1. The client code -> client name dictionary is
    $Global:VeeamClientMap, also in HaloCommon.ps1 - add new codes there
    as they show up; this script never needs to change for that.
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

    Write-Log "Veeam alert script started for ticket $TicketId"
    $token  = Get-HaloToken
    $ticket = Get-HaloTicket -Token $token -TicketId $TicketId

    Invoke-HaloVeeamAlertReassign -Token $token -Ticket $ticket -TicketId $TicketId
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}