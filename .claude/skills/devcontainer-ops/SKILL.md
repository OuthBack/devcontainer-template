---
name: devcontainer-ops
description: >-
  Como operar o devcontainer deste repositório a partir do host: achar o
  container do projeto pelo label, mapear caminhos host↔container, executar
  comandos sem perder o PATH, escrever arquivos sem criar lixo root:root,
  testar portas que chegam ao host pelo túnel reverso, falar com os serviços
  vizinhos da rede Docker e ler os logs certos. Use quando a sessão rodar no
  host e precisar rodar, testar ou depurar algo dentro do container — "roda
  isso no container", "docker exec", "a porta não responde no host", "o
  serviço do devcontainer", "instalar algo no container".
---

# Operar o devcontainer a partir do host

Esta skill é para a sessão que roda **no host** e precisa agir dentro do devcontainer.
O túnel SSH reverso tem documentação própria em [`../../../README.md`](../../../README.md) —
consulte-a para configuração do host, segurança e troubleshooting do túnel; aqui fica só o que
um agente precisa para operar.

## Regra dura: no host, só leitura

**Nunca edite, crie, mova ou apague nada no host.** Toda escrita acontece dentro do container, via
`docker exec`. No host você pode apenas ler e inspecionar: `cat`, `ls`, `grep`, `git log/diff/status`,
`docker ps/inspect/logs`.

Vale para arquivos do projeto, arquivos de configuração, logs e qualquer coisa fora do repositório.
Inclui as ferramentas de edição do harness (Write/Edit) e redirecionamentos de shell (`>`, `>>`,
`sed -i`, `tee`, `rm`, `mv`, `mkdir`) apontando para caminhos do host.

Se algo precisa mudar e você não consegue fazê-lo de dentro do container, **pare e peça ao
usuário** — não contorne pelo host.

## Quando não usar

Se a sessão já está **dentro** do container, não há `docker exec` nenhum a fazer: rode os comandos
direto. Para saber de que lado você está:

```bash
[ -n "$REMOTE_CONTAINERS" ] || grep -qE 'docker|container|lxc' /proc/1/cgroup && echo "dentro" || echo "host"
```

## 1. Achar o container do projeto

Os nomes são aleatórios (`affectionate_brown`); o endereço estável é o label que o Dev Containers
grava com a pasta aberta no host:

```bash
D=$PWD; CID=""; ROOT=""
while [ "$D" != "/" ]; do
  CID=$(docker ps -q --filter "label=devcontainer.local_folder=$D")
  [ -n "$CID" ] && { ROOT=$D; break; }
  D=$(dirname "$D")
done
echo "container=$CID root=$ROOT"
```

Sobe de `$PWD` até achar a pasta que foi aberta no VS Code. Não use
`git rev-parse --show-toplevel` para isso: `.devcontainer/` é um repo próprio, então de dentro dele
o toplevel não é a raiz do projeto e o label nunca casa.

- Vazio e `docker ps -a` mostra o container parado, ou não existe nenhum: **pare e pergunte**.
  Subir, recriar ou rebuildar container é decisão do usuário, não sua.
- Mais de um id: há containers duplicados do mesmo projeto; pergunte qual usar.

## 2. Mapa host ↔ container

| Host | Container |
|---|---|
| `$ROOT` (raiz do repo) | `/workspaces/$(basename $ROOT)` |
| `~/.ssh` | `/tmp/host-ssh` (readonly) |
| `~/.gitconfig` | `/root/.gitconfig` |

O usuário dentro do container é **root**. O workspace é bind mount: o que muda de um lado muda do
outro na hora.

## 3. Executar comandos

```bash
docker exec -w "/workspaces/$(basename $ROOT)" "$CID" zsh -ic '<comando>'
```

- **Use `zsh -ic`.** `zsh -lc` e `sh -c` não leem o `.zshrc` e perdem o `PATH` montado no
  `install.sh`: sem eles, `claude`, `nvim` e tudo em `/root/.local/bin` somem.
- **Não use `-it`.** A sessão não tem TTY; comandos interativos travam.
- Comando longo (servidor, watcher): rode em background pelo host
  (`docker exec -d`) ou pelo harness, nunca em primeiro plano bloqueando a sessão.

## 4. Escrever arquivos

Toda escrita é feita **de dentro do container** (ver a regra dura acima). O workspace é bind mount,
então o resultado aparece no host na mesma hora — sem você escrever no host.

```bash
# conteúdo novo ou reescrita: heredoc sem expansão
docker exec -i "$CID" zsh -c 'cat > /workspaces/<repo>/<arquivo>' <<'EOF'
...
EOF

# edição pontual
docker exec -w "/workspaces/<repo>" "$CID" zsh -ic "sed -i 's/antigo/novo/' <arquivo>"
```

Consequência a assumir: arquivo escrito assim nasce `root:root` no host, e o usuário do host pode
não conseguir nem truncá-lo depois (foi o caso de `.devcontainer/postcreate.log`). Se isso atrapalhar
o usuário, ajuste a posse **de dentro** (`chown`) — o arquivo e a decisão são dele.

## 5. Portas e rede

Nada de `forwardPorts`/`appPort`: o `port-watch-ssh.sh` detecta qualquer porta em LISTEN no
container e abre o túnel reverso em até ~2 s. Então o teste do host é direto:

```bash
docker exec -d "$CID" zsh -ic 'cd /workspaces/<repo> && npm run dev'
sleep 5 && curl -sS localhost:3000     # do host
```

Só portas que escutam em `0.0.0.0`, `127.0.0.1`, `::` ou `::1` são tuneladas — serviço preso ao IP
do container não aparece no host.

Se o `curl` do host falhar, **confira antes de tudo se o watcher está no ar**
(`docker exec "$CID" pgrep -af port-watch-ssh.sh`): ele morre junto com o `postStartCommand` em
alguns starts, e sem watcher nenhuma porta é tunelada. Confirme primeiro que a porta está em LISTEN
dentro do container (`docker exec "$CID" ss -ltn`) para separar "o serviço não subiu" de "o túnel
não existe". Religar o watcher é mudança de estado do container: proponha ao usuário o comando do
`README.md` ("Operação manual") em vez de executá-lo por conta própria.

Serviços vizinhos da rede `ms-infrastructure_default` são alcançáveis **pelo nome do container**
de dentro do devcontainer (`postgres`, `wedding-platform-mysql`, `infra-redis`, `infra-dynamodb`),
e os devcontainers dos outros repositórios estão na mesma rede. Confira o que está de pé com
`docker ps` antes de supor que um serviço existe.

## 6. Git e SSH

A chave `/root/.ssh/id_ed25519` **tem passphrase** e é carregada sob demanda pelo alias `sshkey`,
que exige um humano digitando — você não vai conseguir fazê-lo por `docker exec`. Logo:

- `git fetch/push` por SSH de dentro do container só funciona se o usuário já tiver rodado `sshkey`
  naquele container. Cheque com `docker exec "$CID" zsh -ic 'ssh-add -l'` antes de tentar.
- Para operação remota sem depender disso, use HTTPS com o `GITHUB_TOKEN` que o `containerEnv`
  injeta. **Nunca** imprima, ecoe ou logue o valor do token, nem o embuta numa URL que vá para o
  log ou para o `git remote`.
- Git que **lê** (status, diff, log) pode rodar dos dois lados. Git que **escreve** (commit, merge,
  checkout, stash) roda dentro do container, como qualquer outra escrita — e, como sempre, só com
  autorização explícita do usuário para aquele commit.

## 7. Diagnóstico

| Arquivo | O que tem |
|---|---|
| `.devcontainer/port-watch-ssh.log` | Vida do watcher de portas, uma linha `--- New Run` por start |
| `/tmp/port-tunnel-ssh/<porta>.log` | Saída do `ssh` de cada túnel — primeiro lugar a olhar quando a porta não responde no host |
| `.devcontainer/postcreate.log` | Saída do `install.sh`. É `root:root` e cresce a cada rebuild; se incomodar, trunque **de dentro** do container |

Watcher no ar? `docker exec "$CID" pgrep -af port-watch-ssh.sh`.
Resto do troubleshooting do túnel: tabela "Problemas comuns" do `README.md`.

## 8. Limites

- **Não rebuilde, recrie nem reinicie o container** por conta própria: derruba os agents, os túneis
  e o estado de trabalho do usuário. Proponha e espere o ok.
- **Mudança durável vai no `install.sh` ou no `devcontainer.json`**, nunca só no `/root/.zshrc` do
  container — o que você escreve lá dentro morre no próximo rebuild. Ao mexer no bloco apendado ao
  `.zshrc`, mantenha o guard do marcador `# >>> devcontainer zshrc >>>` para o append continuar
  idempotente.
- `.devcontainer/` é um repositório próprio (`OuthBack/devcontainer-template`), com uma branch por
  stack. Commit aqui não é commit do projeto; confirme a branch antes.
