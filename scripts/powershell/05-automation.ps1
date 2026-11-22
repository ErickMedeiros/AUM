# 05-automation.ps1 · v1.1 · Automation Account, identidade, papéis mínimos, variáveis, runbooks 7.4, webhooks e Event Grid
# Validado em laboratório em 22/11/2026. Mudanças em relação à v1.0:
#   - papel customizado no formato Permissions[] (Az.Resources >= 10) e com start/deallocate/tags-write (PatchStartStop)
#   - atribuição de papel por ID (o nome do papel recém-criado não é resolvido de imediato)
#   - runtime environment PowerShell-7.4 criado e runbooks publicados nele via REST (Import-AzAutomationRunbook só cria 7.2)
#   - idempotente: pode ser executado de novo
# Pré-requisitos: Az PowerShell + Azure CLI logados na assinatura; Owner ou User Access Administrator para o RBAC.
param(
    [Parameter(Mandatory)][string]$Sub,
    [string]$RG  = 'rg-aum-patching',
    [string]$Loc = 'brazilsouth',
    [string]$AA  = 'aa-aum-patching',
    [string]$KeyVault                # opcional: grava as URIs dos webhooks como segredos
)
Set-AzContext -Subscription $Sub | Out-Null
az account set --subscription $Sub
$ErrorActionPreference = 'Stop'

if (-not (Get-AzAutomationAccount -ResourceGroupName $RG -Name $AA -ErrorAction SilentlyContinue)) {
    New-AzAutomationAccount -ResourceGroupName $RG -Name $AA -Location $Loc -AssignSystemIdentity | Out-Null
}
$aaObj = Get-AzAutomationAccount -ResourceGroupName $RG -Name $AA
$mi = $aaObj.Identity.PrincipalId
$aaId = "/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.Automation/automationAccounts/$AA"
Write-Output "Automation Account: $AA · identidade $mi"

# Papel customizado mínimo: snapshot, cancelamento, ligar/desalocar VM marcada e marcar tag. Sem nenhuma ação de delete.
if (-not (Get-AzRoleDefinition -Name 'AUM Pre-Patch Operator' -ErrorAction SilentlyContinue)) {
    $role = @{
      Name = 'AUM Pre-Patch Operator'; IsCustom = $true
      Description = 'Pré-evento do Azure Update Manager: snapshot e cancelamento. Não exclui recursos.'
      # Az.Resources >= 10: formato com array Permissions (o formato "achatado" da documentação é rejeitado)
      Permissions = @(@{ Actions = @(
        'Microsoft.Compute/virtualMachines/read', 'Microsoft.Compute/disks/read',
        'Microsoft.Compute/snapshots/read', 'Microsoft.Compute/snapshots/write',
        'Microsoft.Maintenance/maintenanceConfigurations/read',
        'Microsoft.Maintenance/applyUpdates/read', 'Microsoft.Maintenance/applyUpdates/write',
        'Microsoft.Resources/subscriptions/resourceGroups/read',
        'Microsoft.Compute/virtualMachines/start/action', 'Microsoft.Compute/virtualMachines/deallocate/action',   # PatchStartStop
        'Microsoft.Resources/tags/write'                                                                           # tag AUM-StartedBy
      ); NotActions = @(); DataActions = @(); NotDataActions = @() })
      AssignableScopes = @("/subscriptions/$Sub")
    }
    $role | ConvertTo-Json -Depth 5 | Out-File "$env:TEMP\aum-role.json"
    New-AzRoleDefinition -InputFile "$env:TEMP\aum-role.json" | Out-Null
}
# Replicação do papel customizado pode levar minutos: aguarda até 5 min antes de atribuir
$t0 = Get-Date
while (-not (Get-AzRoleDefinition -Name 'AUM Pre-Patch Operator' -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) -and ((Get-Date) - $t0).TotalMinutes -lt 5) { Start-Sleep -Seconds 15 }
foreach ($r in @(
    @{ n = 'Reader'; s = "/subscriptions/$Sub" },
    @{ n = 'Backup Operator'; s = "/subscriptions/$Sub" },
    @{ n = 'AUM Pre-Patch Operator'; s = "/subscriptions/$Sub" },
    @{ n = 'Automation Job Operator'; s = $aaId })) {
    # Atribui pelo ID: com papel customizado recém-criado, a busca pelo nome no New-AzRoleAssignment falha
    $rid = az role definition list --name "$($r.n)" --scope "/subscriptions/$Sub" --query "[0].name" -o tsv
    if (-not $rid) { $rid = az role definition list --custom-role-only true --scope "/subscriptions/$Sub" --query "[?roleName=='$($r.n)'].name | [0]" -o tsv }
    if (-not (az role assignment list --assignee $mi --role $rid --scope $r.s --query "[0].id" -o tsv)) {
        New-AzRoleAssignment -ObjectId $mi -ObjectType ServicePrincipal -RoleDefinitionId $rid -Scope $r.s | Out-Null
        Write-Output "RBAC: $($r.n) em $($r.s)"
    }
}

# Variáveis lidas pelo Runbook (revisar antes de cada ciclo: POP, seção 5)
$vars = [ordered]@{
  'AUM-Feriados'           = '["2027-01-01","2027-02-08","2027-02-09","2027-02-10","2027-03-26","2027-04-21","2027-05-01","2027-05-27","2027-09-07","2027-10-12","2027-10-28","2027-11-02","2027-11-15","2027-11-20","2027-12-25"]'
  'AUM-FailClosed'         = $true
  'AUM-RetencaoBackupDias' = 30
  'AUM-HoldWaves'          = '[]'
  'AUM-LigarDesalocadas'   = $false            # decisão do CAB
  'AUM-HybridWorkerGroup'  = 'hwg-vsphere'
  'AUM-AutomationAccount'  = $AA
  'AUM-AutomationRG'       = $RG
  'AUM-vCenter'            = '<fqdn-do-vcenter>'
}
foreach ($k in $vars.Keys) {
    if (Get-AzAutomationVariable -ResourceGroupName $RG -AutomationAccountName $AA -Name $k -ErrorAction SilentlyContinue) {
        Set-AzAutomationVariable -ResourceGroupName $RG -AutomationAccountName $AA -Name $k -Encrypted $false -Value $vars[$k] | Out-Null
    } else {
        New-AzAutomationVariable -ResourceGroupName $RG -AutomationAccountName $AA -Name $k -Encrypted $false -Value $vars[$k] | Out-Null
    }
}
Write-Output "Variáveis: $($vars.Keys -join ', ')"

# Runbooks PowerShell 7.4 (runtime environment) via REST
$api = '2023-05-15-preview'
$rte = @{ location = $Loc; properties = @{ runtime = @{ language = 'PowerShell'; version = '7.4' }; defaultPackages = @{ Az = '12.3.0' } } } | ConvertTo-Json -Depth 5
$r0 = Invoke-AzRestMethod -Method PUT -Path "$aaId/runtimeEnvironments/PowerShell-7.4?api-version=$api" -Payload $rte
Write-Output "Runtime environment PowerShell-7.4: HTTP $($r0.StatusCode)"
foreach ($rb in @(@{ n = 'AUM-PreEvent'; f = '06-runbook-pre.ps1' }, @{ n = 'AUM-PostEvent'; f = '07-runbook-post.ps1' })) {
    $body = @{ location = $Loc; properties = @{ runbookType = 'PowerShell'; runtimeEnvironment = 'PowerShell-7.4'; logProgress = $false; logVerbose = $false } } | ConvertTo-Json -Depth 5
    $r1 = Invoke-AzRestMethod -Method PUT -Path "$aaId/runbooks/$($rb.n)?api-version=$api" -Payload $body
    $r2 = Invoke-AzRestMethod -Method PUT -Path "$aaId/runbooks/$($rb.n)/draft/content?api-version=$api" -Payload (Get-Content "$PSScriptRoot\..\runbooks\$($rb.f)" -Raw)
    $r3 = Invoke-AzRestMethod -Method POST -Path "$aaId/runbooks/$($rb.n)/publish?api-version=$api"
    Write-Output "Runbook $($rb.n): create $($r1.StatusCode) · content $($r2.StatusCode) · publish $($r3.StatusCode)"
    if ($r1.StatusCode -ge 300) { Write-Output $r1.Content }
}
Start-Sleep -Seconds 15

# Webhooks (a URI só pode ser lida na criação)
# As URIs só podem ser lidas na criação. Guardar no Key Vault (-KeyVault) e anotar a validade (1 ano) no POP.
if (Get-AzAutomationWebhook -ResourceGroupName $RG -AutomationAccountName $AA -Name 'wh-aum-pre' -ErrorAction SilentlyContinue) {
    throw 'Webhooks já existem. Para recriar (renovação), siga o POP: novo webhook + atualizar as assinaturas do Event Grid.'
}
$whPre  = New-AzAutomationWebhook -ResourceGroupName $RG -AutomationAccountName $AA -RunbookName 'AUM-PreEvent'  -Name 'wh-aum-pre'  -IsEnabled $true -ExpiryTime (Get-Date).AddYears(1) -Force
$whPost = New-AzAutomationWebhook -ResourceGroupName $RG -AutomationAccountName $AA -RunbookName 'AUM-PostEvent' -Name 'wh-aum-post' -IsEnabled $true -ExpiryTime (Get-Date).AddYears(1) -Force
if ($KeyVault) {
    Set-AzKeyVaultSecret -VaultName $KeyVault -Name 'aum-webhook-pre'  -SecretValue (ConvertTo-SecureString $whPre.WebhookURI  -AsPlainText -Force) -Expires $whPre.ExpiryTime.UtcDateTime | Out-Null
    Set-AzKeyVaultSecret -VaultName $KeyVault -Name 'aum-webhook-post' -SecretValue (ConvertTo-SecureString $whPost.WebhookURI -AsPlainText -Force) -Expires $whPost.ExpiryTime.UtcDateTime | Out-Null
    Write-Output "URIs dos webhooks gravadas no Key Vault $KeyVault"
} else { Write-Warning 'Sem -KeyVault: as URIs dos webhooks não foram guardadas e não poderão ser lidas de novo.' }
$wh = [pscustomobject]@{ pre = $whPre.WebhookURI; post = $whPost.WebhookURI }

# Event Grid: um system topic por Maintenance Configuration, com assinaturas Pre e Post
foreach ($mcName in 'mc-aum-wave1-dev','mc-aum-wave2-hml-piloto','mc-aum-wave3-hml') {
  $mcId = (Get-AzResource -ResourceGroupName $RG -Name $mcName -ResourceType 'Microsoft.Maintenance/maintenanceConfigurations').ResourceId
  az eventgrid system-topic create -g $RG -n "evgt-$mcName" --location $Loc --topic-type Microsoft.Maintenance.MaintenanceConfigurations --source $mcId -o none
  az eventgrid system-topic event-subscription create -g $RG --system-topic-name "evgt-$mcName" -n "pre-$mcName" `
     --endpoint-type webhook --endpoint $wh.pre --included-event-types Microsoft.Maintenance.PreMaintenanceEvent -o none
  az eventgrid system-topic event-subscription create -g $RG --system-topic-name "evgt-$mcName" -n "post-$mcName" `
     --endpoint-type webhook --endpoint $wh.post --included-event-types Microsoft.Maintenance.PostMaintenanceEvent -o none
  Write-Output "Event Grid: evgt-$mcName (pre/post) -> " + (az eventgrid system-topic event-subscription list -g $RG --system-topic-name "evgt-$mcName" --query "[].provisioningState" -o tsv)
}

