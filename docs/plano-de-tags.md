# Plano de tags e associação às Waves

As tags separam DEV, HML e PROD, ligam cada ambiente a uma Wave e indicam o método de proteção. A associação às Waves é feita **só por tag**: nenhuma máquina é associada manualmente.

## 1. Taxonomia

Seis tags com valores fechados. Os valores **diferenciam maiúsculas e minúsculas**.

| Tag | Valores permitidos | Obrigatória | Quem define | Uso |
|---|---|---|---|---|
| `Ambiente` | `DEV` · `HML` · `PROD` | Todas | Dono do sistema | Identifica o ambiente e limita a Wave permitida |
| `PatchWave` | `Wave1-Dev` · `Wave2-HML-Piloto` · `Wave3-HML` · `Hold` · `Nao-Aplicavel` | Todas | Time de nuvem, com o dono | Filtro do Dynamic Scope de cada Wave |
| `PreBackup` | `AzureBackup` · `Snapshot` · `Hypervisor` · `MABS` | Em Wave | Time de nuvem | Método de proteção do pré-evento |
| `SystemOwner` | e-mail do responsável | Em Wave | Gestão de infraestrutura | Avisos D−5/D−1 e smoke test |
| `Sistema` | nome do sistema | Recomendada | Dono do sistema | Montar o piloto HML com uma máquina por sistema |
| `PatchStartStop` | `true` · `false` | Opcional | CAB | Liga a VM desalocada no pré-evento e desliga no pós |

- **Hold:** a máquina é patchável, mas está fora das Waves por decisão temporária (produção até a fase seguinte, Arc desconectado, No-Go do Change Manager).
- **Nao-Aplicavel:** a máquina nunca deve ser patchada pelo AUM (nós de cluster, appliances, imagens base, VMs VMware duplicadas de um servidor Arc).
- **`AUM-StartedBy`:** marcador técnico gravado pelo pré-evento nas VMs que ele liga e limpo pelo pós-evento. Não faz parte da taxonomia e não deve ser alterado manualmente.

> **Maiúsculas:** o `01-tags.ps1` (com `-cnotin`) e a Q11 (KQL `in`) diferenciam maiúsculas. A política de auditoria do Azure Policy **não** diferencia: um valor como `dev` passa nela e só é apontado pela Q11, que por isso é a verificação obrigatória.

## 2. Regras de associação

| Ambiente | PatchWave permitida | Regra |
|---|---|---|
| DEV | `Wave1-Dev` · `Hold` · `Nao-Aplicavel` | Toda máquina de DEV patchável vai para a Wave 1 |
| HML | `Wave2-HML-Piloto` · `Wave3-HML` · `Hold` · `Nao-Aplicavel` | Piloto com cerca de 20% das máquinas e ao menos uma por sistema; o restante na Wave 3 |
| PROD | `Hold` · `Nao-Aplicavel` | Fora das Waves de DEV/HML |

- Sem tag `Ambiente` confirmada pelo dono, a máquina não recebe PatchWave de Wave.
- Máquina em Wave precisa de `SystemOwner` e `PreBackup` preenchidos.
- Trocar de Wave é trocar a tag `PatchWave`, com registro na GMUD; vale na execução seguinte.
- **Não trocar a tag nos 40 minutos anteriores à janela:** o AUM cancela a execução.

## 3. Aplicação

| Etapa | Atividade | Evidência |
|---|---|---|
| 1 | Donos revisam o CSV e marcam `Aprovado = S` | CSV aprovado |
| 2 | `01-tags.ps1` sem `-Aplicar` (simulação); corrigir as linhas rejeitadas | `tags-relatorio-*.csv` |
| 3 | Aplicar DEV: `-Aplicar -Ambiente DEV` | Q11 sem apontamento para DEV |
| 4 | Aplicar HML (piloto e Wave 3) | Q11 sem apontamento para HML |
| 5 | Aplicar PROD com `Hold` e as exclusões com `Nao-Aplicavel` | Q11 sem apontamento |
| 6 | Atribuir a política de auditoria das tags | Conformidade da política |
| 7 | Contínuo: máquinas novas já com tags; a política aponta quem ficou sem | Relatório semanal Q11 |

As tags são gravadas em modo Merge: as existentes são preservadas e nenhuma é removida. A permissão de alterar tags nas máquinas fica restrita ao time de nuvem.

## 4. Associação às Waves

| Wave | Maintenance Configuration | Dynamic Scope | Filtro |
|---|---|---|---|
| 1 | `mc-aum-wave1-dev` | `ds-wave1-dev` | `PatchWave = Wave1-Dev` |
| 2 | `mc-aum-wave2-hml-piloto` | `ds-wave2-hml-piloto` | `PatchWave = Wave2-HML-Piloto` |
| 3 | `mc-aum-wave3-hml` | `ds-wave3-hml` | `PatchWave = Wave3-HML` |

### Pré-requisitos para a máquina ficar "Pronta"

| Plataforma | Pré-requisito | Como resolver |
|---|---|---|
| VM Azure | Customer Managed Schedules (AutomaticByPlatform e bypass = true) | Política built-in com remediação |
| VM Azure | Ligada na janela | Manter ligada ou `PatchStartStop = true` (decisão do CAB) |
| VM Azure | Azure VM Agent reportando | Verificar o agente e a extensão de OS Update |
| VM Azure com `AzureBackup` | Backup inicial concluído | Q10 com último backup preenchido |
| Servidor Arc | Status Connected e extensão de OS Update saudável | Reconectar o agente |
| VM VMware | Agente Arc instalado | Arc › vCenter › habilitar guest management |
| Todas | `PreBackup` e `SystemOwner` preenchidos | Etapas 3 a 5 |

### Passo a passo

1. Implantar as Maintenance Configurations e os Dynamic Scopes. Com as Waves vazias, nada é executado.
2. Depois das etapas 3 a 5, rodar a **Q8**: mostra, por Wave e ambiente, quantas máquinas o Dynamic Scope vai pegar e quais estão prontas.
3. Corrigir as pendências apontadas.
4. Rodar a **Q11**: nenhuma combinação incoerente pode existir.
5. Conferir no portal a prévia de cada Dynamic Scope; deve bater com a Q8.
6. Na semana anterior à Wave, congelar as tags da Wave.

## 5. Governança contínua

- **Auditoria:** a política customizada aponta máquina sem `Ambiente` ou `PatchWave`, valor fora da lista ou combinação incoerente.
- **Revisão mensal:** a Q11 e a Q8 entram no D−5 de cada ciclo ([POP](pop.md)).
- **Rastreabilidade:** a Q9 (`resourcechanges`) mostra quem mudou `Ambiente`, `PatchWave` ou `PreBackup` nos últimos 14 dias. No laboratório ela **não registrou todas** as alterações: para evidência de GMUD, use também o Activity Log (operação `Microsoft.Resources/tags/write`).
