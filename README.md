# Supply Gate

`Supply Gate` e o nome do projeto. Alguns caminhos, marcadores e identificadores de runtime ainda usam o nome legado `supply-chain-protect` por compatibilidade com a implementacao atual.

Ferramenta de hardening local para reduzir risco de ataques de supply chain em estações de desenvolvimento e ambientes de automação.

Ela aplica uma camada obrigatória de:

- wrappers por precedência de `PATH`;
- policy `soft` ou `hard`;
- logging em `STDOUT` e em arquivos persistentes;
- auditoria local de compliance;
- enforcement para gerenciadores de pacote e CLIs de IA.

## Objetivo

O software existe para fechar os caminhos mais comuns de bypass em instalações de dependências e uso de ferramentas sensíveis.

Ele protege especialmente contra:

- uso direto de package managers fora da policy;
- drift em arquivos de configuração;
- ausência de lock discipline;
- instalações feitas sem trilha de auditoria;
- uso de CLIs de IA fora de jail;
- inconsistência de configuração entre máquinas.

No modo `hard`, também força o uso de proxies/registries corporativos.

## Comandos suportados

Atualmente a camada de wrapper cobre:

- `npm`
- `pnpm`
- `yarn`
- `bun`
- `pip`
- `uv`
- `poetry`
- `cargo`
- `go`
- `claude`
- `gemini`
- `codex`

## Modos de operação

### `soft`

Aplica hardening local sem exigir proxy central.

Inclui:

- wrappers obrigatórios;
- configs locais gerenciadas;
- logging por execução;
- `audit` local;
- fail-closed para CLIs de IA sem jail configurada.

### `hard`

Aplica tudo do modo `soft` e exige proxies/registries corporativos.

Se os valores de proxy estiverem ausentes, inválidos ou apontando para placeholders, a aplicação da policy falha.

## Estrutura do repositório

- [install.sh](/Users/jpcbl/petuti-code/supply-gate/install.sh): entrypoint principal.
- [policy/default-policy.conf](/Users/jpcbl/petuti-code/supply-gate/policy/default-policy.conf): policy declarativa.
- [lib/common.sh](/Users/jpcbl/petuti-code/supply-gate/lib/common.sh): runtime compartilhado.
- [shims/manager-wrapper.sh](/Users/jpcbl/petuti-code/supply-gate/shims/manager-wrapper.sh): enforcement de wrappers.
- [scripts/windows-apply.ps1](/Users/jpcbl/petuti-code/supply-gate/scripts/windows-apply.ps1): integração nativa com Windows.
- [fleet/osquery](/Users/jpcbl/petuti-code/supply-gate/fleet/osquery): templates de compliance para FleetDM/osquery.
- [GUIDE.md](/Users/jpcbl/petuti-code/supply-gate/GUIDE.md): guideline ampliado de boas práticas.
- [docs/internal-proxies.md](/Users/jpcbl/petuti-code/supply-gate/docs/internal-proxies.md): guia detalhado de proxies internos.
- [docs/prescriptive-proxy-stack.md](/Users/jpcbl/petuti-code/supply-gate/docs/prescriptive-proxy-stack.md): stack prescritiva recomendada para implantação real.
- [docker/README.md](/Users/jpcbl/petuti-code/supply-gate/docker/README.md): como subir a stack prescritiva com Docker Compose.

## Como funciona

### 1. Wrappers

O instalador cria um diretório de shims e coloca esse diretório antes do restante do `PATH`.

Cada comando protegido passa pelo wrapper, que:

- identifica o binário real;
- carrega a policy ativa;
- aplica variáveis/configurações de ambiente;
- registra logs;
- decide se permite, bloqueia ou exige jail.

### 2. Logging

Cada execução gera:

- saída legível no terminal;
- arquivo de log por rodada;
- evento agregado em `JSONL`.

No macOS/Linux os artefatos ficam em:

```text
~/.local/share/supply-chain-protect/
```

No Windows:

```text
%LOCALAPPDATA%\SupplyChainProtect\
```

Principais subdiretórios:

- `logs/`
- `runtime/`
- `shims/`
- `attestation/`

### 3. Auditoria

O comando `audit` valida:

- runtime instalado;
- shims presentes;
- blocos gerenciados nos perfis;
- arquivos de config gerenciados;
- integridade básica do estado local;
- drift de `hard mode` em `go` e policy.

## Instalação

### Modo `soft`

```sh
./install.sh apply --mode soft
```

### Modo `hard`

Antes, ajuste [policy/default-policy.conf](/Users/jpcbl/petuti-code/supply-gate/policy/default-policy.conf) com seus registries reais.

Depois:

```sh
./install.sh apply --mode hard
```

## Operação

Aplicar:

```sh
./install.sh apply --mode soft
```

Auditar:

```sh
./install.sh audit
```

Reparar:

```sh
./install.sh repair
```

Remover:

```sh
./install.sh uninstall
```

## Configuração da policy

A policy padrão fica em [policy/default-policy.conf](/Users/jpcbl/petuti-code/supply-gate/policy/default-policy.conf).

Parâmetros mais importantes:

- `DEFAULT_MODE`
- `MANAGED_COMMANDS`
- `NPM_REGISTRY_URL`
- `PYTHON_INDEX_URL`
- `CARGO_REGISTRY_URL`
- `GO_PROXY_URL`
- `GO_SUMDB`
- `GO_PRIVATE_PATTERNS`
- `GO_NO_SUMDB_PATTERNS`
- `GO_VCS_RULES`
- `AI_JAIL_BACKEND_MACLINUX`
- `AI_JAIL_BACKEND_WINDOWS`
- `AI_JAIL_LAUNCHER_MACLINUX`
- `AI_JAIL_LAUNCHER_WINDOWS`

## CLIs de IA e jail

`claude`, `gemini` e `codex` são tratados como comandos sensíveis.

Sem launcher configurado para o backend de jail, o wrapper bloqueia a execução.

Isso é intencional.

## FleetDM / osquery

Os arquivos em [fleet/osquery](/Users/jpcbl/petuti-code/supply-gate/fleet/osquery) são templates iniciais para:

- verificar existência de runtime;
- validar hashes de arquivos críticos;
- detectar execução de binários sensíveis;
- diferenciar `soft` e `hard` no backend de compliance.

## Inventário e Incident Response

Este projeto nao tenta ser um scanner universal de estado do endpoint.

O foco continua sendo:

- prevencao local;
- enforcement por wrapper;
- policy de `soft`/`hard`;
- proxy/registry em `hard mode`;
- auditoria local e deteccao de drift.

Para inventario read-only e exposure hunting no endpoint, o encaixe recomendado e usar uma ferramenta complementar como `perplexityai/bumblebee`, sem acoplar seu ciclo de vida ao fluxo principal deste repositorio.

### Divisao de responsabilidade

- `Supply Gate` previne, bloqueia e força policy no momento de execucao.
- proxies internos controlam origem, cache e trilha central de downloads.
- `FleetDM`/`osquery` ajudam a detectar drift, bypass e estado persistente.
- `bumblebee` entra como camada opcional de inventario local e busca de exposicao conhecida.

### O que o Bumblebee agrega

- varredura periodica de workstations Linux/macOS;
- inventario de superficies que este projeto nao observa profundamente hoje;
- campanhas de incidente para localizar pacote, extensao ou config comprometida ja presente no disco;
- leitura de configuracoes MCP em JSON e outros artefatos locais relevantes para exposure scan.

### O que ele nao substitui

- wrappers;
- proxy corporativo;
- `audit`, `apply` ou `repair`;
- telemetria de processo em tempo real;
- enforcement de CLIs de IA ou de package managers.

### Stack recomendado por camada

1. `Supply Gate` para prevencao e enforcement local.
2. proxies internos para controle de origem.
3. `FleetDM`/`osquery` para drift e bypass detection.
4. `bumblebee` para inventario endpoint-side e incident response.

### Modelo operacional sugerido

- `baseline` diario para inventario leve de workstation;
- `project` para roots conhecidos de desenvolvimento;
- `deep` apenas em incidente ou campanha de exposure hunting;
- preferir saida em arquivo `NDJSON` ou `POST` HTTP para relay interno;
- correlacionar resultados com `events.jsonl`, sinais de bypass no `FleetDM`/`osquery` e logs de proxy.

### Limitacoes e cautelas desta avaliacao

Esta recomendacao assume uma avaliacao de encaixe feita em 23 de maio de 2026, considerando o estado do `bumblebee` `v0.1.1`, publicado em 22 de maio de 2026.

- cobertura declarada para Linux/macOS, nao Windows;
- projeto ainda novo nesta avaliacao;
- sem spool/queue local;
- modo `deep` nao deve ser tratado como fonte permanente de "current state";
- cobertura MCP parcial para `codex`, porque a leitura de `config.toml` nao entra nessa avaliacao inicial.

### O que nao fazer

- nao tornar `bumblebee` dependencia obrigatoria do `install.sh`;
- nao falhar `apply`, `audit` ou `repair` pela ausencia dele;
- nao tratar inventario read-only como substituto de enforcement.

## Limitações atuais

- O modo `hard` depende de proxies/registries corporativos reais.
- O enforcement de jail no Windows depende da configuração do backend escolhido.
- A auditoria atual é local e baseada em arquivos/processos; não substitui telemetria central.
- Nem todo ecossistema permite o mesmo nível de bloqueio apenas com configuração local.

## Recomendações de rollout

Ordem sugerida:

1. Ajustar a policy para a sua organização.
2. Implantar em `soft`.
3. Validar logs, wrappers e `audit`.
4. Implantar proxies internos.
5. Migrar grupos controlados para `hard`.
6. Ligar FleetDM/osquery para drift e bypass detection.

## Próximos incrementos recomendados

- assinatura dos artefatos de policy;
- encadeamento criptográfico dos logs;
- queries Fleet por SO;
- integração com SIEM;
- validação mais rígida de registries por ecossistema;
- backend de jail pronto para macOS/Linux/Windows.

## Matriz de Cobertura

| Camada | Cobre bem | Nao cobre sozinha |
| --- | --- | --- |
| Wrappers + policy local | enforcement, PATH, lock discipline, jail, trilha local de execucao | inventario profundo de estado ja presente no disco |
| Proxies internos | origem, cache, bloqueio pre-download, trilha central | bypass fora do fluxo gerenciado, execucao pos-download |
| `FleetDM` / `osquery` | drift, hash, presence checks, alguns sinais de bypass | bloqueio inline e inventario sem query/modelagem previa |
| `bumblebee` | inventario read-only, exposure scan local, extensoes/configs MCP JSON | enforcement, proxy, correcao de drift, observacao de processo em tempo real |
