param(
  [Parameter(Mandatory = $true)] [string] $SubscriptionId,         # 1) Azure subscription ID
  [Parameter(Mandatory = $true)] [string] $ResourceGroupName,      # 2) Resource group with the Fabric capacity
  [Parameter(Mandatory = $true)] [string] $CapacityName,           # 3) Fabric Capacity Name
  [Parameter(Mandatory = $true)]                                   # 4) Operation (accepts short synonyms; normalized to 'suspend' or 'resume')
  [ValidateSet("suspend","resume","stop","start","pause","run","0","1", IgnoreCase = $true)]
  [string] $Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ---- Normalize to ARM operation ----
$op = switch ($Operation.ToLower().Trim()) {
  "suspend" { "suspend" }
  "stop"    { "suspend" }
  "pause"   { "suspend" }
  "0"       { "suspend" }
  "resume"  { "resume"  }
  "start"   { "resume"  }
  "run"     { "resume"  }
  "1"       { "resume"  }
}

# ---- Auth ----
Import-Module Az.Accounts -ErrorAction SilentlyContinue
Connect-AzAccount -Identity | Out-Null
$tokenArm = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token

# ---- ARM call ----
$apiVersion = "2023-11-01"
$svcBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName"
$svcUri  = "$svcBase/${op}?api-version=$apiVersion"
$headers = @{ Authorization = "Bearer $tokenArm" }

# ---- Check if already suspended ----
if ($op -eq "suspend") {
  $cap = Invoke-RestMethod -Method GET -Uri "${svcBase}?api-version=$apiVersion" -Headers $headers
  $state = $cap.properties.state
  if (-not $state) { $state = $cap.properties.status }
  if (-not $state) { $state = $cap.properties.provisioningState }

  if ($state -match 'Suspended|Stopped|Paused|Deallocated') {
    Write-Output "🛌 [IDLE]  Capacity: $CapacityName → already SUSPENDED (state: $state)."
    return
  }
}

try {
  $null = Invoke-RestMethod -Method POST -Uri $svcUri -Headers $headers
  if ($op -eq "suspend") {
    Write-Output "[IDLE]   Capacity: $CapacityName → SUSPENDING..."
  } else {
    Write-Output "[RESUME] Capacity: $CapacityName → RESUMING..."
  }
}
catch {
  $msg = $_.Exception.Message
  if ($op -eq "suspend") {
    Write-Output "[ERROR]  Capacity: $CapacityName → SUSPEND FAILED: $msg"
  } else {
    Write-Output "[ERROR]  Capacity: $CapacityName → RESUME FAILED: $msg"
  }
  throw
}
