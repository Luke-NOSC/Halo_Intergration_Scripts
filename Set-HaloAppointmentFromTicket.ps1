<#
.SYNOPSIS
    Halo PowerShell Integration script: creates a 30-minute holding
    appointment (4:00pm-4:30pm AEST/UTC+10) for the ticket's assigned
    agent, titled "<Client> - <Request Category>".

.DESCRIPTION
    Intended to run as a second step straight after one of the client
    reassignment scripts (Halo-M365.ps1 / Halo-Cloudally.ps1) has
    successfully matched and reassigned the ticket's client - by that
    point the ticket has the correct client and (assuming it's already
    triaged) an agent assigned, so this script only needs the ticket ID
    to build the appointment.

    Your separate "fill the gaps" automation (running every 5 minutes)
    is what moves this appointment earlier into a free slot in the
    agent's day - this script's only job is to get it onto the calendar
    in the first place.

    Field Mappings (Configuration > Integrations > PowerShell > this
    script > Field Mappings) - only one field needed, same as the other
    scripts:
        Ticket ID -> TicketId

    "Type of alert" in the appointment title comes from the ticket's
    Request Category field (category_4 on this instance), falling back
    to category_1 then the ticket summary if that's not set - see
    New-HaloTicketAppointment in HaloCommon.ps1 if you want to change
    that source.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$EncodedJson
)

# Hardcoded path rather than $PSScriptRoot - see Halo-M365.ps1 for why.
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

    Write-Log "Appointment script started for ticket $TicketId"
    $token  = Get-HaloToken
    $ticket = Get-HaloTicket -Token $token -TicketId $TicketId

    Write-Log "Ticket $TicketId - client '$($ticket.client_name)' (ID $($ticket.client_id)), agent '$($ticket.agent_name)' (ID $($ticket.agent_id)), category_4 '$($ticket.category_4)'"

    New-HaloTicketAppointment -Token $token -Ticket $ticket -TicketId $TicketId
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" "Red"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "Red"
    if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
}