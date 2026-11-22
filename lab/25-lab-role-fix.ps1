# 25-lab-role-fix.ps1 · acrescenta ao papel AUM Pre-Patch Operator as ações exigidas pelo PatchStartStop (pré) e pelo desligamento (pós)
# Continua SEM nenhuma ação de delete.
param([string]$Sub = (az account show --query id -o tsv))
$def = az role definition list --custom-role-only true --scope "/subscriptions/$Sub" --query "[?roleName=='AUM Pre-Patch Operator'] | [0]" -o json | ConvertFrom-Json
$novas = 'Microsoft.Compute/virtualMachines/start/action', 'Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Resources/tags/write'
$acoes = @($def.permissions[0].actions) + $novas | Select-Object -Unique
$body = @{ roleName = $def.roleName; name = $def.name; IsCustom = $true; Description = $def.description
           Actions = $acoes; NotActions = @(); DataActions = @(); NotDataActions = @(); AssignableScopes = $def.assignableScopes }
$f = Join-Path $env:TEMP 'aum-role-update.json'; $body | ConvertTo-Json -Depth 5 | Set-Content $f
az role definition update --role-definition "@$f" --query "{papel:roleName, acoes:permissions[0].actions}" -o json

