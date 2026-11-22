# Modelo de GMUD · Patching de DEV e HML com Azure Update Manager

Modelo de Gestão de Mudanças para o CAB. Substitua os campos entre colchetes.

| Campo | Informação |
|---|---|
| Número | [a definir pelo CAB] |
| Tipo | Normal na primeira aprovação; depois, padrão recorrente mensal |
| Solicitante | [nome] |
| Ambiente | [assinatura] · Azure VMs e Azure Arc · DEV e HML |

## 1. Objetivo

Implantar e operar a aplicação mensal de patches críticos e de segurança do sistema operacional, pelo Azure Update Manager, nas máquinas de DEV e HML, em três Waves depois da Patch Tuesday, sem reboot automático e com proteção antes de cada janela.

## 2. Justificativa técnica

- Reduzir o tempo de exposição a vulnerabilidades com um processo automatizado e auditável.
- [Dados do inventário: máquinas sem tag de ambiente, avaliação periódica inativa, patch mode AutomaticByOS, SO perto do fim do suporte. Rodar a Q1 (10b) e a Q6.]
- Validar o processo em DEV e HML antes de estendê-lo à produção.
- Padronizar janelas fora do horário comercial, com change freeze e calendário de feriados.

## 3. Escopo

| PatchWave | Máquinas |
|---|---|
| Wave1-Dev | [lista] |
| Wave2-HML-Piloto | [lista: ao menos uma por sistema] |
| Wave3-HML | [lista] |
| Hold | [produção, Arc desconectado] |
| Nao-Aplicavel | [nós de cluster, appliances, imagens base] |

**Componentes criados:** três Maintenance Configurations, três Dynamic Scopes, Automation Account com identidade gerenciada e runbooks, system topics e assinaturas do Event Grid, atribuições de Azure Policy, papel customizado AUM Pre-Patch Operator (sem ações de exclusão; inclui ligar e desalocar VM marcada com PatchStartStop e gravar tag) e Workbook. Nenhum recurso existente é excluído ou reconfigurado além das tags e do patch orchestration.

## 4. Cronograma

| Etapa | Período | Responsável |
|---|---|---|
| Onda 0: donos validam a classificação | [datas] | Donos |
| Aplicação das tags (DEV, HML, PROD e exclusões) | [datas] | Time de nuvem |
| Pré-requisitos: Policy, Automation, RBAC | [datas] | Time de nuvem |
| Teste em laboratório ([roteiro](laboratorio.md)) | [datas] | Time de nuvem |
| Aprovação no CAB (POP e GMUD) | [datas] | Change Manager |
| Piloto: Wave 1, Wave 2, Wave 3 | [datas] | Time de nuvem e NOC |
| Primeiro ciclo completo e reavaliação | [datas] | Time de nuvem e Change Manager |

O calendário de exemplo está em [arquitetura.md](arquitetura.md#calendário-de-exemplo-2027).

## 5. Análise de risco

| Risco | Probab. | Impacto | Mitigação |
|---|---|---|---|
| Patch em máquina de produção mal classificada | Média | Alto | Tag confirmada pelo dono; sem tag, sem Wave |
| Patch quebra aplicação em HML | Média | Médio | Piloto na Wave 2, exclusão de pacotes, rollback por snapshot |
| Backup não conclui antes da janela | Baixa | Alto | Fail-closed: cancelamento até T−10 e alerta |
| Primeiro backup não conclui na janela do pré-evento | Média | Alto | Backup inicial concluído antes da Wave (Q10) |
| Mudança de agenda ou tag a menos de 40 min da janela | Baixa | Médio | Congelar mudanças a partir de T−40; execução avulsa |
| Atualização de módulos Az quebra os runbooks | Média | Alto | Runtime PowerShell-7.4 com Az 12.3.0 fixado; repetir o teste em laboratório antes de mudar |
| Reboot pendente prolongado | Alta | Médio | Relatório no pós-evento e janela de reboot com SLA |
| Execução em feriado ou freeze | Baixa | Médio | Calendário no runbook e API de cancelamento |
| VM desalocada ou Arc offline sem patch | Alta | Baixo | Relatório de não conformidade; decisão sobre PatchStartStop |
| Patch em nó de cluster ou appliance | Baixa | Alto | `Nao-Aplicavel` e sem agente Arc nesses nós |
| Custo de snapshots acumulados | Média | Baixo | Snapshots incrementais; revisão mensal pelo dono |

## 6. Comunicação

| Quando | O quê | Público | Canal |
|---|---|---|---|
| D−5 | Aviso da Wave com datas e lista de máquinas | Donos | E-mail e chat |
| D−1 | Lembrete e exceções | Donos e NOC | Chat |
| D0 | Início e fim da janela | NOC e Change Manager | Canal da mudança |
| D+1, 09:00 | Relatório da execução | Donos e Change Manager | E-mail |
| D+1, tarde | Decisão Go/No-Go | Todos | Canal da mudança |

## 7. Validação

- **Antes:** avaliação periódica recente, patch mode correto, tags completas e proteção registrada.
- **Depois:** status por máquina, KBs e pacotes, reboot pendente, serviços no ar, logs sem erro novo.
- **Para seguir à próxima Wave:** 95% de sucesso, nenhum P1/P2, 100% de proteção, smoke tests aprovados até D+1 12:00.
- **Teste em laboratório:** anexar o resultado do roteiro de [laboratório](laboratorio.md) (cancelamento real, execução real completa, proteção e PatchStartStop).

## 8. Plano de retorno

| Nível | Gatilho | Ação | Tempo |
|---|---|---|---|
| Configuração | Comportamento inesperado do agendamento | Wave em `AUM-HoldWaves` ou `PatchWave = Hold`; o pré-evento cancela | Minutos |
| Atualização | KB ou pacote quebra a aplicação | Desinstalar o KB ou reverter o pacote; excluir nas Waves seguintes | Até 1 h por máquina |
| Máquina (Azure) | SO instável | Restaurar do Azure Backup ou trocar o disco de SO por um do snapshot | 1 a 2 h por máquina |
| Máquina (Arc VMware) | SO instável | Reverter para o snapshot `AUM-<execução>` no vCenter | Até 1 h por máquina |

Os componentes podem ser desativados sem exclusão: retirar as tags `PatchWave` ou colocar as Waves em Hold.

## 9. Decisões pedidas ao CAB

1. Aprovar a classificação proposta e indicar os donos.
2. VMs desalocadas: ligar no pré-evento e desligar no pós (`AUM-LigarDesalocadas`), ou manter fora.
3. Falha de proteção: fail-closed (recomendado) ou fail-open.
4. Confirmar as exclusões: nós de cluster, appliances e imagens base.
5. Definir o SLA de reboot pendente em DEV e HML.
6. Aprovar o piloto e a regra de remanejamento por feriado.

## 10. Aprovações

| Papel | Nome | Assinatura | Data |
|---|---|---|---|
| Solicitante | | | |
| Gestão de infraestrutura de nuvem | | | |
| Gestão de infraestrutura on-premises | | | |
| Segurança da informação | | | |
| Change Manager (CAB) | | | |
