# 23-lab-publicar.ps1 · republica AUM-PreEvent e AUM-PostEvent (runtime PowerShell-7.4)
. "$PSScriptRoot\00-lab-config.ps1"
$aaId = "/subscriptions/$($Lab.Sub)/resourceGroups/$($Lab.RG)/providers/Microsoft.Automation/automationAccounts/$($Lab.AA)"
foreach ($rb in @(@{ n = 'AUM-PreEvent'; p = 'runbooks\06-runbook-pre-lab.ps1' }, @{ n = 'AUM-PostEvent'; p = '..\scripts\runbooks\07-runbook-post.ps1' })) {
    $r2 = Invoke-AzRestMethod -Method PUT -Path "$aaId/runbooks/$($rb.n)/draft/content?api-version=2023-05-15-preview" -Payload (Get-Content "$PSScriptRoot\$($rb.p)" -Raw)
    $r3 = Invoke-AzRestMethod -Method POST -Path "$aaId/runbooks/$($rb.n)/publish?api-version=2023-05-15-preview"
    Write-Output "$($rb.n): content $($r2.StatusCode) · publish $($r3.StatusCode)"
}

