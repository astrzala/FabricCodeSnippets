# 🔄 Microsoft Fabric Capacity Auto-Suspend Based on Activity ⚡️

This PowerShell runbook automatically **suspends your Microsoft Fabric capacity** when no activity is detected within a configurable time window.  
It uses **Azure Automation Runbook**, **Managed Identity**, and the **Fabric Capacity Metrics App** semantic model to decide whether the capacity should remain active or be paused.

---

## 🔑 Key Features

- 💤 **Auto-suspend:** Automatically pauses the capacity when no compute activity (`SumCUs`) is detected.
- 📈 **Metrics-driven:** Uses the official *Fabric Capacity Metrics App* semantic model for real-time usage checks.
- 🧠 **Smart decision logic:** Keeps capacity running when recent activity is detected; suspends otherwise.
- 🔐 **Credential-free:** Uses Managed Identity for authentication — no secrets required.
- ☁️ **Serverless automation:** Designed for Azure Automation Runbooks, with minimal maintenance.

---

## ⚙️ How It Works

1. The script queries the **Power BI ExecuteQueries REST API** against the *Capacity Metrics* dataset.
2. A DAX query calculates the **Sum of Compute Units (CU)** consumed by the target capacity during a recent time window (e.g. last 5 minutes).
3. If any CU usage is detected (`SumCUs > 0`), the script logs that the capacity is still active and exits.
4. If no usage is detected, it calls the **Azure Resource Manager (ARM)** API to suspend the capacity.
5. All actions and results are logged for observability.

---

## ✅ Prerequisites

Before using this runbook, make sure you have:

- **Microosft Fabric Capacity Metrics App** installed  
- An **Azure Automation Account** with:
  - PowerShell 7.2 runtime
  - System-Assigned or User-Assigned Managed Identity  
- Managed Identity permissions:
  - `Contributor` role on the Fabric capacity
  - `Viewer` (and optionally `Build`) permission on the *Fabric Capacity Metrics* workspace and dataset  
- Fabric tenant settings:
  - *Service principals can call Fabric public APIs* 

---

## 🚀 Setup and Usage

1. **Deploy as a Runbook**
   - In your Azure Automation Account, go to **Runbooks → Create a Runbook**.
   - Name it e.g. `Auto-Suspend-Fabric-By-Activity`.
   - Select **PowerShell** and runtime **7.2**.
   - Paste the script code, then **Save** and **Publish** it.

2. **Schedule the Runbook**
   - Run the job periodically (e.g. every 5–15 minutes).
   - It will automatically detect activity and suspend capacity if idle.

3. **Monitor Logs**
   - Each run logs:
     - `[STOPPED]` when capacity is already suspended.
     - `[ACTIVE]` when capacity still has compute activity.  
     - `[IDLE]` when no compute activity and suspension triggered.  
     - `[ERROR]` when suspension fails.

---

## 🎛️ Parameters

| Name | Type | Required | Default | Description |
|------|------|-----------|----------|-------------|
| `SubscriptionId` | string | ✅ | – | Azure subscription hosting the capacity |
| `ResourceGroupName` | string | ✅ | – | Resource group containing the capacity |
| `CapacityName` | string | ✅ | – | Fabric capacity resource name |
| `CapacityId` | string | ✅ | – | Fabric capacity ID used in the DAX filter |
| `WorkspaceId` | string | ✅ | – | Workspace ID of the *Capacity Metrics* semantic model |
| `DatasetId` | string | ✅ | – | Dataset ID of the *Capacity Metrics* semantic model |
| `UTCshiftMinutes` | int | ❌ | `120` | Timezone offset from UTC (e.g. `120` for UTC+2) |
| `WindowMinutes` | int | ❌ | `5` | Time window (in minutes) used to check for recent activity |

---

## 🧮 Logic Summary

The script runs a DAX query similar to:

```DAX
EVALUATE
ROW(
  "SumCUs", SUM('CU Detail'[CU (s)]),
  "HasActivity", IF(SUM('CU Detail'[CU (s)]) > 0, 1, 0),
  "CurrentTime", UTCNOW()
)
```

If `SumCUs > 0` → capacity remains **active**.  
If `SumCUs = 0` → capacity is **suspended** via ARM API.

---

## ⚠️ Error Handling and Logging

- Logs clearly indicate activity status: `[STOPPED]`,`[ACTIVE]`, `[IDLE]`, or `[ERROR]`.
- If the ARM suspend call fails, the full error message is printed.
- The job throws on failure, marking the Automation Runbook as **Failed** for visibility.
- Safe defaults:
  - A small time window (default `5 min`) ensures quick detection of inactivity.
  - No operation is performed if the Metrics query fails (no blind suspension).

---

## 📌 Example Log Output

```
[ACTIVE]  SumCUs: 320 | Window: 5 min | Capacity: fabric-dev → STILL RUNNING
[IDLE]    SumCUs: 0   | Window: 5 min | Capacity: fabric-dev → SUSPENDING...
[ERROR]   SumCUs: 0   | Window: 5 min | Capacity: fabric-dev → SUSPEND FAILED: <error>
```

---

*This script is provided as-is. Test thoroughly in a non-production environment before deployment.*

