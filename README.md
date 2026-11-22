# 🛠️ Azure Update Manager (AUM)

## Patching previsível para ambientes DEV e HML — em 3 Waves

Como aplicar atualizações críticas e de segurança sem perder o controle da janela de manutenção? Este projeto apresenta um modelo de patching para Azure VMs e servidores Azure Arc, organizado em três Waves após a Patch Tuesday — com proteção antes da janela e **sem reboot automático**.

> 🎯 **Em poucas palavras:** escopo por tags, validações antes da manutenção, backup ou snapshot e acompanhamento do ciclo de patch do início ao fim.

## ✨ O que este projeto entrega

- 🗓️ **Três Waves de implantação** para distribuir as atualizações entre DEV, HML piloto e HML.
- 🏷️ **Escopo dinâmico por tags**: as máquinas entram na Wave correspondente quando atendem à taxonomia definida.
- 🛡️ **Proteção pré-patch**: backup on-demand do Azure Backup ou snapshot incremental dos discos, conforme a configuração.
- ⚙️ **Automação orientada a eventos**: Event Grid aciona runbooks antes e depois da janela de manutenção.
- 🚦 **Guardas operacionais**: calendário, feriados, freeze e Wave em Hold podem impedir a execução.
- 🔒 **Fail-closed configurável**: se a proteção pré-patch falhar, o pré-evento pode cancelar a execução.
- 🔄 **Never Reboot**: o reboot não é automático; fica pendente para uma janela própria.

## 🧪 Testado em laboratório

A solução foi implantada e testada de ponta a ponta em uma assinatura de laboratório pay-as-you-go, com três VMs: Windows em DEV, Windows em HML piloto e Linux em HML.

- ✅ Uma execução real foi cancelada pelo guard de calendário.
- ✅ Uma execução real foi concluída em 10 minutos; no cenário testado, não havia patches pendentes e o reboot ficou como `NotNeeded`.
- ✅ Foram exercitados fluxos de snapshot, backup on-demand, cancelamento por falha de proteção e liga/desaloca de VM.
- ℹ️ Alguns cenários de proteção e eventos foram simulados; os resultados e limites de cada teste estão documentados no [relatório do laboratório](docs/laboratorio.md).

## 🧭 Como funciona

```text
Tag PatchWave ──► Dynamic Scope ──► Maintenance Configuration (Wave 1, 2 ou 3)
                                         │
                       T−30 min          ▼  Event Grid (system topic)
       AUM-PreEvent (webhook) ◄── PreMaintenanceEvent
         ├─ valida calendário, feriados, freeze e estado da Wave
         ├─ pode ligar VM desalocada marcada com PatchStartStop = true
         └─ protege: backup on-demand (Azure Backup) ou snapshot incremental
                                         │
                       T                 ▼  Critical + Security · Never Reboot
                                         │
       AUM-PostEvent (webhook) ◄── PostMaintenanceEvent
         └─ identifica reboot pendente e desaloca VMs ligadas pelo pré-evento
```

| Wave | Tag `PatchWave` | Maintenance Configuration | Recorrência | Janela |
|---|---|---|---|---|
| 1 | `Wave1-Dev` | `mc-aum-wave1-dev` | Segunda terça do mês + 1 dia (quarta) | 22:00–01:55 |
| 2 | `Wave2-HML-Piloto` | `mc-aum-wave2-hml-piloto` | Segunda terça + 6 dias (segunda) | 22:00–01:55 |
| 3 | `Wave3-HML` | `mc-aum-wave3-hml` | Terceira terça + 1 dia (quarta) | 22:00–01:55 |

## 🗂️ O que há no repositório

```text
scripts/
  powershell/   tags · políticas · automação · inventário · vCenter
  bicep/        maintenance configurations · dynamic scopes · exclusões Linux
  runbooks/     pré-evento · pós-evento · vSphere
  policy/       auditoria de tags
  kql/          consultas · inventário · governança de tags
lab/            roteiro e scripts para reproduzir os testes
 docs/          arquitetura · implantação · governança · POP · GMUD · laboratório
CHANGELOG.md    correções da v1.0 identificadas nos testes e alterações da v1.1
```

## 🚀 Início rápido

**Pré-requisitos:** Azure CLI 2.86+ com Bicep, Az PowerShell (`Az.Resources` 10+, `Az.Automation`, `Az.ResourceGraph`, `Az.RecoveryServices`) e papel Owner ou User Access Administrator na assinatura.

```powershell
az login --tenant <tenant-id>; az account set --subscription <subscription-id>
$Sub = '<subscription-id>'

# 1. Validar tags em modo de simulação e depois aplicar por ambiente
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\minhas-tags.csv
.\scripts\powershell\01-tags.ps1 -Sub $Sub -Csv .\minhas-tags.csv -Aplicar -Ambiente DEV

# 2. Criar Maintenance Configurations e Dynamic Scopes
az group create -n rg-aum-patching -l brazilsouth
az deployment group create -g rg-aum-patching -f scripts\bicep\02-maintenance-configurations.bicep -p linuxExcl=@scripts\bicep\linux-exclusions.json
az deployment sub create -l brazilsouth -f scripts\bicep\03-dynamic-scopes.bicep -p waves=@waves.json

# 3. Configurar políticas, avaliar e remediar em sequência
.\scripts\powershell\04-policies.ps1 -Sub $Sub
az policy state trigger-scan --subscription $Sub
.\scripts\powershell\04-policies.ps1 -Sub $Sub -Remediar

# 4. Configurar Automation, RBAC, runbooks 7.4, webhooks e Event Grid
.\scripts\powershell\05-automation.ps1 -Sub $Sub -KeyVault <nome-do-key-vault>
```

📘 O guia de [implantação](docs/implantacao.md) detalha a ordem, o formato de `waves.json` e as verificações de cada etapa.

## 📚 Documentação

| Documento | O que você encontra |
|---|---|
| [Arquitetura](docs/arquitetura.md) | Componentes, fluxo, Waves, calendário, reboot, Hotpatch e resiliência |
| [Implantação](docs/implantacao.md) | Ordem, comandos, RBAC e verificações |
| [Plano de tags](docs/plano-de-tags.md) | Taxonomia, regras Ambiente × PatchWave e governança |
| [POP](docs/pop.md) | Procedimento mensal D−5, D−1, D0 e D+1, falhas e rollback |
| [Modelo de GMUD](docs/gmud-modelo.md) | Justificativa, riscos, plano de retorno e decisões para o CAB |
| [Laboratório](docs/laboratorio.md) | Ambiente, roteiro, resultados e limpeza |
| [CHANGELOG](CHANGELOG.md) | Evolução da v1.0 para a v1.1 |

## 🧱 Princípios de operação

- **Não destrutivo:** scripts, runbooks e permissões não excluem recursos, discos, snapshots ou backups. A limpeza de snapshots é manual, pelo responsável.
- **Associação por tag:** sem tag confirmada, a máquina fica fora da Wave.
- **Fail-closed:** se a proteção pré-patch falhar, o pré-evento pode cancelar a execução (configurável).
- **Never Reboot:** o reboot fica pendente e é realizado em janela própria.

## ⚠️ Antes de usar em produção

Este repositório é um **modelo de referência**. Revise tags, calendário, feriados, exclusões de pacotes e permissões para o seu ambiente. Reproduza o roteiro de [laboratório](docs/laboratorio.md) antes de usar em produção e sempre que atualizar os módulos Az.
