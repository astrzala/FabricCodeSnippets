param(
  [Parameter(Mandatory = $true)] [string] $SubscriptionId,       # 1) Azure subscription ID
  [Parameter(Mandatory = $true)] [string] $ResourceGroupName,    # 2) Resource group with the Fabric capacity
  [Parameter(Mandatory = $true)] [string] $CapacityName,         # 3) Fabric Capacity name
  [Parameter(Mandatory = $true)] [string] $CapacityId,           # 4) Fabric Capacity ID
  [Parameter(Mandatory = $true)] [string] $WorkspaceId,          # 5) Workspace ID (Metrics semantic model)
  [Parameter(Mandatory = $true)] [string] $DatasetId,            # 6) Semantic model ID (dataset)
  [int] $UserTimezoneShiftHours = 0,                             # 7) User display timezone shift - adjust for your Timezone
  [int] $DataTimestampShiftHours = -5,                           # 8) Data correction shift (match the timestamp with your Timezone)
  [int] $IdleThresholdHours = 1,                                 # 9) Look back window (hours)
  [int] $MinimumCUThresholdSeconds = 100                         # 10) Noise threshold for the SUM of CU(s) in the window.
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Import-Module Az.Accounts -ErrorAction SilentlyContinue
Connect-AzAccount -Identity | Out-Null

# ---- ARM token (only) for the early state check ----
$tokenArm = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
$apiVersionArm = "2023-11-01"
$headersArm = @{ Authorization = "Bearer $tokenArm" }

# ---- Skip everything if already stopped/paused ----
$capGetUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/${CapacityName}?api-version=$apiVersionArm"
$cap = Invoke-RestMethod -Method GET -Uri $capGetUri -Headers $headersArm

$state = $cap.properties.state
if (-not $state) { $state = $cap.properties.status }
if (-not $state) { $state = $cap.properties.provisioningState }

if ($state -match 'Suspended|Stopped|Paused|Deallocated') {
  Write-Output "[STOPPED]    Capacity: $CapacityName → already SUSPENDED (state: $state)."
  return
}

# ---- Calculate Time Windows ----
$currentUtc = [DateTime]::UtcNow
$currentUserLocal = $currentUtc.AddHours($UserTimezoneShiftHours)
$currentFullHour = [DateTime]::new($currentUserLocal.Year, $currentUserLocal.Month, $currentUserLocal.Day, $currentUserLocal.Hour, 0, 0)
$windowStartTime = $currentFullHour.AddHours(-$IdleThresholdHours)

Write-Output "TIMEZONE CONFIGURATION:"
Write-Output "  User Timezone Shift:   $UserTimezoneShiftHours hours"
Write-Output "  Data Timestamp Shift:  $DataTimestampShiftHours hours"
Write-Output "------------------------------------------------------------"
Write-Output "TIME REFERENCE:"
Write-Output "  Azure Runbook UTC:     $($currentUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "  User Local Time:       $($currentUserLocal.ToString('yyyy-MM-dd HH:mm:ss')) (UTC$(if($UserTimezoneShiftHours -ge 0){'+'})$UserTimezoneShiftHours)"
Write-Output "  Current Full Hour:     $($currentFullHour.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Output "------------------------------------------------------------"
Write-Output "EVALUATION:"
Write-Output "  Idle Window:           Last $IdleThresholdHours hour(s) ( > $($windowStartTime.ToString('yyyy-MM-dd HH:mm:ss')) )"
Write-Output "  Noise Threshold:       $MinimumCUThresholdSeconds CU(s)"
Write-Output ""

# ---- Only now get PBI token and run DAX ----
$tokenPbi = (Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api").Token
$headersPbi = @{ Authorization = "Bearer $tokenPbi"; "Content-Type" = "application/json" }
$execUri = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId/executeQueries"

# ---- DAX query (Usage Summary Table) ----
$daxShiftHours = [Math]::Abs($DataTimestampShiftHours)
$daxQuery = @"
DEFINE
    VAR _CapacityID = "$CapacityId"

EVALUATE
    SELECTCOLUMNS(
        ADDCOLUMNS(
            SUMMARIZE(
                FILTER(
                    'Usage Summary (Last 24 hours)',
                    'Usage Summary (Last 24 hours)'[Capacity Id] = _CapacityID
                ),
                'Usage Summary (Last 24 hours)'[Timestamp]
            ),
            "CU_Seconds", CALCULATE(SUM('Usage Summary (Last 24 hours)'[CU (s)]))
        ),
        "CU_Consumption_Start", 'Usage Summary (Last 24 hours)'[Timestamp] - TIME($daxShiftHours, 0, 0),
        "CU_Seconds", [CU_Seconds]
    )
ORDER BY [CU_Consumption_Start] DESC
"@

Write-Output "Querying Usage Summary (Last 24 hours)..."

# ---- Execute and Process Results ----
$hasData = $false
$totalRecentCUs = 0
$rowsInWindow = 0

try {
  $body = @{ queries = @(@{ query = $daxQuery }); serializerSettings = @{ includeNulls = $true } } | ConvertTo-Json -Depth 6
  $response = Invoke-RestMethod -Method POST -Uri $execUri -Headers $headersPbi -Body $body
  
  $table = $response.results[0].tables[0]
  if ($table -and $table.rows -and $table.rows.Count -gt 0) {
    Write-Output "Timestamp (Shifted)       | CU Seconds   | In Window?"
    Write-Output "-------------------------|--------------|-----------"
    
    foreach ($row in $table.rows) {
      $timestampStr = $row.'[CU_Consumption_Start]'
      $cuSeconds = if ($row.'[CU_Seconds]') { [double]$row.'[CU_Seconds]' } else { 0 }
      
      $rowDt = [DateTime]::Parse($timestampStr)
      $rowFullHour = [DateTime]::new($rowDt.Year, $rowDt.Month, $rowDt.Day, $rowDt.Hour, 0, 0)

      # Accumulate if in window
      $inWindow = $false
      if ($rowFullHour -gt $windowStartTime) {
          $inWindow = $true
          $totalRecentCUs += $cuSeconds
          $rowsInWindow++
      }

      $windowFlag = if ($inWindow) { "<-- CHECK" } else { "" }
      "{0,-24} | {1,12:N2} | {2}" -f $timestampStr, $cuSeconds, $windowFlag
    }
    Write-Output ""
  }
}
catch {
  Write-Output "[ERROR] Query failed: $($_.Exception.Message)"
  return
}

# ---- Decide on suspend ----
Write-Output "  Total CUs in Window:   $([math]::Round($totalRecentCUs, 2))"
if ($totalRecentCUs -gt $MinimumCUThresholdSeconds) {
    Write-Output "[ACTIVE]  SumCUs: $([math]::Round($totalRecentCUs, 2)) | Threshold: $MinimumCUThresholdSeconds | Capacity: $CapacityName → STILL RUNNING"
    return
}

# ---- Suspend ----
$svcUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/${CapacityName}/suspend?api-version=$apiVersionArm"
try {
  Invoke-RestMethod -Method POST -Uri $svcUri -Headers $headersArm | Out-Null
  Write-Output "[IDLE]    SumCUs: $([math]::Round($totalRecentCUs, 2)) | Threshold: $MinimumCUThresholdSeconds | Capacity: $CapacityName → SUSPENDING..."
}
catch {
  $msg = $_.Exception.Message
  Write-Output "[ERROR]   SumCUs: $([math]::Round($totalRecentCUs, 2)) | Capacity: $CapacityName → SUSPEND FAILED: $msg"
  throw
}
