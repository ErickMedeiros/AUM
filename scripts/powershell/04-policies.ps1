# 04-policies.ps1 · v1.1 · pré-requisitos via Azure Policy (substitui o 04-policies.sh; não depende de jq/bash)
# Validado em laboratório em 22/11/2026. Mudanças em relação à v1.0:
#   - Periodic Assessment: UMA atribuição por SO e por plataforma (o parâmetro osType da built-in tem padrão Windows)
#   - CMS restrito às máquinas em Wave (tagValues = PatchWave Wave1/2/3, operador Any)
#   - remediações em SEQUÊNCIA (CMS -> PA): em paralelo, os dois PUT na mesma VM dão Conflict ou perdem a escrita
#   - az policy remediation create não aceita --scope (usar a assinatura padrão)
param(
    [Parameter(Mandatory)][string]$Sub,
    [string]$Loc = 'brazilsouth',
    [switch]$Remediar
)
$ErrorActionPreference = 'Stop'
az account set --subscription $Sub
$Scope = "/subscriptions/$Sub"
$tmp = Join-Path $env:TEMP 'aum-policy'; New-Item -ItemType Directory -Force $tmp | Out-Null

# 1) Customer Managed Schedules (built-in DeployIfNotExists) só nas máquinas em Wave
@{ tagOperator = @{ value = 'Any' }; tagValues = @{ value = @(
    @{ key = 'PatchWave'; value = 'Wave1-Dev' }, @{ key = 'PatchWave'; value = 'Wave2-HML-Piloto' }, @{ key = 'PatchWave'; value = 'Wave3-HML' }) } } |
  ConvertTo-Json -Depth 6 | Set-Content "$tmp\cms.json"
az policy assignment create --name aum-cms-prereq --display-name 'AUM - Customer Managed Schedules' --scope $Scope `
  --policy 9905ca54-1471-49c6-8291-7582c04cd4d4 --params "@$tmp\cms.json" `
  --mi-system-assigned --location $Loc --role 'Virtual Machine Contributor' --identity-scope $Scope -o none

# 2) Periodic Assessment: uma atribuição por SO, para Azure VMs e para servidores Arc
$pa = @(
  @{ n = 'aum-pa-vm-win';  p = '59efceea-0c96-497e-a4a1-4eb2290dac15'; os = 'Windows'; role = 'Virtual Machine Contributor' },
  @{ n = 'aum-pa-vm-lnx';  p = '59efceea-0c96-497e-a4a1-4eb2290dac15'; os = 'Linux';   role = 'Virtual Machine Contributor' },
  @{ n = 'aum-pa-arc-win'; p = 'bfea026e-043f-4ff4-9d1b-bf301ca7ff46'; os = 'Windows'; role = 'Azure Connected Machine Resource Administrator' },
  @{ n = 'aum-pa-arc-lnx'; p = 'bfea026e-043f-4ff4-9d1b-bf301ca7ff46'; os = 'Linux';   role = 'Azure Connected Machine Resource Administrator' })
foreach ($a in $pa) {
  @{ osType = @{ value = $a.os } } | ConvertTo-Json | Set-Content "$tmp\$($a.n).json"
  az policy assignment create --name $a.n --display-name "AUM - Periodic Assessment $($a.n)" --scope $Scope `
    --policy $a.p --params "@$tmp\$($a.n).json" --mi-system-assigned --location $Loc --role $a.role --identity-scope $Scope -o none
}

# 3) Auditoria das tags (definição customizada em 13-policy-tags-auditoria.json)
$def = Get-Content (Join-Path $PSScriptRoot '..\policy\13-policy-tags-auditoria.json') -Raw | ConvertFrom-Json
$def.properties.policyRule | ConvertTo-Json -Depth 20 | Set-Content "$tmp\aum-tags-rule.json"
az policy definition create --name aum-tags-audit --display-name 'AUM - Auditar tags Ambiente e PatchWave' `
  --mode Indexed --rules "@$tmp\aum-tags-rule.json" --subscription $Sub -o none
az policy assignment create --name aum-tags-audit --display-name 'AUM - Auditar tags Ambiente e PatchWave' --scope $Scope --policy aum-tags-audit -o none

az policy assignment list --scope $Scope --query "[?starts_with(name,'aum-')].{Nome:name, Identidade:identity.principalId}" -o table
if (-not $Remediar) { Write-Output 'Atribuições criadas. Rode de novo com -Remediar depois da avaliação de conformidade (az policy state trigger-scan, 5-15 min).'; return }

# 4) Remediação em sequência: CMS primeiro; PA só depois que o CMS terminar
function Wait-Remediation([string]$Nome) {
  do { Start-Sleep 30; $s = az policy remediation show -n $Nome --query provisioningState -o tsv } while ($s -notin 'Succeeded', 'Failed', 'Canceled')
  Write-Output "$Nome -> $s · $(az policy remediation show -n $Nome --query 'deploymentStatus' -o json | ConvertFrom-Json | ConvertTo-Json -Compress)"
}
$sufixo = Get-Date -Format 'yyyyMMddHHmm'
az policy remediation create --name "rem-aum-cms-$sufixo" --policy-assignment aum-cms-prereq --resource-discovery-mode ReEvaluateCompliance -o none
Wait-Remediation "rem-aum-cms-$sufixo"
foreach ($a in $pa) {
  az policy remediation create --name "rem-$($a.n)-$sufixo" --policy-assignment $a.n --resource-discovery-mode ReEvaluateCompliance -o none
  Wait-Remediation "rem-$($a.n)-$sufixo"
}
Write-Output 'Conferir com a Q6: patchMode = AutomaticByPlatform, bypass = true e assessmentMode = AutomaticByPlatform em todas as máquinas em Wave.'

