<#
.SYNOPSIS
    Shared functions for Halo PowerShell Integration scripts. Not run
    directly - dot-sourced from each alert-specific script, e.g.:

        . "$PSScriptRoot\HaloCommon.ps1"

    Keep this file in the SAME folder as the alert-specific scripts.

.NOTES
    Fill in your Halo URL / Client ID / Client Secret once, here - every
    script that dot-sources this file will use the same credentials.
#>

# ----------------- CONFIG - EDIT THESE ------------------
$Global:HaloBaseUrl  = "https://networkofficesc.halopsa.com"   # no trailing slash
$Global:HaloClientId = "9e2d6e44-0094-482d-b39e-695a69fff952"
$Global:HaloSecret   = "21S_rh5gCgj3HKcfTTysfbfbfc2ATMy5bhkxv4411o8"
$Global:HaloApiTimeoutSec = 30   # every API call below fails fast after this many seconds instead of hanging indefinitely
$Global:HaloLogFile = "C:\ProgramData\Halo Integrator\Scripts\Halo-Script-Debug.log"
$Global:HaloScheduledQueueStatusName = "Scheduled Queue"   # only used as a fallback if HaloScheduledQueueStatusId below is 0 - must match a status name exactly as configured in Halo (Configuration > Tickets > Status)
$Global:HaloScheduledQueueStatusId = 23   # set to the real status ID (e.g. from the URL when viewing/editing the status in Halo config) to skip the name lookup entirely. Set to 0 to fall back to looking it up by name instead.
# ---------------------------------------------------------

# ----------------- VEEAM ALERT CLIENT MAPPING ------------------
# Veeam backup-failure alerts don't spell out a client/organization name
# anywhere in the email - only a short internal code (either a prefix on
# the job name, e.g. "PFL-ZDISPENSER-MAR", or the client's AD domain, e.g.
# "atw.local"). There's no way to derive the real client name from that
# code by matching text - it has to be a manually maintained lookup.
#
# Add/edit entries here as new codes show up. Keys are matched
# case-insensitively.
$Global:VeeamClientMap = @{
    "PFL"          = "Pharmacy For Life"
    "ATW"          = "All Terrain Warriors"
    "SGTS01"       = "Sunshine Smallgoods"
    "192.168.0.20" = "All Terrain Warriors"   # fallback only - the ATW AD domain match (atw.local) in the body should normally catch this one directly
}
# -----------------------------------------------------------------

function Write-Log {
    # File-only logging. IMPORTANT: this deliberately does NOT Write-Host
    # anymore - Halo's PowerShell integration captures console/stdout
    # output and posts it back to the ticket as its own "PowerShell
    # Result" note, which duplicated and cluttered the clean
    # "Automation successful..." note Add-HaloPrivateNote already posts.
    # All debug detail still goes to $Global:HaloLogFile on disk - open
    # that file directly when troubleshooting, rather than the ticket.
    param([string]$Message, [string]$Color = "White")

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    try {
        $logDir = Split-Path -Path $Global:HaloLogFile -Parent
        if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $Global:HaloLogFile -Value $line -Encoding UTF8
    } catch {
        # If we can't write the log file, there's nothing more we can do -
        # swallow it rather than let logging itself crash the script.
    }
}

# Disable Windows proxy auto-detection (WPAD). Without this, the FIRST web
# request made by a script running under a non-interactive host (like the
# Integrator's own process, as opposed to your own interactive console
# session) can hang indefinitely probing for a WPAD server that doesn't
# exist on most networks - this is the classic "works fine when I run it
# myself, hangs forever when the Integrator runs it" symptom.
[System.Net.WebRequest]::DefaultWebProxy = $null

function Get-HaloToken {
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $Global:HaloClientId
        client_secret = $Global:HaloSecret
        scope         = "all"
    }
    $tokenResponse = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/auth/token" -Method Post `
        -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -TimeoutSec $Global:HaloApiTimeoutSec

    if (-not $tokenResponse.access_token) { throw "No access_token returned - check credentials." }
    return $tokenResponse.access_token
}

function Get-HaloTicket {
    param([string]$Token, [int]$TicketId)

    $ticketUrl = "$Global:HaloBaseUrl/api/Tickets/$TicketId`?includedetails=true"
    return Invoke-RestMethod -Uri $ticketUrl -Method Get `
        -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec $Global:HaloApiTimeoutSec
}

function Get-PlainTextBody {
    # Normalises details/details_html into plain-ish text so the same
    # regexes work regardless of which field actually had content:
    # strips tags, decodes a couple of common entities, collapses blank
    # runs so "Label" and "Value" reliably end up on separate lines.
    param([object]$Ticket)

    $raw = if ($Ticket.details) { $Ticket.details }
           elseif ($Ticket.details_html) { $Ticket.details_html }
           else { "" }

    $text = $raw -replace '<[^>]+>', "`n"
    $text = $text -replace '&nbsp;', ' ' -replace '&amp;', '&'
    $text = $text -replace '(\r?\n\s*){2,}', "`n"
    return $text.Trim()
}

function Find-BestClientMatch {
    # Shared exact/substring matching logic against whatever candidate
    # list is passed in.
    param([array]$Candidates, [string]$ExtractedName)

    $exact = $Candidates | Where-Object { $_.name -ieq $ExtractedName } | Select-Object -First 1
    if ($exact) { return $exact }

    $partial = $Candidates | Where-Object {
        $_.name -and ($ExtractedName -like "*$($_.name)*" -or $_.name -like "*$ExtractedName*")
    } | Sort-Object { $_.name.Length } -Descending

    return $partial | Select-Object -First 1
}

function Find-HaloClientByName {
    # Looks up a client whose Halo name matches (case-insensitive,
    # substring-tolerant) the name extracted from the email. Returns the
    # single best match, or $null if none/ambiguous.
    #
    # IMPORTANT: /api/Client with no search term is paginated (observed
    # returning only 50 results by default), so a bare full-list fetch can
    # silently miss a real client that just isn't alphabetically early
    # enough to make the first page. To avoid that:
    #   1. Try the API's own "search" query param first - fast and exact.
    #   2. If that finds nothing, page through the ENTIRE client list
    #      (not just page 1) as a fallback before giving up.
    param([string]$Token, [string]$ExtractedName)

    if ([string]::IsNullOrWhiteSpace($ExtractedName)) { return $null }
    $ExtractedName = $ExtractedName.Trim()
    $headers = @{ Authorization = "Bearer $Token" }

    # ----- Attempt 1: server-side search -----
    try {
        $encoded = [System.Uri]::EscapeDataString($ExtractedName)
        $searchResponse = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Client`?search=$encoded&includeinactive=false" `
            -Method Get -Headers $headers -TimeoutSec $Global:HaloApiTimeoutSec

        $searchResults = if ($searchResponse.clients) { $searchResponse.clients } else { $searchResponse }
        if ($searchResults -and $searchResults.Count -gt 0) {
            Write-Log "Find-HaloClientByName: search=$ExtractedName returned $($searchResults.Count) candidate(s): $(($searchResults | Select-Object -ExpandProperty name) -join '; ')"
            $match = Find-BestClientMatch -Candidates $searchResults -ExtractedName $ExtractedName
            if ($match) { return $match }
        } else {
            Write-Log "Find-HaloClientByName: search=$ExtractedName returned 0 results - falling back to full paginated list."
        }
    } catch {
        Write-Log "Find-HaloClientByName: search query failed ($($_.Exception.Message)) - falling back to full paginated list." "Yellow"
    }

    # ----- Attempt 2: page through the FULL client list -----
    $allClients = @()
    $pageNo = 1
    $pageSize = 200
    do {
        $pageResponse = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Client`?includeinactive=false&pageinate=true&page_size=$pageSize&page_no=$pageNo" `
            -Method Get -Headers $headers -TimeoutSec $Global:HaloApiTimeoutSec

        $pageClients = if ($pageResponse.clients) { $pageResponse.clients } else { $pageResponse }
        if (-not $pageClients -or $pageClients.Count -eq 0) { break }

        $allClients += $pageClients
        Write-Log "Find-HaloClientByName: fetched page $pageNo ($($pageClients.Count) client(s), $($allClients.Count) total so far)."
        $pageNo++
    } while ($pageClients.Count -eq $pageSize -and $pageNo -le 25)   # hard cap at 5000 clients as a safety stop

    if ($allClients.Count -eq 0) {
        Write-Log "Find-HaloClientByName: full paginated fetch returned NO clients at all." "Yellow"
        return $null
    }

    Write-Log "Find-HaloClientByName: full list retrieved, $($allClients.Count) client(s) total."
    $match = Find-BestClientMatch -Candidates $allClients -ExtractedName $ExtractedName
    if ($match) { return $match }

    $firstWord = ($ExtractedName -split '\s+')[0]
    $looseHit = $allClients | Where-Object { $_.name -and $_.name -like "*$firstWord*" }
    if ($looseHit) {
        Write-Log "Find-HaloClientByName: no exact/substring match, but found name(s) containing '$firstWord': $(($looseHit | Select-Object -ExpandProperty name) -join '; ')" "Yellow"
    } else {
        Write-Log "Find-HaloClientByName: '$firstWord' does not appear in ANY of the $($allClients.Count) client names in the FULL list - the client may genuinely not exist in Halo yet, or its name differs more than expected from the extracted text." "Yellow"
    }
    return $null
}

function Set-HaloTicketClient {
    param([string]$Token, [int]$TicketId, [int]$ClientId, [int]$SiteId = 0)

    $payload = @{ id = $TicketId; client_id = $ClientId }
    if ($SiteId -gt 0) { $payload.site_id = $SiteId }
    $json = "[$(($payload | ConvertTo-Json -Depth 5))]"

    Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Tickets" -Method Post `
        -Headers @{ Authorization = "Bearer $Token" } `
        -ContentType "application/json" -Body $json -TimeoutSec $Global:HaloApiTimeoutSec | Out-Null
}

function Get-HaloClientMainSite {
    # Finds the "main" site for a client. Halo doesn't expose a single
    # obvious flag for this consistently, so we try, in order:
    #   1. main_site_id on the client record itself (if the API version/
    #      config you have exposes it)
    #   2. A site literally named "Main Site" (Halo's own default name for
    #      the site auto-created with a new client, unless renamed)
    #   3. Whichever site has the lowest ID (typically the first/original
    #      site created for that client)
    # Returns $null if the client has no sites at all.
    param([string]$Token, [int]$ClientId)

    if ($ClientId -le 0) { return $null }
    $headers = @{ Authorization = "Bearer $Token" }

    if ($ClientId) {
        try {
            $clientDetail = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Client/$ClientId`?includedetails=true" `
                -Method Get -Headers $headers -TimeoutSec $Global:HaloApiTimeoutSec
            if ($clientDetail.main_site_id -and $clientDetail.main_site_id -gt 0) {
                Write-Log "Get-HaloClientMainSite: client record has main_site_id = $($clientDetail.main_site_id)"
                return $clientDetail.main_site_id
            }
        } catch {
            Write-Log "Get-HaloClientMainSite: failed to fetch client detail - $($_.Exception.Message)" "Yellow"
        }
    }

    try {
        $sitesResponse = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Site`?client_id=$ClientId&includeinactive=false" `
            -Method Get -Headers $headers -TimeoutSec $Global:HaloApiTimeoutSec
        $sites = if ($sitesResponse.sites) { $sitesResponse.sites } else { $sitesResponse }

        if (-not $sites -or $sites.Count -eq 0) {
            Write-Log "Get-HaloClientMainSite: client $ClientId has no sites returned by /api/Site." "Yellow"
            return $null
        }

        $namedMain = $sites | Where-Object { $_.name -ieq "Main Site" } | Select-Object -First 1
        if ($namedMain) {
            Write-Log "Get-HaloClientMainSite: found site literally named 'Main Site' (ID $($namedMain.id))"
            return $namedMain.id
        }

        $lowestId = $sites | Sort-Object id | Select-Object -First 1
        Write-Log "Get-HaloClientMainSite: no site named 'Main Site' - falling back to lowest-ID site '$($lowestId.name)' (ID $($lowestId.id))"
        return $lowestId.id
    } catch {
        Write-Log "Get-HaloClientMainSite: failed to fetch sites - $($_.Exception.Message)" "Yellow"
        return $null
    }
}

function Write-Result {
    # Prints ONLY to the console (not the file log) - this is what ends up
    # captured by Halo's own "PowerShell Result" ticket note. Use this for
    # the single final outcome message only; everything else (step detail)
    # should go through Write-Log so it doesn't clutter that note.
    param([string]$Message)
    try { Write-Host $Message } catch {}
}

function Add-HaloPrivateNote {
    param([string]$Token, [int]$TicketId, [string]$NoteText)

    $body = @{
        ticket_id      = $TicketId
        note           = $NoteText
        outcome        = "Private Note"
        hiddenfromuser = $true
    }
    $json = "[$(($body | ConvertTo-Json -Depth 5))]"

    try {
        Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Actions" -Method Post `
            -Headers @{ Authorization = "Bearer $Token" } `
            -ContentType "application/json" -Body $json -TimeoutSec $Global:HaloApiTimeoutSec | Out-Null
    } catch {
        Write-Log "Could not add private note: $($_.Exception.Message)" "Yellow"
    }
}

function Get-HaloStatusIdByName {
    # Looks up a ticket status ID by its display name (e.g. "Scheduled
    # Queue"). Status IDs differ per Halo instance/configuration, so this
    # is resolved by name each run rather than hardcoded.
    param([string]$Token, [string]$StatusName)

    if ([string]::IsNullOrWhiteSpace($StatusName)) { return $null }
    $headers = @{ Authorization = "Bearer $Token" }

    try {
        $response = Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Status" -Method Get `
            -Headers $headers -TimeoutSec $Global:HaloApiTimeoutSec
        $statuses = if ($response.statuses) { $response.statuses } else { $response }

        if (-not $statuses -or $statuses.Count -eq 0) {
            Write-Log "Get-HaloStatusIdByName: /api/Status returned no statuses." "Yellow"
            return $null
        }

        $match = $statuses | Where-Object { $_.name -ieq $StatusName } | Select-Object -First 1
        if (-not $match) {
            $match = $statuses | Where-Object { $_.name -like "*$StatusName*" } | Select-Object -First 1
        }

        if ($match) {
            Write-Log "Get-HaloStatusIdByName: matched '$StatusName' -> '$($match.name)' (ID $($match.id))"
            return $match.id
        }

        Write-Log "Get-HaloStatusIdByName: no status matching '$StatusName' found. Available: $(($statuses | Select-Object -ExpandProperty name) -join '; ')" "Yellow"
        return $null
    } catch {
        Write-Log "Get-HaloStatusIdByName: failed to fetch statuses - $($_.Exception.Message)" "Yellow"
        return $null
    }
}

function Set-HaloTicketStatus {
    param([string]$Token, [int]$TicketId, [int]$StatusId)

    $payload = @{ id = $TicketId; status_id = $StatusId }
    $json = "[$(($payload | ConvertTo-Json -Depth 5))]"

    Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Tickets" -Method Post `
        -Headers @{ Authorization = "Bearer $Token" } `
        -ContentType "application/json" -Body $json -TimeoutSec $Global:HaloApiTimeoutSec | Out-Null
}

function New-HaloTicketAppointment {
    # Creates a fixed 4:00pm-4:30pm (AEST, UTC+10, no daylight saving)
    # "holding" appointment for whichever agent is assigned to the ticket,
    # titled "<Client> - <Alert type>". Intended to run as a second step
    # straight after a successful client reassignment - your separate
    # "fill the gaps" automation (every 5 min) is what actually moves this
    # into an earlier free slot in the agent's day; this function just
    # needs to get an appointment onto the calendar in the first place.
    #
    # Uses a fixed +10:00 offset rather than the server's local timezone,
    # so this produces the correct wall-clock time in AEST regardless of
    # what timezone the box running the Integrator is set to.
    param(
        [string]$Token,
        [object]$Ticket,
        [int]$TicketId
    )

    $token = $Token
    $ticket = $Ticket

    $agentId = $ticket.agent_id
    $agentName = $ticket.agent_name

    if (-not $agentId -or $agentId -le 0) {
        $msg = "Appointment Scheduling: Ticket has no agent assigned, so no appointment could be created. Please assign an agent and schedule manually."
        Write-Log $msg "Yellow"
        Write-Result $msg
        return
    }

    $clientName = if ($ticket.client_name) { $ticket.client_name } else { "Unknown Client" }

    # "Type of alert" - taken from the ticket's "Request Category" field,
    # which on this Halo instance is Category 4 (category_4). Falls back
    # to category_1, then the summary, so the appointment title is never
    # left blank if category_4 isn't set on a given ticket.
    $alertType = if ($ticket.category_4) { $ticket.category_4 }
                 elseif ($ticket.category_1) { $ticket.category_1 }
                 elseif ($ticket.summary) { $ticket.summary }
                 else { "Alert" }

    $subject = "$clientName - $alertType"

    # Fixed +10:00 offset, applied to "today" as it currently is in that
    # offset (not the server's local calendar date), so this is correct
    # even if the Integrator runs on a box set to a different timezone or
    # right around local midnight.
    $aestOffset = [TimeSpan]::FromHours(10)
    $aestNow = [DateTimeOffset]::UtcNow.ToOffset($aestOffset)
    $startLocal = New-Object DateTimeOffset ($aestNow.Year, $aestNow.Month, $aestNow.Day, 16, 0, 0, $aestOffset)
    $endLocal = $startLocal.AddMinutes(30)

    $startUtc = $startLocal.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endUtc = $endLocal.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Log "New-HaloTicketAppointment: agent '$agentName' (ID $agentId), subject '$subject', $startLocal -> $endLocal (AEST)"

    $payload = @{
        ticket_id  = $TicketId
        agent_id   = $agentId
        subject    = $subject
        start_date = $startUtc
        end_date   = $endUtc
        utcoffset  = 10
    }
    if ($ticket.client_id) { $payload.client_id = $ticket.client_id }
    if ($ticket.site_id)   { $payload.site_id   = $ticket.site_id }

    $json = "[$(($payload | ConvertTo-Json -Depth 5))]"

    try {
        Invoke-RestMethod -Uri "$Global:HaloBaseUrl/api/Appointment" -Method Post `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType "application/json" -Body $json -TimeoutSec $Global:HaloApiTimeoutSec | Out-Null

        $msg = "Appointment Scheduling: A 30-minute appointment ('$subject') has been created for $agentName at 4:00pm-4:30pm AEST."
        Write-Log $msg "Green"

        # Also move the ticket into the "Scheduled Queue" status, now that
        # it has an appointment on the calendar. Prefer the hardcoded ID
        # (fast, no extra API call, no name-matching to go wrong) and only
        # fall back to looking it up by name if that hasn't been set.
        if ($Global:HaloScheduledQueueStatusId -and $Global:HaloScheduledQueueStatusId -gt 0) {
            $statusId = $Global:HaloScheduledQueueStatusId
            Write-Log "Using configured status ID $statusId (skipping name lookup)."
        } else {
            Write-Log "No HaloScheduledQueueStatusId configured - looking up status ID for '$($Global:HaloScheduledQueueStatusName)'..."
            $statusId = Get-HaloStatusIdByName -Token $token -StatusName $Global:HaloScheduledQueueStatusName
        }

        if ($statusId) {
            try {
                Set-HaloTicketStatus -Token $token -TicketId $TicketId -StatusId $statusId
                Write-Log "Ticket status set to ID $statusId." "Green"
                $msg += " Ticket status set to '$($Global:HaloScheduledQueueStatusName)'."
            } catch {
                Write-Log "Failed to set ticket status - $($_.Exception.Message)" "Yellow"
                $msg += " Note: the appointment was created, but the ticket status could not be updated - please set it manually."
            }
        } else {
            $msg += " Note: the appointment was created, but no status ID could be determined (check HaloScheduledQueueStatusId/StatusName in HaloCommon.ps1) - please set the status manually."
        }

        Write-Result $msg
    } catch {
        $msg = "Appointment Scheduling: Failed to create the appointment for $agentName - $($_.Exception.Message)"
        Write-Log $msg "Red"
        if ($_.ErrorDetails) { Write-Log "Error details: $($_.ErrorDetails.Message)" "Yellow" }
        Write-Result $msg
    }
}

function Invoke-HaloClientReassignFromExtractedName {
    # The one function each alert-specific script calls once it has
    # pulled the org/client name out of the ticket body. Takes the
    # already-authenticated token and already-fetched ticket (so callers
    # do the auth/fetch ONCE, not twice) and handles lookup, reassignment,
    # and the audit-trail note.
    param(
        [string]$Token,
        [object]$Ticket,
        [int]$TicketId,
        [string]$ExtractedName,
        [string]$SourceDescription   # e.g. "Microsoft 365 vulnerability alert"
    )

    $token = $Token
    $ticket = $Ticket

    Write-Log "===== Run started for ticket $TicketId ($SourceDescription) ====="
    Write-Log "Extracted name from body: '$ExtractedName'"
    Write-Log "Current client on ticket: '$($ticket.client_name)' (ID $($ticket.client_id))"

    if ([string]::IsNullOrWhiteSpace($ExtractedName)) {
        $msg = "Client Auto-Detection ($SourceDescription): No organization name could be identified in the ticket body. No changes were made; please review and reassign this ticket manually."
        Write-Log $msg "Yellow"
        Write-Result $msg
        return
    }

    Write-Log "Fetching client list to match against '$ExtractedName'..."
    $match = Find-HaloClientByName -Token $token -ExtractedName $ExtractedName
    if ($match) {
        Write-Log "Client lookup finished. Best match: '$($match.name)' (ID $($match.id))"
    } else {
        Write-Log "Client lookup finished. No match found."
    }

    if (-not $match) {
        $msg = "Client Auto-Detection ($SourceDescription): The organization '$ExtractedName' was identified in the ticket body but does not match any client on record in Halo. No changes were made; please review and reassign this ticket manually."
        Write-Log $msg "Yellow"
        Write-Result $msg
        return
    }

    if ($ticket.client_id -eq $match.id) {
        $msg = "Client Auto-Detection: This ticket is already correctly assigned to '$($match.name)'. No action was required."
        Write-Log $msg "Green"
        Write-Result $msg
        return
    }

    Write-Log "Looking up main site for client '$($match.name)' (ID $($match.id))..."
    $mainSiteId = Get-HaloClientMainSite -Token $token -ClientId $match.id

    if ($mainSiteId) {
        Set-HaloTicketClient -Token $token -TicketId $TicketId -ClientId $match.id -SiteId $mainSiteId
        Write-Log "Set client + site (site ID $mainSiteId)." "Green"
        $msg = "Client Auto-Detection: This ticket has been automatically reassigned to client '$($match.name)' and its main site, based on the organization named in the ticket body."
    } else {
        Set-HaloTicketClient -Token $token -TicketId $TicketId -ClientId $match.id
        Write-Log "Set client only - no site could be determined." "Yellow"
        $msg = "Client Auto-Detection: This ticket has been automatically reassigned to client '$($match.name)', based on the organization named in the ticket body. A site could not be determined automatically; please review."
    }

    Write-Log $msg "Green"
    Write-Result $msg
    Write-Log "===== Run finished for ticket $TicketId ====="
}

function Get-VeeamAlertClientCode {
    # Veeam backup-failure alerts don't contain a client/organization name
    # anywhere in the text - only a short internal code. This tries three
    # ways to find that code, most reliable first:
    #
    #   1. A "<CODE>-" prefix on the ticket Summary itself, e.g.
    #      "PFL-ZDISPENSER-MAR [Failed] ..." -> "PFL". Present on most
    #      alerts, and unambiguous when it is.
    #   2. The client's AD domain suffix inside the ticket body, e.g. a
    #      hostname like "ATW-YDNA1-DC01.atw.local" -> "ATW". Needed for
    #      alerts where the Summary is just "[Failed] <object>" with no
    #      prefix (bare IPs, bare hostnames like "SGTS01").
    #   3. A last-resort scan for any code already in $Global:VeeamClientMap
    #      appearing as a whole word anywhere in the Summary or body - a
    #      safety net for one-off formats (e.g. matching "SGTS01" literally).
    #
    # Returns the code in upper case, or $null if nothing was found.
    param([object]$Ticket, [string]$PlainText)

    $summary = $Ticket.summary

    if ($summary -and $summary -match '^\s*([A-Za-z0-9]+)-\S*\s*\[Failed\]') {
        return $Matches[1].ToUpper()
    }

    if ($PlainText -and $PlainText -match '(?i)\.([A-Za-z0-9]+)\.local\b') {
        return $Matches[1].ToUpper()
    }

    $haystack = "$summary `n$PlainText"
    foreach ($code in $Global:VeeamClientMap.Keys) {
        if ($haystack -match "(?i)\b$([regex]::Escape($code))\b") {
            return $code.ToUpper()
        }
    }

    return $null
}

function Invoke-HaloVeeamAlertReassign {
    # Entry point for the Veeam alert script. Extracts the internal code
    # (see Get-VeeamAlertClientCode), looks it up in the manually
    # maintained $Global:VeeamClientMap dictionary, and - once it has a
    # real client name - hands off to the same reassignment routine the
    # M365/Blackpoint scripts use, so lookup-by-name, site assignment and
    # the outcome note all behave identically across every alert type.
    param(
        [string]$Token,
        [object]$Ticket,
        [int]$TicketId
    )

    $token = $Token
    $ticket = $Ticket
    $plainText = Get-PlainTextBody -Ticket $ticket

    Write-Log "===== Veeam alert run started for ticket $TicketId ====="
    Write-Log "Current client on ticket: '$($ticket.client_name)' (ID $($ticket.client_id))"

    $code = Get-VeeamAlertClientCode -Ticket $ticket -PlainText $plainText
    Write-Log "Extracted alert code: '$code'"

    if (-not $code) {
        $msg = "Client Auto-Detection (Veeam backup alert): No recognisable client code was found in this alert. No changes were made; please review and reassign this ticket manually."
        Write-Log $msg "Yellow"
        Write-Result $msg
        return
    }

    $clientName = $Global:VeeamClientMap[$code]
    if (-not $clientName) {
        $msg = "Client Auto-Detection (Veeam backup alert): Identified alert code '$code', but it is not yet mapped to a client. No changes were made; please add '$code' to `$Global:VeeamClientMap in HaloCommon.ps1 and reassign this ticket manually."
        Write-Log $msg "Yellow"
        Write-Result $msg
        return
    }

    Write-Log "Code '$code' maps to client '$clientName' - handing off to the standard reassignment routine."
    Invoke-HaloClientReassignFromExtractedName -Token $token -Ticket $ticket -TicketId $TicketId `
        -ExtractedName $clientName -SourceDescription "Veeam backup alert (code '$code')"
}