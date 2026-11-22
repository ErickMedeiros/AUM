<#
.SYNOPSIS  AUM-Snapshot-vSphere · roda no Hybrid Runbook Worker com acesso ao vCenter (VMware PowerCLI instalado).
.NOTES     Cria snapshot sem memória, com quiesce. Não remove snapshots: a remoção é manual, pelo dono, após a estabilização
           (boa prática VMware: não manter snapshot por mais de 72 horas).
#>
param([Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][string]$RunTag)
$ErrorActionPreference = 'Stop'
$cred    = Get-AutomationPSCredential -Name 'vCenter-AUM'          # conta de serviço com permissão de snapshot apenas
$vcenter = Get-AutomationVariable -Name 'AUM-vCenter'
Connect-VIServer -Server $vcenter -Credential $cred | Out-Null
try {
    $vm   = Get-VM -Name $VmName
    $nome = "AUM-$RunTag"
    if (Get-Snapshot -VM $vm -Name $nome -ErrorAction SilentlyContinue) { Write-Output "Snapshot já existe: $nome"; return }
    New-Snapshot -VM $vm -Name $nome -Description "Pré-patch Azure Update Manager · execução $RunTag" -Memory:$false -Quiesce:$true | Out-Null
    Write-Output "Snapshot criado no vCenter: $VmName / $nome"
} finally { Disconnect-VIServer -Server $vcenter -Confirm:$false }

