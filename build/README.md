# Build: pacotes nativos (.deb / .pkg + .dmg)

Empacota o supply-gate como instalador nativo por SO, em vez de distribuir o
checkout do repo direto. Isso dá versionamento real (o pacote carrega uma
versão, `dpkg`/`installer` sabem o que está instalado) e permite que o
KACE (ou qualquer ferramenta de deploy) rode só `dpkg -i` / `installer -pkg`
sem precisar clonar o repo em cada máquina.

Windows não tem pacote aqui ainda -- ver `docs/` ou a conversa de instalação
Windows para o estado disso.

## Versionamento

Fonte única: o arquivo [`VERSION`](../VERSION) na raiz do repo (formato
`MAJOR.MINOR.PATCH`, sem `v` na frente). Os dois build scripts leem esse
arquivo e usam o valor como versão do pacote gerado -- não precisa editar
`control.in` nem os scripts do macOS para lançar uma versão nova, só o
`VERSION`.

Isso é **independente** do `POLICY_VERSION` em
`policy/default-policy.conf` -- aquele é a versão do *schema* de policy
(usado no log JSONL para auditoria), não a versão de release do pacote. Os
dois podem coincidir por convenção, mas não precisam.

Para lançar uma versão nova:

```sh
echo "0.2.0" > VERSION
git commit -am "release: 0.2.0"
git tag v0.2.0
./build/deb/build-deb.sh          # gera build/deb/dist/supply-gate_0.2.0_all.deb
./build/macos/build-macos-pkg.sh  # (rodar num Mac) gera build/macos/dist/supply-gate-0.2.0.{pkg,dmg}
```

## O que vai dentro do pacote

Ambos os build scripts empacotam a mesma lista de itens (payload de
produção, não o repo inteiro):

```
install.sh  lib/  shims/  scripts/  policy/  README.md  GUIDE.md  VERSION
```

Ficam de fora, de propósito: `tests/`, `docker/`, `fleet/`, `compose.yaml`,
`.env.example` (material de desenvolvimento/referência, sem uso numa
estação gerenciada) e `policy/local-policy.conf` (nunca deve ir num
pacote versionado/reutilizável -- é específico de máquina/site: URL de
registry, launcher do AI Jail, etc.). O pacote base carrega só
`policy/default-policy.conf`. Ver "Config local (AI Jail, registries)"
abaixo para como entregar o local-policy separadamente.

## Linux: `.deb`

Roda em qualquer máquina com `dpkg-deb` (toda base Debian/Ubuntu já tem,
sem precisar instalar nada a mais):

```sh
./build/deb/build-deb.sh
```

Gera `build/deb/dist/supply-gate_<VERSION>_all.deb`. O `postinst` roda
`install.sh apply --scope machine` sozinho assim que o pacote é instalado:

```sh
sudo dpkg -i build/deb/dist/supply-gate_0.1.0_all.deb
```

Por padrão aplica em modo `soft`. Pra aplicar em `hard` direto na instalação:

```sh
sudo SUPPLY_GATE_MODE=hard dpkg -i build/deb/dist/supply-gate_0.1.0_all.deb
```

Desinstalar remove os shims, os blocos de PATH/profile e o `STATE_ROOT`
(`/opt/supply-gate`) via `prerm`, chamando `install.sh uninstall --scope
machine`:

```sh
sudo dpkg -r supply-gate      # remove
sudo dpkg -P supply-gate      # purge (mesma coisa aqui -- não há conffiles)
```

## macOS: `.pkg` + `.dmg`

**Só roda num Mac de verdade** (ou runner macOS de CI, ex.: GitHub Actions
`macos-latest`) -- `pkgbuild`, `productbuild` e `hdiutil` são ferramentas do
Xcode Command Line Tools, sem equivalente fora do Darwin. Não existe forma
de gerar um `.pkg` real a partir de Linux; o script recusa rodar fora do
macOS com um erro claro em vez de produzir algo quebrado.

```sh
xcode-select --install   # se ainda não tiver as Command Line Tools
./build/macos/build-macos-pkg.sh
```

Gera `build/macos/dist/supply-gate-<VERSION>.pkg` (instalador) e o `.dmg`
que o contém, pra distribuição drag-and-drop. O `postinstall` do pacote roda
`install.sh apply --scope machine` (respeitando `SUPPLY_GATE_MODE`, igual ao
`.deb`) assim que instalado:

```sh
sudo installer -pkg build/macos/dist/supply-gate-0.1.0.pkg -target /
```

**Limitação real do formato `.pkg`**: ao contrário do `.deb`, o macOS não tem
um mecanismo nativo de desinstalação a partir do recibo do pacote. Pra
remover, rode manualmente (ou via Jamf/MDM):

```sh
sudo /usr/local/share/supply-gate/install.sh uninstall --scope machine
```

**Assinatura/notarização**: este script gera um pacote **não assinado**. Para
distribuir via Jamf/MDM numa frota gerenciada sem aviso do Gatekeeper, é
necessário assinar com um "Developer ID Installer" certificate
(`pkgbuild --sign "Developer ID Installer: ..."`) e notarizar via
`xcrun notarytool`. Isso depende de uma conta Apple Developer da empresa --
fora do escopo deste script; ver a documentação da Apple sobre notarização
antes do primeiro rollout real.

## Config local (AI Jail, registries de hard mode)

O pacote base só carrega `policy/default-policy.conf` -- os placeholders. Pra
uma máquina real (ex.: com AI Jail configurado, ou em modo hard com registry
interno), entregue um `local-policy.conf` separadamente, escrito em
`/usr/share/supply-gate/policy/local-policy.conf` (Linux) ou
`/usr/local/share/supply-gate/policy/local-policy.conf` (macOS) **antes**
de instalar o pacote (ou antes de rodar `apply` de novo) -- veja
`policy/local-policy.example.conf` pro formato. No KACE, isso pode ser um
segundo item simples: "copiar arquivo" antes de rodar o `dpkg -i`/`installer`.
