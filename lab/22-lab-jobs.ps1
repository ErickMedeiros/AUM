# 22-lab-jobs.ps1 · lista os jobs recentes dos runbooks AUM e mostra a saída (Output + Error)
param([int]$Ultimos = 6, [string]$JobId)
. "$PSScriptRoot\00-lab-config.ps1"
$jobs = if ($JobId) { @(Get-AzAutomationJob -ResourceGroupName $Lab.RG -AutomationAccountName $Lab.AA -Id $JobId) }
        else { Get-AzAutomationJob -ResourceGroupName $Lab.RG -AutomationAccountName $Lab.AA | Sort-Object CreationTime -Descending | Select-Object -First $Ultimos }
foreach ($j in $jobs) {
    "===== $($j.RunbookName) · $($j.Status) · criado $($j.CreationTime.ToString('HH:mm:ss')) · job $($j.JobId)"
    Get-AzAutomationJobOutput -ResourceGroupName $Lab.RG -AutomationAccountName $Lab.AA -Id $j.JobId -Stream Any |
        Sort-Object Time | ForEach-Object {
            $txt = $_.Summary
            if ($_.Type -eq 'Error') { $txt = (Get-AzAutomationJobOutputRecord -ResourceGroupName $Lab.RG -AutomationAccountName $Lab.AA -JobId $j.JobId -Id $_.StreamRecordId).Value.Exception; if (-not $txt) { $txt = $_.Summary } }
            "  [$($_.Type)] $txt"
        }
}

