# Implantação

Ordem: **tags (Onda 0) → Maintenance Configurations → Dynamic Scopes → políticas → Automation, runbooks e Event Grid → Workbook.** Todos os scripts são idempotentes ou só criam recursos.

## Pré-requisitos

| Item | Versão validada |
|---|---|
| Azure CLI com Bicep | 2.86 (`az bicep install`) |
| Az PowerShell | Az.Accounts 5.5, Az.Resources 10.0, Az.Compute 11.6, Az.Automation 1.12, Az.ResourceGraph 1.3, Az.RecoveryServices 7.12 |
| Runtime da Automation | PowerShell-7.4 com Az 12.3.0 (criado pelo `05-automation.ps1`) |
| Permissão | Owner, ou Contributor + User Access Administrator, na assinatura |
| Providers | `Microsoft.Maintenance`, `Microsoft.EventGrid`, `Microsoft.Automation`, `Microsoft.RecoveryServices`, `Microsoft.PolicyInsights` |

```powershell
foreach ($p in 'Microsoft.Maintenance','Microsoft.EventGrid','Microsoft.Automation','Microsoft.RecoveryServices','Microsoft.PolicyInsights') { az provider register -n $p }
$Sub = '<subscription-id>'
```

Para conectar o Az PowerShell reaproveitando o login do Azure CLI, sem segundo login interativo:

```powershell
$tok = az account get-access-token --query accessToken -o tsv
Connect-AzAccount -AccessToken $tok -AccountId (az account show --query user.name -o tsv) -TenantId (az account show --query tenantId -o tsv) -SubscriptionId $Sub
```

## 1. Tags (Onda 0)

Entrada: um CSV no formato de [lab/examples/AUM_Tags_Lab.csv](../lab/examples/AUM_Tags_Lab.csv), separador `;`, revisado pelos donos (coluna `Aprovado = S`).

```powershell
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\tags.csv                       # simulação
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\tags.csv -Aplicar -Ambiente DEV
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\tags.csv -Aplicar -Ambiente HML
```

O script valida valores (com diferenciação de maiúsculas), a coerência Ambiente × PatchWave e os campos obrigatórios em Wave, grava em modo **Merge** (preserva as demais tags) e gera `tags-relatorio-<data-hora>.csv`. Confira com a **Q11**.

## 2. Maintenance Configurations

```powershell
az group create -n rg-aum-patching -l brazilsouth
az deployment group create -g rg-aum-patching -n aum-mc -f scripts\bicep\02-maintenance-configurations.bicep `
  -p linuxExcl=@scripts\bicep\linux-exclusions.json startDateTime='2027-01-01 22:00' owner='Plataforma-Cloud'
```

A primeira execução é a primeira ocorrência depois de `startDateTime`. Confirme as datas no portal (Maintenance Configuration › Schedule).

## 3. Dynamic Scopes

Monte o `waves.json` a partir da saída do passo 2:

```powershell
$mc = az deployment group show -g rg-aum-patching -n aum-mc --query properties.outputs.mcIds.value -o json | ConvertFrom-Json
$map = @{ 'mc-aum-wave1-dev'='Wave1-Dev'; 'mc-aum-wave2-hml-piloto'='Wave2-HML-Piloto'; 'mc-aum-wave3-hml'='Wave3-HML' }
@($mc | ForEach-Object { @{ mcId = $_.id; tag = $map[$_.name] } }) | ConvertTo-Json | Set-Content .\waves.json
az deployment sub create -l brazilsouth -n aum-ds -f scripts\bicep\03-dynamic-scopes.bicep -p waves=@waves.json
```

Confira no portal (Maintenance Configuration › Dynamic scopes) a prévia de máquinas, que deve bater com a **Q8**.

## 4. Azure Policy

```powershell
.\scripts\powershell\04-policies.ps1 -Sub $Sub                 # atribuições
az policy state trigger-scan --subscription $Sub                # 5 a 15 minutos
.\scripts\powershell\04-policies.ps1 -Sub $Sub -Remediar        # remediação em sequência
```

| Atribuição | Política | Escopo e filtro |
|---|---|---|
| `aum-cms-prereq` | Built-in 9905ca54 (Customer Managed Schedules, DINE) | Assinatura, tag `PatchWave` ∈ Wave1/2/3 |
| `aum-pa-vm-win` / `aum-pa-vm-lnx` | Built-in 59efceea (Periodic Assessment, Azure VMs) | Uma por SO |
| `aum-pa-arc-win` / `aum-pa-arc-lnx` | Built-in bfea026e (Periodic Assessment, Arc) | Uma por SO |
| `aum-tags-audit` | Customizada ([13-policy-tags-auditoria.json](../scripts/policy/13-policy-tags-auditoria.json)) | Assinatura, efeito audit |

> Remediar CMS e Periodic Assessment **ao mesmo tempo** causa `Conflict` (os dois fazem PUT na mesma VM) e pode desfazer o patch mode. O script remedia em sequência. Ao final, a **Q6** deve mostrar `AutomaticByPlatform`, `bypass = true` e `assessmentMode = AutomaticByPlatform` em todas as máquinas em Wave.

## 5. Automation, permissões e Event Grid

```powershell
.\scripts\powershell\05-automation.ps1 -Sub $Sub -RG rg-aum-patching -AA aa-aum-patching -KeyVault <key-vault>
```

O script cria, de forma idempotente:

1. Automation Account com identidade gerenciada.
2. Papel customizado **AUM Pre-Patch Operator** (formato `Permissions[]`) e as atribuições por ID: Reader e Backup Operator na assinatura, AUM Pre-Patch Operator na assinatura, Automation Job Operator na conta.
3. Variáveis: `AUM-Feriados`, `AUM-FailClosed`, `AUM-RetencaoBackupDias`, `AUM-HoldWaves`, `AUM-LigarDesalocadas`, `AUM-HybridWorkerGroup`, `AUM-AutomationAccount`, `AUM-AutomationRG`, `AUM-vCenter`.
4. Runtime environment **PowerShell-7.4** (Az 12.3.0) e os runbooks `AUM-PreEvent` e `AUM-PostEvent` publicados nele.
5. Webhooks com validade de um ano. **A URI só pode ser lida na criação:** com `-KeyVault`, ela é gravada como segredo com a data de expiração.
6. Um system topic do Event Grid por Maintenance Configuration, com assinaturas `pre-*` e `post-*` para os webhooks.

Papel AUM Pre-Patch Operator:

```
Microsoft.Compute/virtualMachines/read            Microsoft.Compute/disks/read
Microsoft.Compute/snapshots/read                  Microsoft.Compute/snapshots/write
Microsoft.Maintenance/maintenanceConfigurations/read
Microsoft.Maintenance/applyUpdates/read           Microsoft.Maintenance/applyUpdates/write
Microsoft.Resources/subscriptions/resourceGroups/read
Microsoft.Compute/virtualMachines/start/action    Microsoft.Compute/virtualMachines/deallocate/action
Microsoft.Resources/tags/write
```

Sem `start/action`, o PatchStartStop recebe **403 AuthorizationFailed** (reproduzido no laboratório). O RBAC leva alguns minutos para propagar depois de cada mudança.

O runbook `08-runbook-vsphere.ps1` (snapshot no vCenter) é importado no Hybrid Runbook Worker com PowerCLI e a credencial `vCenter-AUM` (conta só com permissão de snapshot).

## 6. Verificações finais

| Verificação | Como | Esperado |
|---|---|---|
| Máquinas prontas por Wave | Q8 | Situação `Pronta` |
| Tags coerentes | Q11 | Nenhum apontamento para máquinas em Wave |
| Patch mode | Q6 | AutomaticByPlatform + bypass |
| Proteção atual | Q10 | Cofre e último backup preenchidos onde `PreBackup = AzureBackup` |
| Event Grid | `az eventgrid system-topic event-subscription list` | `Succeeded` nas seis assinaturas |
| Pré-evento real | Maintenance Configuration de teste (ver [laboratório](laboratorio.md)) | Job `AUM-PreEvent` Completed e execução cancelada ou concluída como esperado |
