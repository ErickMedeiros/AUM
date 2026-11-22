# Azure Update Manager · Modelo de patching DEV/HML em 3 Waves

Modelo de implantação do **Azure Update Manager (AUM)** para aplicar patches críticos e de segurança do sistema operacional em Azure VMs e servidores Azure Arc, em três Waves depois da Patch Tuesday, **sem reboot automático** e com **backup ou snapshot antes de cada janela**.

Tudo neste repositório foi **implantado e testado de ponta a ponta numa assinatura de laboratório** (pay-as-you-go), com três VMs: uma Windows em DEV, uma Windows em HML piloto e uma Linux em HML. O resultado do teste e o roteiro para reproduzi-lo estão em [docs/laboratorio.md](docs/laboratorio.md).

## Como funciona

```
Tag PatchWave ──► Dynamic Scope ──► Maintenance Configuration (Wave 1, 2 ou 3)
                                         │
                       T−30 min          ▼  Event Grid (system topic)
       AUM-PreEvent (webhook) ◄── PreMaintenanceEvent
         ├─ guard de calendário: fim de semana, feriado, freeze, Wave em Hold → cancela a run
         ├─ liga VM desalocada marcada com PatchStartStop = true
         └─ protege: backup on-demand (Azure Backup) ou snapshot incremental dos discos
                                         │
                       T                 ▼  instalação Critical + Security, Never Reboot
                                         │
       AUM-PostEvent (webhook) ◄── PostMaintenanceEvent
         └─ lista reboot pendente e desaloca as VMs que o pré-evento ligou
```

| Wave | Tag `PatchWave` | Maintenance Configuration | Recorrência | Janela |
|---|---|---|---|---|
| 1 | `Wave1-Dev` | `mc-aum-wave1-dev` | Segunda terça do mês + 1 dia (quarta) | 22:00–01:55 |
| 2 | `Wave2-HML-Piloto` | `mc-aum-wave2-hml-piloto` | Segunda terça + 6 dias (segunda) | 22:00–01:55 |
| 3 | `Wave3-HML` | `mc-aum-wave3-hml` | Terceira terça + 1 dia (quarta) | 22:00–01:55 |

## Estrutura

```
scripts/
  powershell/   01-tags · 04-policies · 05-automation · 10-exportar-inventario · 12-vcenter-guestos
  bicep/        02-maintenance-configurations · 03-dynamic-scopes · linux-exclusions.json
  runbooks/     06-runbook-pre (AUM-PreEvent) · 07-runbook-post (AUM-PostEvent) · 08-runbook-vsphere
  policy/       13-policy-tags-auditoria.json
  kql/          09-queries (Q1–Q7) · 10a/10b inventário · 11-tags-governanca (Q8–Q11)
lab/            roteiro de teste: MCs temporárias, eventos simulados, leitura de jobs, limpeza
docs/           arquitetura · implantação · plano de tags · POP · modelo de GMUD · laboratório
CHANGELOG.md    defeitos da v1.0 encontrados no teste e corrigidos na v1.1
```

## Início rápido

Pré-requisitos: Azure CLI 2.86+ com Bicep, Az PowerShell (Az.Resources 10+, Az.Automation, Az.ResourceGraph, Az.RecoveryServices), Owner ou User Access Administrator na assinatura.

```powershell
az login --tenant <tenant-id>; az account set --subscription <subscription-id>
$Sub = '<subscription-id>'

# 1. Tags (simulação, depois aplicação por ambiente)
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\minhas-tags.csv
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\minhas-tags.csv -Aplicar -Ambiente DEV

# 2. Maintenance Configurations e Dynamic Scopes
az group create -n rg-aum-patching -l brazilsouth
az deployment group create -g rg-aum-patching -f scripts\bicep\02-maintenance-configurations.bicep -p linuxExcl=@scripts\bicep\linux-exclusions.json
az deployment sub create -l brazilsouth -f scripts\bicep\03-dynamic-scopes.bicep -p waves=@waves.json

# 3. Políticas (atribuição, avaliação e remediação em sequência)
.\scripts\powershell\04-policies.ps1 -Sub $Sub
az policy state trigger-scan --subscription $Sub
.\scripts\powershell\04-policies.ps1 -Sub $Sub -Remediar

# 4. Automation, RBAC, runbooks 7.4, webhooks e Event Grid
.\scripts\powershell\05-automation.ps1 -Sub $Sub -KeyVault <nome-do-key-vault>
```

O passo a passo completo, com o formato do `waves.json` e as verificações, está em [docs/implantacao.md](docs/implantacao.md).

## Documentação

| Documento | Conteúdo |
|---|---|
| [Arquitetura](docs/arquitetura.md) | Componentes, sequência de uma execução, Waves, calendário, reboot, Hotpatch, resiliência |
| [Implantação](docs/implantacao.md) | Ordem, comandos, RBAC e verificações de cada etapa |
| [Plano de tags](docs/plano-de-tags.md) | Taxonomia, regras Ambiente × PatchWave e governança |
| [POP](docs/pop.md) | Procedimento mensal D−5, D−1, D0 e D+1, falhas e rollback |
| [Modelo de GMUD](docs/gmud-modelo.md) | Justificativa, riscos, plano de retorno e decisões para o CAB |
| [Laboratório](docs/laboratorio.md) | Ambiente de teste, roteiro, resultados e limpeza |
| [CHANGELOG](CHANGELOG.md) | O que mudou da v1.0 para a v1.1 |

## Princípios

- **Não destrutivo:** nenhum script, runbook ou permissão exclui recursos, discos, snapshots ou backups. A limpeza de snapshots é manual, pelo dono.
- **Associação só por tag:** nenhuma máquina é ligada a uma Wave manualmente. Sem tag confirmada, a máquina fica fora.
- **Fail-closed:** se a proteção pré-patch falhar, o pré-evento cancela a execução (configurável).
- **Never Reboot:** o reboot fica pendente e é feito em janela própria.

## Aviso

Modelo de referência. Revise tags, calendário, feriados, exclusões de pacotes e permissões para o seu ambiente, e repita o roteiro de [laboratório](docs/laboratorio.md) antes de usar em produção ou depois de atualizar os módulos Az.
