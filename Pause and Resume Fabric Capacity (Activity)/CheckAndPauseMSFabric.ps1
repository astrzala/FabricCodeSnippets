param(
  [Parameter(Mandatory = $true)] [string] $SubscriptionId,      # 1) Azure subscription ID
  [Parameter(Mandatory = $true)] [string] $ResourceGroupName,   # 2) Resource group with the Fabric capacity
  [Parameter(Mandatory = $true)] [string] $CapacityName,        # 3) Fabric Capacity name
  [Parameter(Mandatory = $true)] [string] $CapacityId,          # 4) Fabric Capacity ID
  [Parameter(Mandatory = $true)] [string] $WorkspaceId,         # 5) Workspace ID (where the Fabric Capacity Metrics semantic model lives)
  [Parameter(Mandatory = $true)] [string] $DatasetId,           # 6) Semantic model ID (dataset)
  [int] $UTCshiftMinutes = 120,                                 # 7) UTC shift in minutes (e.g., 120 for UTC+2)
  [int] $WindowMinutes = 15                                     # 8) Timeframe/window (minutes) to check for activity
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
  Write-Output "🛌 [IDLE]   Capacity: $CapacityName → already SUSPENDED (state: $state)."
  return
}

# ---- Only now get PBI token and run DAX, since capacity is running ----
$tokenPbi = (Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api").Token

# ---- DAX query ----
$dax = @"
DEFINE
  VAR ShiftMinutes  = $([double]$UTCshiftMinutes)
  VAR WindowMinutes = $([double]$WindowMinutes)
  VAR TargetCapId   = "$CapacityId"

  VAR CurrentTime = UTCNOW() + (ShiftMinutes / 1440.0)

  VAR __CapFilter =
    TREATAS( { TargetCapId }, 'Capacities'[capacity Id] )

  VAR __TimeFilter =
    FILTER(
      KEEPFILTERS( ALL('TimePoints'[TimePoint]) ),
      'TimePoints'[TimePoint] >= CurrentTime - (WindowMinutes / 1440.0)
      && 'TimePoints'[TimePoint] < CurrentTime - 1/1440.0
    )

  VAR SumCUs =
    CALCULATE(
      SUM('CU Detail'[CU (s)]),
      __CapFilter,
      __TimeFilter
    )

EVALUATE
  ROW(
    "SumCUs",      SumCUs,
    "HasActivity", IF(SumCUs > 0, 1, 0),
    "CurrentTime", UTCNOW() + (ShiftMinutes / 1440.0)
  )
"@

# ---- ExecuteQueries ----
$headersPbi = @{ Authorization = "Bearer $tokenPbi"; "Content-Type" = "application/json" }
$body = @{ queries = @(@{ query = $dax }); serializerSettings = @{ includeNulls = $true } } | ConvertTo-Json -Depth 6
$execUri = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId/executeQueries"
$response = Invoke-RestMethod -Method POST -Uri $execUri -Headers $headersPbi -Body $body

# ---- Extract SumCUs ----
$sumCUs = 0.0
$table = $response.results[0].tables[0]
if ($table -and $table.rows -and $table.rows.Count -gt 0) {
  $row0 = $table.rows[0]
  if ($row0 -is [pscustomobject] -or $row0 -is [hashtable]) {
    $sumCUs = [double]($row0.'[SumCUs]')
  }
}

# ---- Decide on suspend ----
if ($sumCUs -gt 0) {
  Write-Output "[ACTIVE]  SumCUs: $sumCUs | Window: $WindowMinutes min | Capacity: $CapacityName → STILL RUNNING"
  return
}

# ---- Suspend (with safe interpolation) ----
$svcUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/${CapacityName}/suspend?api-version=$apiVersionArm"

try {
  Invoke-RestMethod -Method POST -Uri $svcUri -Headers $headersArm | Out-Null
  Write-Output "[IDLE]   SumCUs: $sumCUs | Window: $WindowMinutes min | Capacity: $CapacityName → SUSPENDING..."
}
catch {
  $msg = $_.Exception.Message
  Write-Output "[ERROR]  SumCUs: $sumCUs | Window: $WindowMinutes min | Capacity: $CapacityName → SUSPEND FAILED: $msg"
  throw
}
