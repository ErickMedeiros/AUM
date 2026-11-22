<#
.SYNOPSIS  AUM-PostEvent · resumo da execução, reboot pendente e desligamento das VMs ligadas pelo pré-evento.
.NOTES     PowerShell 7.4 · identidade gerenciada · não exclui recursos nem reinicia máquinas.
           v1.1 (validado em lab 22/11/2026): Search-AzGraph com .Data; limpa a tag AUM-StartedBy;
           também é acionado em execução Cancelled (desliga o que o pré-evento ligou).
#>
param([object]$WebhookData)
$ErrorActionPreference = 'Stop'
$evento = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)[0]
if ($evento.eventType -ne 'Microsoft.Maintenance.PostMaintenanceEvent') { return }
Connect-AzAccount -Identity | Out-Null
$runId = $evento.data.CorrelationId; $runTag = ($runId -split '/')[-1]
Write-Output "Execução $runTag terminou com status $($evento.data.Status)"

# Reboot pendente nas máquinas da execução
$pend = @((Search-AzGraph -First 1000 -Query @"
maintenanceresources
| where type =~ 'microsoft.maintenance/applyupdates' and properties.correlationId =~ '$runId'
| project vmId = tolower(tostring(properties.resourceId))
| join kind=inner (patchassessmentresources
    | where type !has 'softwarepatches' and tobool(properties.rebootPending)
    | project vmId = tostring(split(tolower(id), '/patchassessmentresults/')[0])) on vmId
| project vmId
"@).Data)
Write-Output "Máquinas com reboot pendente: $($pend.Count)"
$pend | ForEach-Object { Write-Output "  - $($_.vmId)" }

# Desliga (deallocate) só as VMs que o pré-evento ligou nesta execução
$ligadas = @((Search-AzGraph -First 1000 -Query "resources | where type =~ 'microsoft.compute/virtualmachines' and tags['AUM-StartedBy'] == '$runTag' | project id, resourceGroup, name").Data)
foreach ($v in $ligadas) {
    Stop-AzVM -ResourceGroupName $v.resourceGroup -Name $v.name -Force -NoWait | Out-Null
    Update-AzTag -ResourceId $v.id -Tag @{ 'AUM-StartedBy' = '' } -Operation Merge | Out-Null   # limpa o marcador (não remove outras tags)
    Write-Output "Desalocada de volta: $($v.name)"
}
# O resumo para e-mail e Teams é enviado pela Logic App que lê a saída deste job (ou por alerta do Azure Monitor).

