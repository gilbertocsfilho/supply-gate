# GUIA CONSOLIDADO FINAL E COMPLETO PARA PROTECAO CONTRA ATAQUES DE SUPPLY CHAIN NO NPM (E ECOSSISTEMAS SEMELHANTES)

Este e o guia definitivo, com 100% das informacoes dos 4 posts originais + tudo relevante do artigo da Snyk sobre o ataque TanStack (Mini Shai-Hulud, maio 2026) + integracao completa da ferramenta DataDog Supply-Chain Firewall (SCFW).

Nada foi perdido. Tudo foi somado e organizado para maxima completude e praticidade.

## 1. Entendendo o Ataque TanStack (Mini Shai-Hulud - Maio 2026)

**O que aconteceu:** Entre 19:20-19:26 UTC de 11 de maio 2026, 84 versoes maliciosas de 42 pacotes `@tanstack/*` foram publicados via pipeline legitima da TanStack (usando OIDC trusted publisher e SLSA Build Level 3 provenance valido).

**Vetor principal:** Hijack de GitHub Actions via `pull_request_target` + cache poisoning + extracao de OIDC token da memoria do runner.

**Payload (`router_init.js` ~2.3 MB, obfuscado em 3 camadas):**
- Injetado via `optionalDependencies: {"@tanstack/setup": "github:tanstack/router#..."}` + script `prepare`.
- Daemoniza, varre credenciais (GitHub, AWS, npm tokens, Vault, K8s, etc.), exfiltra via Session P2P (`.getsession.org`) ou dead-drop commits no GitHub.
- Auto-propaga para outros maintainers (Mistral AI, UiPath, etc.).

**Impacto:** Pacotes com provenance valido + assinatura legitima -> bypassam muitas verificacoes tradicionais.

**Acao imediata se afetado:** Trate a maquina como comprometida. Revogue todas as credenciais acessiveis do host.

**Pacotes TanStack comprometidos (exemplos principais):** `@tanstack/react-router` (`1.169.5`, `1.169.8`), `@tanstack/vue-router`, `@tanstack/solid-router`, `@tanstack/router-core`, etc. (lista completa no `GHSA-g7cv-rxg3-hmpx`).

## 2. Bloqueio de Janela de Ataque (Cooldown de Dependencias) - Mais Eficaz

**npm (`~/.npmrc`):**

```ini
min-release-age=7
minimum-release-age=10080
save-exact=true
```

**Bun (`~/.bunfig.toml`):**

```toml
[install]
minimumReleaseAge = 604800
```

**pnpm v11+:** Ative `blockExoticSubdeps` (padrao) + cooldown.

**npm 11.4+:** Recurso similar (opt-in).

**Python (`uv`/`poetry`/`pip`):** Lockfiles rigorosos + cooldown equivalente.

**Regra de ouro:** Nunca use ranges (`^`, `~`, `>=`) em producao. Sempre versao exata + commit do lockfile.

## 3. Fixacao Rigida de Versoes e Lockfiles

- Remova todo `^` e `~` de `package.json` (`dependencies`, `devDependencies`, `peerDependencies`).
- Sempre commite `package-lock.json` / `pnpm-lock.yaml` / `bun.lock` / `uv.lock` / `poetry.lock`.
- CI/CD: Use `npm ci`, `pnpm install --frozen-lockfile`, `bun install --frozen-lockfile`, `uv sync`, etc.
- Vendorize dependencias criticas quando possivel.

## 4. Protecao no Momento da Instalacao (Install-Time Defense) - Adicao Principal

**DataDog Supply-Chain Firewall (SCFW):** Ferramenta excelente para bloquear instalacoes maliciosas em tempo real.

**Instalacao recomendada:**

```bash
pipx install scfw
scfw configure   # configura wrappers automaticos para npm/pip/etc.
```

**Uso:**

```bash
scfw run npm install pacote
scfw run pip install -r requirements.txt
```

- Verificadores: Malicious packages da DataDog, `OSV.dev`, registry metadata (pacotes muito novos), listas customizadas.
- Bloqueia automaticamente pacotes com achados criticos; avisa em warnings.
- Suporta npm (`>=7`), pip, poetry.
- Logs locais + integracao Datadog para auditoria.
- Ideal para workstations de desenvolvimento.

**Socket Firewall (`sfw` do Socket Security):** Complementar ao SCFW. Configure como wrapper padrao (`npm`/`pnpm`/`yarn`/`pip`/`uv`/`cargo`). Limpe caches antes.

**Bloqueie scripts sempre que possivel:** `--ignore-scripts` ou equivalentes.

## 5. GitHub Actions e CI/CD (Defesas Criticas Contra Hijack)

- Fixe todas as actions em SHA completo de commit (nunca `@vX`).
- Evite `pull_request_target` + cache compartilhado sem trust split rigoroso.
- Permissoes minimas nas workflows.
- Rode em runners sandboxed (evite exfiltracao de secrets).
- Nunca confie em cache de pnpm/npm sem verificacao.

## 6. Monitoramento e Deteccao

- Dependabot alerts (obrigatorio em todos os repos).
- Socket Security ou Snyk (scanning ao vivo + firewall).
- SCFW audit: `scfw audit npm` para checar pacotes instalados.
- Assine feeds oficiais de advisory (`npm`, `PyPI`, `OSV.dev`).
- Siga: `@socketsecurity`, `@snyksec`, `@stepsecurity`.

**Audit semanal/manual:**

```bash
grep -r "postinstall|prepare|preinstall" node_modules/*/package.json | grep -iE "curl|wget|eval|base64|bun run"
```

Verifique lockfiles por `optionalDependencies` suspeitos ou GitHub refs estranhos.

## 7. Credenciais e Segredos

- Nunca commite `.env` (`.gitignore` em todo projeto).
- Tokens com escopo minimo + rotacao a cada 90 dias.
- Separe ambientes (`dev`/`staging`/`prod`).
- `2FA`/`MFA` obrigatorio em GitHub, npm, PyPI, AWS, GCP, etc.
- Nunca cole secrets em LLMs/chats de IA.
- Revogue tudo imediatamente em caso de suspeita.

## 8. IDE e Ambiente Local

- Audite extensoes do VSCode/Cursor todo mes: remova as nao usadas ha 30+ dias.
- Verifique publisher, stars, ultima atualizacao e repo GitHub antes de instalar.
- Use dev containers para isolamento.

## 9. Resposta de Emergencia (se instalou em janela suspeita)

- Revogue todas credenciais de nuvem, GitHub PATs, SSH keys, npm tokens, etc.
- Audite logs de API das ultimas horas.
- Fixe para versoes limpas + reinstale de lockfile limpo.
- Apague histories (`~/.bash_history`, etc.), caches (`~/.npm`, `node_modules`).
- Se rodou como `root`/`sudo` -> nuke total da maquina e restaure so do Git.

## 10. Estrategias Avancadas / Longo Prazo

- Private registry (Verdaccio, GitHub Packages, npm Enterprise) + proxy.
- SBOM + verificacao de hashes/provenance (com atencao: SLSA sozinho nao basta, como visto no TanStack).
- LavaMoat ou sandbox para execucao de codigo.
- Use versoes curadas de distro Linux quando possivel.
- Mindset Go-like: minimize dependencias transitivas + hash pinning.
- Para projetos criticos: review manual de diffs antes de updates.

## 11. Checklist Rapido (Faca Hoje - 30-60 minutos)

- Configure cooldown 7 dias (`npm` + `bun` + `pnpm`).
- Fixe todas as versoes + commite lockfiles.
- Instale e configure SCFW + Socket Firewall.
- Fixe GitHub Actions em SHAs completos.
- Ative Dependabot + Socket/Snyk/SCFW audit.
- `2FA` + rotacao de tokens + `.gitignore` para `.env`.
- Audit de extensoes do IDE.
- Teste `scfw run npm install` em um projeto.

Este guia agora e o mais completo possivel, incorporando todos os detalhes tecnicos do ataque TanStack (incluindo limitacoes do Bun, obfuscation, exfiltracao, etc.) e a protecao proativa do DataDog SCFW como camada essencial de install-time defense.

Se quiser o guia em formato Markdown pronto para salvar como arquivo, comandos exatos personalizados, ou expansao em alguma secao (ex: configuracao completa do SCFW), e so pedir.

Mantenha-se seguro.

## 12. Modos de Enforcamento: Soft vs Hard

O baseline da ferramenta deve operar em um de dois modos formais:

### Modo Soft

- Wrappers obrigatorios para todos os gerenciadores detectados.
- Lockfiles, versoes fixas, cooldown e auditoria local obrigatorios.
- CLIs de IA (`claude`, `gemini`, `codex`) devem rodar via wrapper e jail.
- Nao exige proxy corporativo central.
- Adequado para adocao inicial ou ambientes sem infraestrutura central.

### Modo Hard

- Tudo do modo soft.
- Proxy/registry corporativo obrigatorio para todos os ecossistemas suportados.
- Falha fechada se `npm`, `go`, `cargo`, `pip` ou similares apontarem para upstream publico sem autorizacao.
- Auditoria deve provar que a origem efetiva das dependencias esta controlada.

## 13. O Que os Proxies Protegem

Proxies/registries corporativos protegem principalmente:

- **Origem controlada:** reduzem fetch direto de registries publicos e VCS arbitrario.
- **Bloqueio pre-download:** permitem negar versoes recem-publicadas, pacotes maliciosos ou fora de policy antes da instalacao.
- **Rastreabilidade:** registram quem baixou o que, quando, de onde e com qual versao.
- **Consistencia:** garantem a mesma policy entre maquinas e times.
- **Resposta a incidentes:** aceleram buscas por blast radius e rollback.

Importante: proxy sozinho nao substitui lockfiles, checksums, sandbox, least privilege nem auditoria local.

## 14. Regras por Ecossistema

### Node (`npm`, `pnpm`, `yarn`, `bun`)

- `save-exact=true` e cooldown obrigatorios.
- Install/update apenas via wrapper oficial.
- `--ignore-scripts` deve ser usado por padrao em fluxos automatizados quando isso nao quebrar o caso de uso esperado.
- Em modo hard, `registry` deve apontar para o mirror corporativo.

### Python (`pip`, `uv`, `poetry`)

- Lockfiles obrigatorios sempre que o ecossistema suportar.
- Index corporativo obrigatorio em modo hard.
- Install/update apenas via wrapper oficial.

### Rust (`cargo`)

- `Cargo.lock` obrigatorio em projetos aplicaveis.
- `cargo add` e `cargo install` apenas via wrapper oficial.
- Em modo hard, `source replacement` ou registry corporativo obrigatorio.
- Para projetos criticos, preferir `cargo vendor`.

### Go (`go`)

- `go install`, `go get` e `go mod download` apenas via wrapper oficial.
- `GOPROXY`, `GOSUMDB`, `GOPRIVATE`, `GONOSUMDB` e `GOVCS` devem ser definidos explicitamente.
- Em modo hard, `GOPROXY` deve apontar para proxy corporativo.

## 15. Wrappers Obrigatorios

- Alias de shell nao bastam como controle principal.
- O mecanismo recomendado e precedencia de `PATH` com binarios shim.
- O binario real nao deve ser chamado diretamente; isso e bypass e conta como nao-compliance.
- Cada wrapper deve validar policy, ambiente, backend de jail e integridade basica antes de delegar ao binario real.

## 16. Logging e Evidencia de Compliance

Toda execucao de install, update, audit ou CLI protegida deve:

- Escrever simultaneamente em `STDOUT` e em arquivo persistente.
- Gerar log por rodada em diretorio padrao.
- Adicionar evento em log agregado `JSONL`.
- Registrar no minimo:
  - timestamp de inicio e fim;
  - usuario local;
  - hostname;
  - comando solicitado;
  - comando real executado;
  - gerenciador/CLI envolvido;
  - modo da policy (`soft` ou `hard`);
  - versao da policy;
  - backend de jail;
  - proxy/registry esperado e efetivo;
  - resultado final e exit code.

Ausencia de evidencia valida deve ser tratada como nao-compliance.

## 17. FleetDM / osquery

Para auditoria continua:

- Verifique existencia e hash dos wrappers.
- Verifique se o `PATH` prioriza o diretorio shim.
- Verifique arquivos de config gerenciados (`.npmrc`, `.bunfig.toml`, `.cargo/config.toml`, `pip.conf`, perfis shell, etc.).
- Detecte drift em policy, profiles, logs e attestation local.
- Detecte execucao direta de binarios reais fora do wrapper sempre que houver telemetria de processo disponivel.

## 18. Inventario e Incident Response com Bumblebee

Esta stack nao deve confundir duas capacidades diferentes:

- **prevencao/enforcement**
- **inventario/exposure hunting**

O `Supply Gate` pertence ao primeiro grupo. Um scanner endpoint-side read-only como `perplexityai/bumblebee` pertence ao segundo.

### Encaixe correto

Use `bumblebee` como camada complementar de visibilidade para:

- varredura periodica de workstations Linux/macOS;
- campanhas de incidente;
- localizacao de pacote comprometido ja presente no host;
- inventario de extensoes de editor, extensoes de browser e configs MCP JSON.

Nao use `bumblebee` como substituto de:

- wrappers;
- proxy interno;
- jail;
- telemetria de processo;
- auditoria de compliance deste repositorio.

### Stack por camada

1. `Supply Gate` para prevencao local.
2. proxies internos para controle de origem.
3. `FleetDM`/`osquery` para drift e bypass.
4. `bumblebee` para inventario e exposure scan no endpoint.

### Divisao pratica de responsabilidades

- `Supply Gate` responde: "este comando pode rodar agora, sob qual policy, com qual proxy e com qual trilha de auditoria?"
- proxies respondem: "de onde a dependencia veio e quem baixou?"
- `FleetDM`/`osquery` respondem: "houve drift, bypass ou alteracao persistente observavel?"
- `bumblebee` responde: "onde este pacote, extensao ou configuracao comprometida existe no disco agora?"

### Modelo operacional recomendado

- `baseline` diario para inventario leve;
- `project` para roots conhecidos de desenvolvimento;
- `deep` apenas para incidente ou campanha de exposure hunting;
- saida preferencial em `NDJSON` ou `POST` HTTP para relay interno;
- correlacao com `events.jsonl`, logs de proxy e sinais de bypass no `FleetDM`/`osquery`.

### Limites importantes desta recomendacao

Esta recomendacao assume uma avaliacao feita em 23 de maio de 2026, considerando o estado do `bumblebee` `v0.1.1`, liberado em 22 de maio de 2026.

- cobertura esperada para Linux/macOS, nao Windows;
- projeto ainda novo nesta avaliacao;
- sem spool/queue local;
- o modo `deep` nao deve alimentar inventario permanente de "current state";
- cobertura MCP parcial para `codex`, porque `config.toml` nao entra nessa avaliacao inicial.

### Regras de integracao

- Nao torne `bumblebee` dependencia obrigatoria do instalador.
- Nao acople `apply`, `audit` ou `repair` a presenca dele.
- Nao mova o centro deste projeto para agregacao de scanners externos.

## 19. Matriz de Cobertura

| Camada | Cobre bem | Nao cobre sozinha |
| --- | --- | --- |
| Wrappers + policy local | enforcement, PATH, jail, lock discipline, auditoria local | inventario profundo de estado ja presente no disco |
| Proxies internos | origem, cache, cooldown central, bloqueio pre-download, rastreabilidade | bypass fora do fluxo gerenciado, execucao pos-download |
| `FleetDM` / `osquery` | drift, hash, presence checks, alguns sinais de bypass | bloqueio inline e hunting de exposicao sem modelagem previa |
| `bumblebee` | inventario read-only, extensoes, configs MCP JSON, exposure scan local | enforcement, proxy, correcao de drift, observacao de processo em tempo real |
