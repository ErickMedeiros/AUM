# 99-lab-limpeza.ps1 · remove TUDO o que o teste AUM criou na assinatura de laboratório (Pago pelo Uso)
# Sem -Executar: só lista. Com -Executar: remove. Com -ManterCofre: preserva rsv-aum-lab e seus pontos de backup.
# Não toca nas VMs nem nos discos; só remove as tags AUM delas e devolve o patch mode ao valor anterior (opcional -RestaurarPatchMode).
param([Parameter(Mandatory)][string]$Sub, [switch]$Executar, [switch]$ManterCofre, [switch]$RestaurarPatchMode)
if ((az account show --query id -o tsv) -ne $Sub) { throw "Contexto do Azure CLI não está na assinatura informada em -Sub $Sub. Abortado." }
$vms = @('RG-AADDS/VM-SRV-AADDS', 'RG-LAB-HYPERV-BR/VM-HyperV-Host', 'RG-IMERSAO-ARQUITETOAZURE/vm-imersao')
$tagsAum = 'Ambiente', 'PatchWave', 'PreBackup', 'SystemOwner', 'Sistema', 'PatchStartStop', 'AUM-StartedBy'
function Invoke-Passo([string]$Desc, [scriptblock]$Acao) { if ($Executar) { Write-Output "REMOVENDO: $Desc"; & $Acao } else { Write-Output "seria removido: $Desc" } }

# 1) Dynamic Scopes (assinatura) e atribuições/definição de política
foreach ($ds in 'ds-wave1-dev', 'ds-wave2-hml-piloto', 'ds-wave3-hml', 'ds-mc-aum-lab-cancel', 'ds-mc-aum-lab-e2e') {
    Invoke-Passo "Dynamic Scope $ds" { az rest --method delete --url "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Maintenance/configurationAssignments/$ds`?api-version=2023-04-01" -o none }
}
$pol = @(@{ n = 'aum-cms-prereq'; s = "/subscriptions/$Sub" }, @{ n = 'aum-tags-audit'; s = "/subscriptions/$Sub" },
         @{ n = 'aum-pa-win-aadds'; s = "/subscriptions/$Sub/resourceGroups/RG-AADDS" }, @{ n = 'aum-pa-win-hyperv'; s = "/subscriptions/$Sub/resourceGroups/RG-LAB-HYPERV-BR" },
         @{ n = 'aum-pa-lnx-imersao'; s = "/subscriptions/$Sub/resourceGroups/RG-IMERSAO-ARQUITETOAZURE" })
foreach ($p in $pol) {
    $pid_ = az policy assignment show -n $p.n --scope $p.s --query identity.principalId -o tsv 2>$null
    if ($pid_) { Invoke-Passo "RBAC da identidade da política $($p.n)" { az role assignment delete --assignee $pid_ -o none } }
    Invoke-Passo "Atribuição de política $($p.n)" { az policy assignment delete -n $p.n --scope $p.s -o none }
}
Invoke-Passo 'Definição de política aum-tags-audit' { az policy definition delete -n aum-tags-audit -o none }

# 2) Papel customizado (depois de remover as atribuições da identidade da Automation)
$mi = az automation account show -g rg-aum-patching -n aa-aum-patching-lab --query identity.principalId -o tsv 2>$null
if ($mi) { Invoke-Passo "RBAC da identidade da Automation ($mi)" { az role assignment delete --assignee $mi -o none } }
Invoke-Passo 'Papel customizado AUM Pre-Patch Operator' { az role definition delete --name 'AUM Pre-Patch Operator' --scope "/subscriptions/$Sub" -o none }

# 3) Snapshots criados pelo pré-evento (tag CreatedBy = AUM-PreEvent)
$snaps = az graph query -q "resources | where type =~ 'microsoft.compute/snapshots' and tags.CreatedBy == 'AUM-PreEvent' | project id, name" --query data -o json | ConvertFrom-Json
foreach ($s in $snaps) { Invoke-Passo "Snapshot $($s.name)" { az snapshot delete --ids $s.id -o none } }

# 4) Cofre: parar proteção e apagar dados de backup (só sem -ManterCofre)
if (-not $ManterCofre) {
    Invoke-Passo 'Proteção da VM-SRV-AADDS e pontos de backup (rsv-aum-lab)' {
        az backup vault backup-properties set -g rg-aum-patching -n rsv-aum-lab --soft-delete-feature-state Disable -o none
        az backup protection disable -g rg-aum-patching -v rsv-aum-lab -c VM-SRV-AADDS -i VM-SRV-AADDS --backup-management-type AzureIaasVM --delete-backup-data true --yes -o none
    }
}

# 5) Tags AUM nas VMs (as demais tags são preservadas) e patch mode
foreach ($v in $vms) {
    $g, $n = $v -split '/'
    $id = az vm show -g $g -n $n --query id -o tsv
    Invoke-Passo "Tags AUM em $n" { az tag update --resource-id $id --operation Delete --tags $tagsAum.ForEach({ "$_=" }) -o none }
    if ($RestaurarPatchMode) {
        $os = az vm show -g $g -n $n --query storageProfile.osDisk.osType -o tsv
        $modo = if ($os -eq 'Windows') { 'AutomaticByOS' } else { 'ImageDefault' }
        Invoke-Passo "Patch mode de $n -> $modo / assessment ImageDefault" { az vm update -g $g -n $n --set "osProfile.$($os.ToLower())Configuration.patchSettings.patchMode=$modo" "osProfile.$($os.ToLower())Configuration.patchSettings.assessmentMode=ImageDefault" -o none }
    }
}

# 6) Grupo de recursos da solução (MCs, Automation, runtime, webhooks, Event Grid e, sem -ManterCofre, o cofre)
if ($ManterCofre) {
    $res = az resource list -g rg-aum-patching --query "[?type!='Microsoft.RecoveryServices/vaults'].{id:id, n:name, t:type}" -o json | ConvertFrom-Json
    foreach ($r in $res | Sort-Object { $_.t -like '*eventSubscriptions*' } -Descending) { Invoke-Passo "$($r.t) $($r.n)" { az resource delete --ids $r.id -o none } }
} else {
    Invoke-Passo 'Grupo de recursos rg-aum-patching (inteiro)' { az group delete -n rg-aum-patching --yes -o none }
}
if (-not $Executar) { Write-Output "`nNada foi removido. Para executar: .\99-lab-limpeza.ps1 -Executar [-ManterCofre] [-RestaurarPatchMode]" }

