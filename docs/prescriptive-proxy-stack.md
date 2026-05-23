# Implementacao Prescritiva de Proxies Internos

Este documento fecha as escolhas tecnicas para uma implantacao real do modo `hard`.

Em vez de listar varias opcoes, esta versao assume uma stack unica e recomendada:

- `Verdaccio` para `npm`, `pnpm`, `yarn` e `bun`
- `devpi-server` para `pip`, `uv` e `poetry`
- `Athens` para `go`
- `Kellnr` para `cargo`
- `Nginx` na frente de todos os servicos para TLS, autenticacao e logs padronizados

Essa stack e focada em:

- software self-hosted;
- controle central;
- cache/proxy local;
- rollout gradual para `hard mode`.

## 1. Decisao arquitetural

### Layout recomendado

```text
developer machine / CI
  -> Supply Gate wrapper
  -> Nginx reverse proxy corporativo
  -> service-specific proxy
     - Verdaccio
     - devpi-server
     - Athens
     - Kellnr
  -> upstream publico somente pelo proxy
```

### Hostnames recomendados

- `npm-proxy.corp.example`
- `pypi-proxy.corp.example`
- `go-proxy.corp.example`
- `cargo-proxy.corp.example`

### Regras globais

- TLS obrigatorio em todos os endpoints.
- Logs centralizados no reverse proxy e no servico.
- Disco persistente para cache e metadados.
- Backup diario do storage e das configuracoes.
- Acesso direto aos servicos internos negado; apenas via Nginx.
- Autenticacao obrigatoria para escrita.
- Leitura autenticada ou controlada por rede interna.

## 2. Infraestrutura base

### VM/container por servico

Recomendacao minima:

- `2 vCPU` por servico para ambiente pequeno.
- `4-8 GB RAM` para Node/Python proxies.
- `100+ GB` de disco inicial por proxy com crescimento monitorado.

### Volumes persistentes

Cada servico deve ter:

- volume para configuracao;
- volume para storage/cache;
- volume ou export para logs.

### Rede

- Nginx exposto na rede interna ou via load balancer.
- Servicos backend escutando apenas na rede privada.
- Firewall negando acesso publico direto.

## 3. Nginx como camada comum

Nginx faz:

- terminacao TLS;
- cabecalhos padronizados;
- logging central;
- auth basica inicial ou integracao posterior com SSO;
- limite de tamanho de request;
- rate limiting quando fizer sentido.

### Exemplo de bloco base

```nginx
log_format supply_chain '$remote_addr - $remote_user [$time_local] '
                        '"$request" $status $body_bytes_sent '
                        '"$http_referer" "$http_user_agent" '
                        'rt=$request_time ua="$upstream_addr" us="$upstream_status"';

proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
proxy_read_timeout 300;
client_max_body_size 512m;
```

### Exemplo para Verdaccio

```nginx
server {
  listen 443 ssl http2;
  server_name npm-proxy.corp.example;

  access_log /var/log/nginx/npm-proxy.access.log supply_chain;
  error_log /var/log/nginx/npm-proxy.error.log warn;

  ssl_certificate /etc/nginx/tls/fullchain.pem;
  ssl_certificate_key /etc/nginx/tls/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:4873;
  }
}
```

Repita o mesmo padrao para os demais endpoints.

## 4. Verdaccio para Node

Fonte oficial do projeto: `verdaccio.org`.

### Por que Verdaccio

- E o proxy privado self-hosted mais comum do ecossistema Node.
- Suporta uplinks para npm publico.
- Suporta cache local.
- Suporta pacotes privados e scopes.
- E simples de operar.

### Instalar

Exemplo com Node ja instalado no host:

```sh
npm install -g verdaccio
mkdir -p /srv/verdaccio/storage /srv/verdaccio/conf
```

### Configuracao recomendada

Arquivo `/srv/verdaccio/conf/config.yaml`:

```yaml
storage: /srv/verdaccio/storage
auth:
  htpasswd:
    file: /srv/verdaccio/conf/htpasswd

uplinks:
  npmjs:
    url: https://registry.npmjs.org/

packages:
  "@*/*":
    access: $authenticated
    publish: $authenticated
    proxy: npmjs
  "**":
    access: $authenticated
    publish: $authenticated
    proxy: npmjs

server:
  keepAliveTimeout: 60

logs:
  - { type: stdout, format: pretty, level: http }
```

### Systemd unit

Arquivo `/etc/systemd/system/verdaccio.service`:

```ini
[Unit]
Description=Verdaccio
After=network.target

[Service]
User=verdaccio
Group=verdaccio
ExecStart=/usr/bin/verdaccio --config /srv/verdaccio/conf/config.yaml
Restart=always
WorkingDirectory=/srv/verdaccio

[Install]
WantedBy=multi-user.target
```

### Cliente

No `hard mode`, configure:

```ini
registry=https://npm-proxy.corp.example/
save-exact=true
```

E na policy:

```sh
NPM_REGISTRY_URL="https://npm-proxy.corp.example/"
```

### Bloqueios operacionais

Verdaccio por si so nao entrega um motor sofisticado de policy temporal.

Por isso a recomendacao prescritiva e:

- aplicar cooldown no endpoint com `Supply Gate`;
- usar Nginx + listas de bloqueio no perimetro quando necessario;
- manter pacote/versao banidos em processo operacional central.

## 5. devpi-server para Python

Fonte oficial do projeto: `doc.devpi.net`.

### Por que devpi

- Funciona como cache/proxy de PyPI.
- Suporta indices locais.
- E compativel com o fluxo de `pip`.
- E mais alinhado com espelho/proxy do que um servidor de arquivos simples.

### Instalar

```sh
python3 -m venv /opt/devpi
/opt/devpi/bin/pip install -U pip
/opt/devpi/bin/pip install devpi-server devpi-web
mkdir -p /srv/devpi
```

### Inicializar

```sh
/opt/devpi/bin/devpi-init --serverdir /srv/devpi
```

### Systemd unit

Arquivo `/etc/systemd/system/devpi.service`:

```ini
[Unit]
Description=devpi-server
After=network.target

[Service]
User=devpi
Group=devpi
ExecStart=/opt/devpi/bin/devpi-server --serverdir /srv/devpi --host 127.0.0.1 --port 3141
Restart=always

[Install]
WantedBy=multi-user.target
```

### Fluxo inicial

1. Subir o servico.
2. Acessar via Nginx.
3. Criar usuario admin.
4. Criar index espelhando `root/pypi`.
5. Liberar leitura para o grupo desejado.

### Cliente

Arquivo `pip.conf` no `hard mode`:

```ini
[global]
index-url = https://pypi-proxy.corp.example/simple/
disable-pip-version-check = true
```

Na policy:

```sh
PYTHON_INDEX_URL="https://pypi-proxy.corp.example/simple/"
```

### uv e poetry

No rollout prescritivo:

- `uv` deve usar o mesmo source do `pip`;
- `poetry` deve apontar explicitamente para o source corporativo;
- o wrapper continua sendo a ultima barreira de enforcement.

## 6. Athens para Go

Fonte oficial do projeto: `gomods.io` / repositorio `gomods/athens`.

### Por que Athens

- Foi criado especificamente como proxy de modulos Go.
- Fala o protocolo esperado por `GOPROXY`.
- Reduz dependencia de acesso direto a upstream.

### Instalar

Exemplo com binario/container. Em host Linux:

```sh
mkdir -p /srv/athens/storage /srv/athens/config
```

### Configuracao recomendada

Arquivo `/srv/athens/config/config.toml`:

```toml
GoBinaryEnvVars = ["GONOSUMDB=github.com/your-org/*", "GOPRIVATE=github.com/your-org/*"]
ProtocolWorkers = 10
LogLevel = "info"
DownloadMode = "sync"
StorageType = "disk"
GlobalEndpoint = "https://go-proxy.corp.example"

[DiskStorage]
Root = "/srv/athens/storage"
```

### Systemd unit

O detalhe do binario pode variar conforme o metodo de instalacao. Exemplo:

```ini
[Unit]
Description=Athens Go Proxy
After=network.target

[Service]
User=athens
Group=athens
ExecStart=/usr/local/bin/athens-proxy -config_file /srv/athens/config/config.toml
Restart=always

[Install]
WantedBy=multi-user.target
```

### Cliente

No host cliente:

```sh
go env -w GOPROXY=https://go-proxy.corp.example
go env -w GOSUMDB=sum.golang.org
go env -w GOPRIVATE=github.com/your-org/*
go env -w GONOSUMDB=github.com/your-org/*
go env -w GOVCS=public:off,private:git|ssh
```

Na policy:

```sh
GO_PROXY_URL="https://go-proxy.corp.example"
GO_SUMDB="sum.golang.org"
GO_PRIVATE_PATTERNS="github.com/your-org/*"
GO_NO_SUMDB_PATTERNS="github.com/your-org/*"
GO_VCS_RULES="public:off,private:git|ssh"
```

### Regra importante

No modo prescritivo `hard`, nao use `,direct` em `GOPROXY` para modulos publicos.

Isso reabre bypass para a internet.

## 7. Kellnr para Cargo

Fonte oficial do projeto: `kellnr.io`.

### Por que Kellnr

- E uma opcao self-hosted voltada para registries Cargo.
- Suporta uso como registry privado.
- Entrega uma historia mais operacional do que tentar montar um registry Cargo totalmente custom do zero.

### Limitacao importante

O ecossistema Cargo tem uma historia de proxy/mirror mais rigida do que npm ou Go.

Por isso, a versao prescritiva aqui e:

- usar `Kellnr` como registry controlado;
- usar `source replacement` no cliente;
- para projetos criticos, complementar com `cargo vendor`.

### Instalar

A forma exata depende do metodo de deploy escolhido, mas o baseline e:

- rodar `Kellnr` em host ou container interno;
- colocar o endpoint atras do Nginx;
- persistir dados em volume dedicado.

### Cliente

Arquivo `~/.cargo/config.toml`:

```toml
[registries.crates-io]
protocol = "sparse"

[source.crates-io]
replace-with = "corporate"

[source.corporate]
registry = "sparse+https://cargo-proxy.corp.example/"
```

Na policy:

```sh
CARGO_REGISTRY_URL="sparse+https://cargo-proxy.corp.example/"
```

### Regra operacional

Para times de maior criticidade:

- `Cargo.lock` obrigatorio;
- `cargo install` somente para bins aprovados;
- `cargo vendor` em pipelines criticos.

## 8. Integracao com Supply Gate

### Policy recomendada

Edite [policy/default-policy.conf](../policy/default-policy.conf):

```sh
DEFAULT_MODE="hard"

NPM_REGISTRY_URL="https://npm-proxy.corp.example/"
PYTHON_INDEX_URL="https://pypi-proxy.corp.example/simple/"
CARGO_REGISTRY_URL="sparse+https://cargo-proxy.corp.example/"
GO_PROXY_URL="https://go-proxy.corp.example"
GO_SUMDB="sum.golang.org"
GO_PRIVATE_PATTERNS="github.com/your-org/*"
GO_NO_SUMDB_PATTERNS="github.com/your-org/*"
GO_VCS_RULES="public:off,private:git|ssh"
```

Depois:

```sh
./install.sh apply --mode hard
./install.sh audit
```

## 9. Rollout recomendado

### Fase 1

- Subir Nginx e um proxy por ecossistema.
- Validar health checks.
- Validar storage persistente.
- Validar backup.

### Fase 2

- Apontar 3 a 5 maquinas piloto em `soft`.
- Verificar quais package managers estao em uso real.
- Simular mudanca de policy.

### Fase 3

- Trocar policy das maquinas piloto para `hard`.
- Validar install, update, build e CI.
- Acompanhar logs do wrapper e do proxy.

### Fase 4

- Bloquear egress direta para upstream publico onde fizer sentido.
- Ligar FleetDM para drift e bypass detection.
- Expandir rollout por grupos.

## 10. Logs que precisam existir

### No endpoint

- logs do `Supply Gate`;
- attestation local;
- resultado de `audit`.

### No Nginx

- access log por hostname;
- error log;
- IP de origem;
- tempo de resposta;
- upstream de backend.

### No servico especifico

- pacote requisitado;
- versao;
- hit/miss de cache;
- falha de upstream;
- erro de auth.

## 11. O que ainda precisa de decisao sua

Este documento fecha a stack, mas ainda depende de valores da sua empresa:

- dominio interno real;
- modelo de autenticacao;
- onde os servicos vao rodar;
- como os logs vao para SIEM;
- politica de cooldown e blocklist;
- quais modulos Go privados entram em `GOPRIVATE`;
- quais binarios Cargo podem usar `cargo install`.

## 12. Resultado esperado

Ao final dessa implantacao:

- `npm`, `pip`, `go` e `cargo` nao devem resolver pacotes diretamente da internet publica em `hard mode`;
- toda execucao deve gerar trilha local no endpoint;
- todo download deve gerar trilha central no proxy;
- FleetDM deve conseguir provar se a maquina segue compliant.
