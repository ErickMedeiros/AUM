// 03-dynamic-scopes.bicep · escopo de assinatura
// az deployment sub create -l brazilsouth -f 03-dynamic-scopes.bicep -p waves=@waves.json
// waves.json: [{ "mcId": "<id da mc-aum-wave1-dev>", "tag": "Wave1-Dev" }, ...]
targetScope = 'subscription'

param waves array

resource ds 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = [for w in waves: {
  name: 'ds-${toLower(w.tag)}'          // sem location: atribuição no nível da assinatura
  properties: {
    maintenanceConfigurationId: w.mcId
    filter: {
      resourceTypes: [
        'Microsoft.Compute/virtualMachines'
        'Microsoft.HybridCompute/machines'
      ]
      osTypes: [
        'Windows'
        'Linux'
      ]
      tagSettings: {
        filterOperator: 'All'
        tags: {
          PatchWave: [ w.tag ]
        }
      }
    }
  }
}]

