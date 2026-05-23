# Docker Compose stack

Esta pasta contem os artefatos locais para subir a stack prescritiva com Docker Compose.

## Componentes

- `nginx`: reverse proxy unico de entrada
- `verdaccio`: proxy/registry para Node
- `devpi`: proxy/index para Python
- `athens`: proxy para modulos Go
- `kellnr`: registry/proxy para Cargo

## Bootstrap

1. Copie `.env.example` para `.env`.
2. Ajuste os hostnames e imagens.
3. Suba a stack:

```sh
docker compose up -d --build
```

4. Confira o estado:

```sh
docker compose ps
docker compose logs -f nginx verdaccio devpi athens kellnr
```

## Teste local

Para testar sem DNS corporativo, adicione entradas temporarias no `/etc/hosts` apontando para `127.0.0.1`:

```text
127.0.0.1 npm-proxy.corp.example
127.0.0.1 pypi-proxy.corp.example
127.0.0.1 go-proxy.corp.example
127.0.0.1 cargo-proxy.corp.example
```

Depois acesse via `http://<hostname>:8080` somente para bootstrap local.

## Importante

- Esta stack usa HTTP no Nginx para facilitar bootstrap local.
- Para producao, troque para TLS interno e controle de autenticacao.
- O `Athens` e o `Kellnr` usam configuracao minima operacional; revise autenticacao, backup e persistencia antes de rollout real.
