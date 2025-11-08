# 🤖 Automate Pausing and Resuming Microsoft Fabric Capacity ⚡️

This PowerShell script is designed to be used as an **Azure Automation Runbook** to programmatically pause or resume a Microsoft Fabric capacity.  
By automating this process, you can effectively manage costs by ensuring capacity is only active when needed — for instance, during business hours.

The script leverages a **Managed Identity** for secure, credential-free authentication to your Azure resources.

---

## 🔑 Key Features

- **Pause & Resume:** Start or stop your Fabric capacity on a schedule.  
- **Flexible Inputs:** Accepts short synonyms for operations (e.g. `stop`, `pause`, `start`, `run`, `0`, `1`).  
- **Cost-Effective:** Reduces Azure costs by keeping Fabric capacity active only when required.  
- **Secure Authentication:** Uses Azure Managed Identity — no credentials stored in the code.  
- **Automation-Ready:** Drop directly into an Azure Automation PowerShell Runbook.

---

## ⚙️ How It Works

The script performs the following actions:

1. Accepts four mandatory parameters:  
   - `SubscriptionId`  
   - `ResourceGroupName`  
   - `CapacityName`  
   - `Operation` (`suspend` or `resume`, with flexible aliases)  
2. Normalizes user input (e.g. `stop`, `pause`, or `0` → `suspend`).  
3. Connects to Azure using the Automation Account’s Managed Identity.  
4. Retrieves an authentication token for the **Azure Resource Manager (ARM)** API.  
5. Builds the proper REST API endpoint for your capacity and desired action.  
6. Sends a POST request to either suspend or resume the Fabric capacity.  
7. Outputs informative log messages about the operation result.

---

## ✅ Prerequisites

Before using this script, ensure you have:

1. An **Azure Automation Account**.  
2. A **System-Assigned Managed Identity** enabled on the Automation Account.  
3. The Managed Identity must have **Contributor** role on the target capacity.  
4. The `Az.Accounts` module available in your Automation Account’s modules.

---

## 🚀 Setup and Usage

Follow these steps to deploy the script as an Azure Automation Runbook:

### 1️⃣ Create a Runbook

- Go to your **Azure Automation Account**.  
- Under **Process Automation**, select **Runbooks → Create a runbook**.  
- Name it (e.g. `Manage-Fabric-Capacity`), choose **PowerShell**, and select a runtime version (e.g. 7.2).

### 2️⃣ Add the Script

- Copy the contents of the `fabric_pause_and_resume.ps1` script and paste it into the Runbook editor.  
- Save and **Publish** the runbook.

### 3️⃣ Schedule It

- You can run the script manually or create two schedules:
  - **Stop-Fabric-Nightly:** to suspend capacity after work hours.
  - **Start-Fabric-Morning:** to resume capacity before work hours.  
- Under the runbook, select **Link to schedule**, choose your schedule, and set parameters.

---

## 🎛️ Parameters

| Parameter | Type | Description |
|------------|------|-------------|
| `SubscriptionId` | String | **(Required)** The Azure subscription ID that contains the Fabric capacity. |
| `ResourceGroupName` | String | **(Required)** The resource group name where the capacity resides. |
| `CapacityName` | String | **(Required)** The name of your Fabric capacity. |
| `Operation` | String | **(Required)** The action to perform. Normalized internally to `suspend` or `resume`. |

### ✔️ Valid Operation Values

| Purpose | Accepted Values |
|----------|----------------|
| Suspend Capacity | `suspend`, `stop`, `pause`, `0` |
| Resume Capacity | `resume`, `start`, `run`, `1` |

---

## ⚠️ Error Handling and Logging

- Includes `try/catch` to handle API or authentication errors gracefully.  
- Displays clear `[IDLE]`, `[RESUME]`, or `[ERROR]` messages for better visibility in Automation logs.  
- On failure, the job exits with an error so that the Automation Runbook is marked as **Failed**.

---

*This script is provided as-is. Test thoroughly in a non-production environment before deployment.*
