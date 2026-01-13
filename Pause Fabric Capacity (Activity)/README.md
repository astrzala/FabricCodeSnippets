# 🔄 Microsoft Fabric Capacity Auto-Suspend Based on Activity ⚡️

This PowerShell runbook automatically **suspends your Microsoft Fabric capacity** when no significant activity is detected within a configurable time window.  
It uses **Azure Automation Runbook**, **Managed Identity**, and the **Fabric Capacity Metrics App** semantic model to decide whether the capacity should remain active or be paused.

---

## 🔑 Key Features

- 💤 **Auto-suspend:** Automatically pauses the capacity when compute activity falls below threshold.
- 📈 **Metrics-driven:** Uses the official *Fabric Capacity Metrics App* semantic model for real-time usage checks.
- 🧠 **Smart decision logic:** Keeps capacity running when recent activity is detected; suspends otherwise.
- 🎯 **Noise filtering:** Configurable threshold to ignore minimal background activity.
- 🕐 **Timezone-aware:** Separate configuration for user display timezone and data timestamp correction.
- ⚡ **Early exit optimization:** Skips checks if capacity is already suspended.
- 🔐 **Credential-free:** Uses Managed Identity for authentication — no secrets required.
- ☁️ **Serverless automation:** Designed for Azure Automation Runbooks, with minimal maintenance.

---

## ⚙️ How It Works

1. **Early State Check:** First checks if the capacity is already suspended/paused via ARM API — if so, exits immediately.
2. **Time Window Calculation:** Determines the lookback window based on current time and timezone settings.
3. **Usage Query:** Queries the **Power BI ExecuteQueries REST API** against the *Capacity Metrics* dataset's "Usage Summary (Last 24 hours)" table.
4. **Activity Analysis:** A DAX query retrieves CU consumption data, applies timezone correction, and sums all CU seconds within the evaluation window.
5. **Decision Logic:** 
   - If total CU seconds **exceeds** the threshold → capacity remains **active** (script exits).
   - If total CU seconds **is below** the threshold → capacity is **suspended** via ARM API.
6. All actions and results are logged with clear status indicators.

---

## ✅ Prerequisites

Before using this runbook, make sure you have:

- **Microsoft Fabric Capacity Metrics App** installed in your tenant
- An **Azure Automation Account** with:
  - PowerShell 7.2 runtime
  - System-Assigned or User-Assigned Managed Identity  
  - `Az.Accounts` module imported
- Managed Identity permissions:
  - `Contributor` role on the Fabric capacity (for suspend operations)
  - `Viewer` permission (minimum) on the *Fabric Capacity Metrics* workspace and dataset  
- Fabric tenant settings:
  - *Service principals can use Fabric APIs* enabled
  - *Service principals can access read-only admin APIs* enabled (if using admin APIs)

---

## 🚀 Setup and Usage

1. **Deploy as a Runbook**
   - In your Azure Automation Account, go to **Runbooks → Create a Runbook**.
   - Name it e.g. `Auto-Suspend-Fabric-By-Activity`.
   - Select **PowerShell** and runtime **7.2**.
   - Paste the script code, then **Save** and **Publish** it.

2. **Configure Parameters**
   - Set up your capacity and workspace IDs
   - Adjust timezone shifts to match your environment
   - Configure idle threshold and noise filter based on your usage patterns

3. **Schedule the Runbook**
   - Run the job periodically (e.g. every 15–30 minutes recommended).
   - It will automatically detect activity and suspend capacity if idle.

4. **Monitor Logs**
   - Each run logs:
     - `[STOPPED]` when capacity is already suspended (early exit).
     - `[ACTIVE]` when capacity has compute activity above threshold.  
     - `[IDLE]` when activity is below threshold and suspension is triggered.  
     - `[ERROR]` when query or suspension fails.

---

## 🎛️ Parameters

| Name | Type | Required | Default | Description |
|------|------|-----------|----------|-------------|
| `SubscriptionId` | string | ✅ | – | Azure subscription ID hosting the capacity |
| `ResourceGroupName` | string | ✅ | – | Resource group containing the capacity |
| `CapacityName` | string | ✅ | – | Fabric capacity resource name (ARM resource) |
| `CapacityId` | string | ✅ | – | Fabric capacity ID (GUID format, used in DAX filter) |
| `WorkspaceId` | string | ✅ | – | Workspace ID containing the *Capacity Metrics* semantic model |
| `DatasetId` | string | ✅ | – | Dataset/Semantic model ID of the *Capacity Metrics* app |
| `UserTimezoneShiftHours` | int | ❌ | `0` | User display timezone offset from UTC in hours (e.g. `2` for UTC+2) |
| `DataTimestampShiftHours` | int | ❌ | `-5` | Data timestamp correction offset in hours (aligns data timestamps with your timezone) |
| `IdleThresholdHours` | int | ❌ | `1` | Lookback window in hours to check for activity |
| `MinimumCUThresholdSeconds` | int | ❌ | `100` | Noise threshold: minimum sum of CU seconds to consider capacity "active" |

### Parameter Notes:
- **UserTimezoneShiftHours:** Only affects display/logging output, doesn't change evaluation logic.
- **DataTimestampShiftHours:** Applied in the DAX query to correct data timestamps (usually negative value to shift back).
- **IdleThresholdHours:** Defines how far back to look for activity (e.g., `1` = last 1 hour).
- **MinimumCUThresholdSeconds:** Helps filter out minimal background operations; capacity only stays active if total CU consumption exceeds this value.

---

## 🧮 Logic Summary

The script runs a DAX query similar to:
```DAX
DEFINE
    VAR _CapacityID = "<YourCapacityID>"

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
        "CU_Consumption_Start", 'Usage Summary (Last 24 hours)'[Timestamp] - TIME(ShiftHours, 0, 0),
        "CU_Seconds", [CU_Seconds]
    )
ORDER BY [CU_Consumption_Start] DESC
```

**Decision Flow:**
1. If capacity already suspended → Exit with `[STOPPED]`
2. Query usage data and apply timezone correction
3. Sum all CU seconds within the evaluation window
4. If `TotalCUs > MinimumCUThresholdSeconds` → Exit with `[ACTIVE]`
5. If `TotalCUs ≤ MinimumCUThresholdSeconds` → Suspend with `[IDLE]`

---

## ⚠️ Error Handling and Logging

- **Clear status indicators:** `[STOPPED]`, `[ACTIVE]`, `[IDLE]`, or `[ERROR]` prefix on key messages.
- **Detailed output:** Shows timezone configuration, time references, evaluation window, and row-by-row CU consumption.
- **Early exit optimization:** Checks capacity state before querying metrics (saves API calls).
- **Graceful error handling:** 
  - If metrics query fails → logs error and exits (no blind suspension).
  - If ARM suspend fails → logs full error message and throws exception.
- **Runbook failure visibility:** Throws on errors to mark Azure Automation job as **Failed**.

---

## 📌 Example Log Output
```
TIMEZONE CONFIGURATION:
  User Timezone Shift:   2 hours
  Data Timestamp Shift:  -5 hours
------------------------------------------------------------
TIME REFERENCE:
  Azure Runbook UTC:     2025-01-13 14:30:00 UTC
  User Local Time:       2025-01-13 16:30:00 (UTC+2)
  Current Full Hour:     2025-01-13 16:00:00
------------------------------------------------------------
EVALUATION:
  Idle Window:           Last 1 hour(s) ( > 2025-01-13 15:00:00 )
  Noise Threshold:       100 CU(s)

Querying Usage Summary (Last 24 hours)...
Timestamp (Shifted)       | CU Seconds   | In Window?
-------------------------|--------------|----------
2025-01-13 16:00:00      |       245.50 | <-- CHECK
2025-01-13 15:00:00      |        89.20 | <-- CHECK
2025-01-13 14:00:00      |         0.00 | 

  Total CUs in Window:   334.7
[ACTIVE]  SumCUs: 334.7 | Threshold: 100 | Capacity: fabric-prod → STILL RUNNING
```

**When idle:**
```
  Total CUs in Window:   45.2
[IDLE]    SumCUs: 45.2 | Threshold: 100 | Capacity: fabric-prod → SUSPENDING...
```

**When already stopped:**
```
[STOPPED]    Capacity: fabric-prod → already SUSPENDED (state: Suspended).
```

---

## 🎯 Best Practices

- **Start conservative:** Use a larger `IdleThresholdHours` (e.g., 2-3 hours) and higher `MinimumCUThresholdSeconds` initially.
- **Tune the noise threshold:** Monitor typical background CU consumption and set threshold slightly above it.
- **Schedule frequency:** Run every 15-30 minutes for balance between responsiveness and API call overhead.
- **Test thoroughly:** Validate timezone settings and thresholds in a dev/test environment first.
- **Monitor costs:** Track whether auto-suspend is reducing costs vs. increased resume overhead.

---

## 🔧 Troubleshooting

**Issue:** Capacity suspends too aggressively  
**Solution:** Increase `MinimumCUThresholdSeconds` or `IdleThresholdHours`

**Issue:** Timestamps seem off  
**Solution:** Adjust `DataTimestampShiftHours` to match your region's offset

**Issue:** "Query failed" errors  
**Solution:** Verify Managed Identity has proper workspace/dataset permissions

**Issue:** "SUSPEND FAILED" errors  
**Solution:** Confirm Managed Identity has `Contributor` role on the capacity

---

## 📝 License

This script is provided as-is for community use. Test thoroughly in non-production environments before deployment.

---

## 🤝 Contributing

Feel free to submit issues or pull requests to improve this automation script!
