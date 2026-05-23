# Guia Detalhado: Como Criar e Operar Proxies Internos para Supply Chain

Este documento explica como desenhar, implementar e operar proxies/registries internos para suportar o modo `hard` do `Supply Gate`.

O foco aqui e seguranca operacional, previsibilidade e auditabilidade.

## 1. Objetivo dos proxies internos

O proxy interno existe para impedir que cada estacao de trabalho fale diretamente com a internet para resolver dependencias.

Em vez disso:

1. o desenvolvedor ou CI pede um pacote;
2. o package manager fala com o endpoint corporativo;
3. o endpoint corporativo decide se baixa, entrega, nega ou registra;
4. toda a trilha fica concentrada em um ponto controlado.

Isso permite:

- controlar origem;
- aplicar cooldown;
- bloquear pacotes/versoes;
- manter cache local;
- reduzir variacao entre maquinas;
- acelerar resposta a incidentes;
- gerar trilha de auditoria.

## 2. O que exatamente o proxy protege

### Protege bem

- **Download direto de registries publicos**
  - o cliente deixa de falar diretamente com `registry.npmjs.org`, `proxy.golang.org`, `crates.io`, `pypi.org` e afins.
- **Pacotes maliciosos ou suspeitos ja identificados**
  - o proxy pode negar nomes, versoes, publishers ou faixas de tempo.
- **Versoes muito novas**
  - o proxy pode aplicar cooldown e segurar publicacoes recem-lancadas.
- **Typosquatting conhecido**
  - listas de bloqueio podem impedir nomes semelhantes ou suspeitos.
- **Falta de rastreabilidade**
  - cada fetch passa a ter trilha central.
- **Bypass acidental**
  - quem mudar config local continua preso ao proxy se a rede e a policy estiverem corretas.

### Nao protege sozinho

- **Codigo malicioso ja permitido pela policy**
  - se o proxy deixar passar, o pacote ainda pode executar algo ruim.
- **Artefatos vindos por canal alternativo**
  - `git clone`, zip manual, USB, download via navegador, copy/paste de binarios.
- **Execucao pos-download**
  - para isso ainda precisa wrapper, jail, least privilege e auditoria.
- **Comprometimento do proprio proxy**
  - o proxy vira parte critica da supply chain e precisa hardening serio.

## 3. Soft vs Hard com relacao a proxies

### `soft`

Sem proxy corporativo obrigatorio.

Serve para:

- introduzir wrappers;
- padronizar configs;
- gerar logs;
- identificar impacto antes de mexer na rede;
- preparar a organizacao para a migracao.

Risco residual principal:

- o endpoint ainda pode acabar resolvendo dependencias da internet publica se houver bypass suficiente fora do wrapper.

### `hard`

Proxy ou registry corporativo obrigatorio.

Serve para:

- controlar a origem efetiva;
- reduzir bypass por config local;
- centralizar cache e bloqueios;
- medir quem baixou o que;
- viabilizar resposta rapida a incidentes.

## 4. Arquitetura recomendada

### Principios

- um ponto corporativo por ecossistema ou uma camada de servicos por ecossistema;
- alta disponibilidade;
- cache local;
- logs detalhados;
- TLS interno;
- autenticacao entre clientes e proxy quando possivel;
- allowlist/denylist central;
- integracao com SIEM/Fleet.

### Topologia recomendada

```text
Dev machine / CI
  -> local wrapper
  -> proxy corporativo por ecossistema
  -> internet publica somente pelo proxy
```

### Componentes

- **camada cliente**
  - configs de `npm`, `pip`, `cargo`, `go`, etc.
- **camada proxy**
  - reverse proxy, cache ou registry manager.
- **camada de policy**
  - bloqueios, cooldown, allowlists, denyists, autenticacao.
- **camada de auditoria**
  - logs, metrics, eventos de bloqueio, correlacao com usuario e host.

## 5. Abordagem por ecossistema

Nao existe um unico proxy universal pratico para todos os ecossistemas. O desenho correto e por protocolo/ecossistema.

### 5.1 npm / pnpm / yarn / bun

Modelos comuns:

- registry manager interno;
- repositario proxy de artefatos;
- mirror privado com cache e policy.

Capacidades desejadas:

- proxy para `registry.npmjs.org`;
- cache de tarballs;
- bloqueio por pacote/versao;
- cooldown por idade da release;
- logs por token, IP, usuario e package name;
- suporte a scopes privados.

Config cliente esperada:

```ini
registry=https://npm-proxy.corp.example/
save-exact=true
```

No modo `hard`, o wrapper tambem deve exportar:

```sh
NPM_CONFIG_REGISTRY=https://npm-proxy.corp.example/
```

### 5.2 Python (`pip`, `uv`, `poetry`)

Modelos comuns:

- simple index privado;
- proxy de `PyPI`;
- repositorio de pacotes Python com cache.

Capacidades desejadas:

- endpoint compativel com `simple index`;
- cache de wheels e sdists;
- bloqueio por pacote/versao/hash;
- logs por usuario/token;
- suporte a namespaces internos.

Config cliente esperada:

```ini
[global]
index-url = https://pypi-proxy.corp.example/simple/
disable-pip-version-check = true
```

Para `poetry` e `uv`, a organizacao deve padronizar tambem os sources equivalentes.

### 5.3 Rust (`cargo`)

`cargo` exige mais atencao porque o desenho mistura indice e download de crates.

Modelos comuns:

- registry corporativo compativel com crates;
- source replacement para espelhar `crates-io`;
- combinacao de cache + mirror controlado.

Objetivo principal:

- tirar o cliente de `crates.io` direto;
- forcar `source replacement` ou registry interno;
- registrar downloads por crate/versao.

Config cliente esperada em modo `hard`:

```toml
[registries.crates-io]
protocol = "sparse"

[source.crates-io]
replace-with = "corporate"

[source.corporate]
registry = "sparse+https://cargo-proxy.corp.example/"
```

Para workloads criticos:

- combinar proxy com `cargo vendor`;
- exigir `Cargo.lock`;
- restringir `cargo install` fora de allowlist.

### 5.4 Go

O ecossistema Go depende fortemente de `GOPROXY`, `GOSUMDB` e regras para modulos privados.

Objetivo:

- impedir fetch direto de modulo da internet;
- centralizar cache de modulos;
- definir excecoes controladas para modulos privados.

Config cliente esperada em modo `hard`:

```sh
go env -w GOPROXY=https://go-proxy.corp.example/
go env -w GOSUMDB=sum.golang.org
go env -w GOPRIVATE=github.com/sua-org/*
go env -w GONOSUMDB=github.com/sua-org/*
go env -w GOVCS=public:off,private:git|ssh
```

Explicacao:

- `GOPROXY`
  - define por onde os modulos publicos devem ser resolvidos.
- `GOSUMDB`
  - preserva verificacao de checksums para modulos publicos.
- `GOPRIVATE`
  - marca modulos que nao devem passar pelo fluxo publico normal.
- `GONOSUMDB`
  - evita validacao em sumdb publica para modulos privados.
- `GOVCS`
  - reduz uso arbitrario de VCS para modulos publicos.

Observacao importante:

- se `GOPROXY` terminar em `,direct`, voce ainda preserva um bypass para upstream.
- para modo `hard`, o ideal e nao permitir `direct` para modulos publicos.

## 6. Como escolher a implementacao do proxy

Escolha com estes criterios:

- suporte nativo ao ecossistema;
- facilidade de autenticar usuarios/servicos;
- qualidade dos logs;
- capacidade de cache;
- suporte a mirror/proxy, nao apenas hosting local;
- facilidade de backup e HA;
- suporte a bloqueio por policy;
- facilidade de operar em incidente.

Perguntas que a solucao precisa responder:

- consigo saber quem baixou um pacote especifico?
- consigo bloquear uma versao em minutos?
- consigo aplicar cooldown?
- consigo distinguir publico de privado?
- consigo espelhar artefatos com baixa latencia?
- consigo exportar logs para SIEM?

## 7. Como implantar

### Fase 1: desenho

Defina:

- quais ecossistemas entram primeiro;
- quem opera o proxy;
- onde ficam credenciais;
- como a equipe vai autenticar;
- como sera o backup;
- qual sera o hostname por ecossistema.

Exemplo de naming:

- `npm-proxy.corp.example`
- `pypi-proxy.corp.example`
- `cargo-proxy.corp.example`
- `go-proxy.corp.example`

### Fase 2: rede e identidade

Defina:

- DNS interno;
- certificados TLS validos;
- firewall permitindo apenas saida necessaria;
- segmentacao de rede;
- autenticacao por token, mTLS, SSO ou credencial de servico.

### Fase 3: bootstrap do proxy

Cada proxy deve subir com:

- storage persistente;
- politicas de retencao;
- logs estruturados;
- health checks;
- monitoracao de disco;
- monitoracao de latencia;
- backup;
- restauracao testada.

### Fase 4: policy de bloqueio

Defina no minimo:

- allowlist de registries upstream;
- denylist de pacotes;
- denylist de publishers comprometidos quando aplicavel;
- cooldown padrao;
- regras especiais para incidentes;
- modo de emergencia para bloquear categoria inteira.

### Fase 5: rollout cliente

Ordem recomendada:

1. habilitar `soft` no endpoint;
2. medir uso real de package managers;
3. subir proxy e validar manualmente;
4. apontar grupo piloto para o proxy;
5. comparar sucesso/falha/logs;
6. ativar `hard` gradualmente;
7. bloquear egress direta onde necessario.

## 8. Configurando o `Supply Gate` para usar os proxies

Edite [policy/default-policy.conf](/Users/jpcbl/petuti-code/supply-gate/policy/default-policy.conf):

```sh
DEFAULT_MODE="hard"

NPM_REGISTRY_URL="https://npm-proxy.corp.example/"
PYTHON_INDEX_URL="https://pypi-proxy.corp.example/simple/"
CARGO_REGISTRY_URL="sparse+https://cargo-proxy.corp.example/"
GO_PROXY_URL="https://go-proxy.corp.example/"
GO_SUMDB="sum.golang.org"
GO_PRIVATE_PATTERNS="github.com/sua-org/*"
GO_NO_SUMDB_PATTERNS="github.com/sua-org/*"
GO_VCS_RULES="public:off,private:git|ssh"
```

Depois aplique:

```sh
./install.sh apply --mode hard
```

Valide:

```sh
./install.sh audit
```

## 9. O que bloquear na rede

Se quiser enforcement realmente forte, o endpoint nao deve depender apenas de config local.

Recomendacao:

- permitir saida para os proxies corporativos;
- negar saida direta para registries publicos quando operacionalmente viavel;
- negar saida direta para hosts de download de artefatos publicos usados pelos ecossistemas protegidos;
- registrar tentativas de acesso direto como sinal de bypass.

Exemplos de alvos a considerar no desenho:

- registries publicos;
- hosts de download de tarballs/wheels/crates;
- endpoints de metadata/mod index;
- hosts git publicos usados por fallback indevido.

Nao faca bloqueio cego sem fase de observacao. Primeiro meca o trafego real.

## 10. Logging do proxy

O proxy precisa registrar no minimo:

- timestamp;
- usuario ou token;
- IP de origem;
- hostname quando houver esse contexto;
- pacote;
- versao;
- resultado;
- upstream usado;
- cache hit/miss;
- motivo de bloqueio;
- correlacao com incidente/policy version quando aplicavel.

Idealmente os logs devem ser:

- estruturados;
- centralizados;
- imutaveis ou protegidos contra alteracao;
- exportados para SIEM;
- retidos conforme a exigencia interna.

## 11. Integracao com FleetDM

FleetDM nao substitui o proxy. Ele valida se o endpoint esta obedecendo a policy.

Use Fleet para verificar:

- se o host esta em `soft` ou `hard`;
- se os arquivos de config apontam para os proxies corretos;
- se os wrappers ainda existem;
- se houve drift;
- se o processo real esta sendo executado fora do shim;
- se a trilha local de log continua sendo gerada.

Combinacao recomendada:

- proxy responde "quem tentou baixar";
- Fleet responde "qual maquina deveria estar obedecendo";
- logs locais respondem "qual comando o wrapper viu".

## 12. Operacao de incidente

Quando um pacote ou versao precisar ser bloqueado:

1. bloqueie no proxy;
2. marque no SIEM/alerta;
3. rode busca por downloads recentes;
4. identifique hosts afetados;
5. execute auditoria local ou coleta adicional;
6. gire credenciais se houver suspeita de execucao maliciosa;
7. documente a excecao e o tempo de bloqueio.

## 13. Riscos operacionais

Os principais riscos de operar proxies internos sao:

- ponto unico de falha;
- disco enchendo por cache;
- certificados expirados;
- latencia excessiva;
- fallback indevido para internet publica;
- mirror desatualizado;
- policy frouxa demais;
- logs insuficientes para investigacao.

Mitigacoes:

- HA ou plano claro de contingencia;
- monitoracao de storage;
- observabilidade completa;
- teste de restore;
- teste de bloqueio;
- revisao periodica de exceptions;
- exercicios de incidente.

## 14. Estrategia recomendada de adocao

### Etapa 1

- ligar `Supply Gate` em `soft`;
- coletar inventario real de uso.

### Etapa 2

- implantar proxy para `npm` e Python primeiro;
- validar fluxo de times piloto.

### Etapa 3

- adicionar `go` e `cargo`;
- fechar fallback para upstream publico.

### Etapa 4

- migrar maquinas criticas para `hard`;
- cruzar compliance local com FleetDM.

## 15. Checklist minimo para entrar em producao

- TLS valido;
- backup testado;
- logs exportados;
- cooldown definido;
- denylist operacional;
- runbook de incidente;
- health checks;
- monitoracao de disco;
- autenticacao definida;
- rollout piloto concluido;
- `install.sh audit` passando nas maquinas alvo;
- Fleet conseguindo distinguir compliant de non-compliant.
