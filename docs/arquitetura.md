# Arquitetura

## 1. Objetivo e escopo

Aplicar mensalmente os patches **Critical** e **Security** do sistema operacional nos ambientes de Desenvolvimento (DEV) e Homologação (HML), com o Azure Update Manager, em três Waves, sem reboot automático e com proteção antes de cada janela.

**Dentro do escopo**
- Azure VMs Windows e Linux e servidores Azure Arc com status Connected.
- Classificações Critical e Security do sistema operacional.
- Proteção pré-patch: backup on-demand (Azure Backup) ou snapshot incremental de discos gerenciados; snapshot no vCenter para VMs VMware com agente Arc.

**Fora do escopo**
- Produção (fase seguinte, depois de dois ciclos estáveis em DEV e HML).
- Aplicações de terceiros, bancos de dados, runtimes, web servers e agentes.
- Nós de cluster (ex.: OpenShift), appliances de fornecedor e imagens base (golden images).
- Reinicialização automática: todas as Maintenance Configurations usam **Never Reboot**.

> **Política não destrutiva:** nenhuma regra, script ou automação exclui recursos, discos, snapshots antigos ou configurações existentes. As permissões da identidade gerenciada não incluem ações de exclusão.

## 2. Componentes

| Componente | Função |
|---|---|
| Tags `Ambiente`, `PatchWave`, `PreBackup`, `SystemOwner` | Roteiam cada máquina para a Wave e indicam o método de proteção ([plano de tags](plano-de-tags.md)) |
| Dynamic Scope (`configurationAssignments`) | Filtra por assinatura, tipo de recurso, SO e tag `PatchWave`; reavaliado em cada execução |
| Maintenance Configurations (3) | Agendas relativas à Patch Tuesday, janela 22:00–01:55, Never Reboot, Critical + Security |
| Event Grid (system topic por configuração) | Entrega `PreMaintenanceEvent` e `PostMaintenanceEvent` aos webhooks |
| Azure Automation (PowerShell 7.4, identidade gerenciada) | `AUM-PreEvent`, `AUM-PostEvent` e `AUM-Snapshot-vSphere` |
| Hybrid Runbook Worker (on-premises) | Snapshot no vCenter para servidores Arc em VMware |
| Azure Backup / snapshots incrementais | Ponto de restauração antes da instalação |
| Azure Resource Graph + Workbook | Status por Wave, KBs, reboot pendente e evidência de proteção |

## 3. Sequência de uma execução

1. Cerca de **30 minutos antes** da janela, o AUM publica o `PreMaintenanceEvent` no Event Grid, que chama o webhook do `AUM-PreEvent`. No laboratório o evento chegou 34 a 35 minutos antes.
2. O runbook valida o tipo de evento e confere o calendário (fim de semana, feriado, freeze, Wave em Hold). Se necessário, cancela a execução; o cancelamento só é aceito até o `CancellationCutOffDateTime` (10 minutos antes do início).
3. O runbook obtém as máquinas da execução no Resource Graph e protege cada uma: backup on-demand, snapshot incremental ou job no Hybrid Worker. VMs desalocadas com `PatchStartStop = true` são ligadas.
4. Na janela, o AUM instala as atualizações Critical e Security. Nada é reiniciado.
5. O `PostMaintenanceEvent` aciona o `AUM-PostEvent`: lista o reboot pendente e desaloca as VMs que o pré-evento ligou. **O pós-evento também chega em execução cancelada** (`Status = Cancelled`).

O status da execução no AUM reflete só a instalação. O status do pré e do pós-evento fica no job do runbook. Se a plataforma não conseguir entregar o pré-evento, ela mesma cancela a execução.

**Regra dos 40 minutos:** criar ou editar uma Maintenance Configuration com pré-evento, um Dynamic Scope ou a tag `PatchWave` de uma máquina menos de 40 minutos antes da janela leva ao cancelamento automático da execução.

## 4. Waves e calendário

| Wave | Tag | Maintenance Configuration | `recurEvery` | Dia | Janela |
|---|---|---|---|---|---|
| 1 | `Wave1-Dev` | `mc-aum-wave1-dev` | `Month Second Tuesday Offset1` | Quarta, PT+1 | 22:00–01:55 |
| 2 | `Wave2-HML-Piloto` | `mc-aum-wave2-hml-piloto` | `Month Second Tuesday Offset6` | Segunda, PT+6 | 22:00–01:55 |
| 3 | `Wave3-HML` | `mc-aum-wave3-hml` | `Month Third Tuesday Offset1` | Quarta, PT+8 | 22:00–01:55 |

- **Janela:** 03:55, o máximo do escopo InGuestPatch. O AUM reserva 10 minutos para reboot e não inicia instalação com menos de 25 minutos restantes.
- **Fim de semana:** os deslocamentos +1, +6 e +8 a partir da Patch Tuesday caem sempre em segunda ou quarta.
- **Change freeze:** últimos 7 dias corridos do mês. Pelo desenho, nenhuma Wave passa do dia 22; o pré-evento cancela se a data cair no freeze.
- **Feriados:** o AUM não tem calendário de exceções. A lista fica na variável `AUM-Feriados` da Automation e é conferida pelo pré-evento. Uma Wave cancelada por feriado é executada como atualização avulsa na noite útil seguinte, fora do freeze.
- **Soak:** 5 dias entre DEV e o piloto de HML; 2 dias entre o piloto e o restante de HML.

### Calendário de exemplo (2027)

| Mês | Patch Tuesday | Wave 1 | Wave 2 | Wave 3 | Freeze |
|---|---|---|---|---|---|
| Jan | 12/01 | 13/01 | 18/01 | 20/01 | 25–31/01 |
| Fev | 09/02 | 10/02 | 15/02 | 17/02 | 22–28/02 |
| Mar | 09/03 | 10/03 | 15/03 | 17/03 | 25–31/03 |
| Abr | 13/04 | 14/04 | 19/04 | 21/04 | 24–30/04 |
| Mai | 11/05 | 12/05 | 17/05 | 19/05 | 25–31/05 |
| Jun | 08/06 | 09/06 | 14/06 | 16/06 | 24–30/06 |
| Jul | 13/07 | 14/07 | 19/07 | 21/07 | 25–31/07 |
| Ago | 10/08 | 11/08 | 16/08 | 18/08 | 25–31/08 |
| Set | 14/09 | 15/09 | 20/09 | 22/09 | 24–30/09 |
| Out | 12/10 | 13/10 | 18/10 | 20/10 | 25–31/10 |
| Nov | 09/11 | 10/11 | 15/11 | 17/11 | 24–30/11 |
| Dez | 14/12 | 15/12 | 20/12 | 22/12 | 25–31/12 |

Confira os feriados nacionais e locais do seu calendário (ex.: 21/04 cai na Wave 3 e 15/11 na Wave 2 em 2027).

## 5. Reinicialização e Hotpatch

**Never Reboot:** updates que exigem reinício ficam instalados e pendentes; a correção só vale depois do reboot, feito em janela própria. No Linux, o kernel novo só entra em uso após o reinício.

| Plataforma | Elegibilidade | Pré-requisitos | Comportamento |
|---|---|---|---|
| Azure VM Windows | Windows Server 2022/2025 Datacenter: Azure Edition, imagens do Marketplace | Patch mode AutomaticByPlatform; extensão `Microsoft.CPlat.Core.WindowsHotpatch` saudável; baseline em dia | Meses de hotpatch sem reboot; baseline trimestral exige reboot |
| Azure Arc Windows | Windows Server 2025 Standard/Datacenter | VBS (UEFI e Secure Boot), agente Arc, Hotpatch ativado no Arc | Oito meses de hotpatch e quatro de baseline por ano |
| Linux | Não suportado pelo AUM | Live patch da distribuição, fora do AUM | Kernel fica em reboot pendente |

Não são hotpatchados: updates não-segurança, .NET, drivers e baselines extras. Imagem custom não suporta Hotpatch no Azure.

## 6. Escopo das atualizações

| Sistema | Inclui | Exclui |
|---|---|---|
| Windows | Critical e Security | Feature packs, service packs, drivers; desabilitar "receber atualizações de outros produtos Microsoft"; KBs vetados em `kbNumbersToExclude` |
| Linux | Critical e Security | Máscaras em `packageNameMasksToExclude` ([linux-exclusions.json](../scripts/bicep/linux-exclusions.json)): bancos, runtimes e web servers |

No laboratório, uma atualização de definição do Defender (classificação *Definition*) ficou corretamente como *NotSelected*.

Cada execução faz uma avaliação nova. Para que a Wave 3 instale exatamente o que a Wave 1 validou, os KBs da Wave 1 podem ser gravados em `kbNumbersToInclude` das configurações seguintes, com mais complexidade de orquestração.

## 7. Resiliência pré-patch

| Situação | Ação do pré-evento | Evidência |
|---|---|---|
| Azure VM com `PreBackup = AzureBackup` | Backup on-demand com retenção de 30 dias; espera só a fase *Take Snapshot* | Job no cofre (Q5) |
| Azure VM com `PreBackup = Snapshot` | Snapshot incremental de cada disco (SO e dados) com tags `MaintenanceRunId`, `MaintenanceConfig`, `CreatedBy`, `CreatedOn`, `SourceDisk`, `SourceVm` | Snapshots (Q4) |
| Servidor Arc em VMware (`Hypervisor`) | Job `AUM-Snapshot-vSphere` no Hybrid Worker: snapshot sem memória, com quiesce | Snapshot no vCenter |
| Servidor Arc físico (`MABS`) | Confere ponto de recuperação nas últimas 24 h | Console MABS/MARS |
| Sem método definido | A máquina não entra em Wave (`PatchWave = Hold`) | — |

- **Janela útil:** cerca de 20 minutos, entre o pré-evento (T−30) e o corte de cancelamento (T−10).
- **Backup inicial:** o primeiro backup de uma VM recém-protegida é completo. No laboratório, a fase *Take Snapshot* levou 12 minutos e o job inteiro 42 minutos. A máquina só deve entrar em Wave com o backup inicial concluído (Q10).
- **Idempotência:** o Event Grid entrega pelo menos uma vez; o runbook não recria snapshot com o mesmo nome de execução.
- **Falha:** com `AUM-FailClosed = true`, qualquer falha de proteção cancela a execução inteira e o job termina **Failed**.
- **Permissões da identidade da Automation:** Reader e Backup Operator na assinatura, Automation Job Operator na conta e o papel customizado **AUM Pre-Patch Operator**: ler VMs e discos, criar snapshots, ler e cancelar execuções, ligar e desalocar VMs e gravar tags. Nenhuma ação de exclusão.

**Limitação do Azure Arc:** o Arc projeta o servidor no Azure, mas o disco continua no hypervisor ou na nuvem de origem; a API de snapshot do Azure não o alcança. Snapshots no vCenter devem ser removidos pelo dono em até 72 horas.

## 8. Boas práticas aplicadas

- Customer Managed Schedules (AutomaticByPlatform + `BypassPlatformSafetyChecksOnUserSchedule`) nas Azure VMs, por Azure Policy (built-in `9905ca54-1471-49c6-8291-7582c04cd4d4`).
- Periodic Assessment a cada 24 horas por Azure Policy, **uma atribuição por SO** (o parâmetro `osType` das built-ins tem padrão Windows).
- Dynamic Scopes por tag no nível da assinatura.
- Agendamento depois da Patch Tuesday.
- Máquina ligada ao menos 15 minutos antes da janela; máquinas desligadas perdem a execução.
- Arc: agente atualizado, extensão de OS Update com status Succeeded e saída HTTPS 443.
- Pré e pós-eventos com filtro de `eventType` e ações idempotentes.
- Sem GPO ou WSUS conflitantes e sem Windows Update automático local.
- Mover VM entre grupos de recursos ou assinaturas quebra a associação: refazer a atribuição.

## 9. Observabilidade

| Aba do Workbook | Conteúdo | Consulta |
|---|---|---|
| Execução por Wave | Sucesso, falha, com avisos e outros | Q1 |
| KBs e pacotes | Patch, KB, classificação e estado por máquina | Q2 |
| Reboot pendente | Máquinas que precisam reiniciar | Q3 |
| Proteção pré-patch | Snapshots da execução e jobs de backup | Q4, Q5 |
| Pré-requisitos | Patch mode, avaliação periódica e tags | Q6, Q7 |

As consultas estão em [scripts/kql/09-queries.kql](../scripts/kql/09-queries.kql) e [scripts/kql/11-tags-governanca.kql](../scripts/kql/11-tags-governanca.kql).

## 10. Referências

- Azure Update Manager: agendamento recorrente, Dynamic Scopes, pré e pós-eventos — learn.microsoft.com/azure/update-manager
- Linha do tempo dos pré e pós-eventos — learn.microsoft.com/azure/update-manager/pre-post-scripts-overview
- Esquema de eventos de Maintenance Configuration no Event Grid — learn.microsoft.com/azure/event-grid/event-schema-maintenance-configuration
- Hotpatch para Windows Server e servidores Azure Arc — learn.microsoft.com/windows-server/get-started/hotpatch
- Consultas de exemplo do Resource Graph para o AUM — learn.microsoft.com/azure/update-manager/sample-query-logs
