# Devcontainer — túneis SSH automáticos para o host

Este devcontainer sobe, a cada start, o script `port-watch-ssh.sh`, que
detecta portas novas escutando dentro do container e abre um túnel SSH
reverso (`ssh -R`) para o host. Resultado: um serviço em `localhost:3000`
no container fica acessível em `localhost:3000` no host, sem declarar
`forwardPorts`/`appPort`.

```
container                                   host (Linux)
┌──────────────────────────┐   ssh -R      ┌──────────────────────────┐
│ app escutando :3000      │ ────────────▶ │ sshd :22                 │
│ port-watch-ssh.sh (poll) │  172.19.0.1   │ localhost:3000 → túnel   │
└──────────────────────────┘               └──────────────────────────┘
```

## Pré-requisitos no host

- Linux com Docker Engine e `openssh-server` (serviço `ssh`) rodando.
- A variável `USER` definida no ambiente em que o VS Code é aberto (é o
  usuário SSH usado pelo túnel, via `${localEnv:USER}`).

## Configuração no host (uma vez)

### 1. Conferir o sshd

```bash
sudo systemctl status ssh
sudo sshd -T | grep -Ei 'allowtcpforwarding|permitlisten|listenaddress'
```

Esperado:

```
listenaddress [::]:22
listenaddress 0.0.0.0:22
allowtcpforwarding yes
permitlisten any
```

- `allowtcpforwarding` precisa ser `yes` ou `remote`.
- `listenaddress` não pode ser só `127.0.0.1` — o container conecta pelo
  gateway da rede Docker.

### 2. Criar a chave dedicada do túnel

A chave fica no `~/.ssh` do host, que já é montado no container em
`/tmp/host-ssh` — por isso sobrevive a rebuilds.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/devcontainer_tunnel -N "" -C devcontainer-tunnel
echo "restrict,port-forwarding $(cat ~/.ssh/devcontainer_tunnel.pub)" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

- **Sem senha** (`-N ""`): o watcher roda em background, sem ninguém para
  digitá-la.
- **`restrict,port-forwarding`**: a chave só abre túneis — não dá shell
  nem executa comandos no host. Se vazar, o estrago fica limitado a isso.
- Não use a chave pessoal (`id_ed25519`): ela tem senha e daria shell
  completo no host.

### 3. Firewall (só se houver ufw/nftables ativo)

O container sai pela bridge da rede `ms-infrastructure_default`, não pela
`docker0`. Descubra a interface e libere a porta 22 nela:

```bash
BR="br-$(docker network inspect ms-infrastructure_default -f '{{.Id}}' | cut -c1-12)"
sudo ufw allow in on "$BR" to any port 22 proto tcp
```

### 4. Rebuild do devcontainer

`containerEnv` só é aplicado no rebuild: **Dev Containers: Rebuild
Container**.

## Verificação (dentro do container)

```bash
# watcher rodando?
pgrep -af port-watch-ssh.sh

# log do watcher (append, uma linha "--- New Run" por start)
cat .devcontainer/port-watch-ssh.log

# teste manual da conexão: deve ficar parado sem erro (Ctrl+C para sair)
ssh -i /tmp/host-ssh/devcontainer_tunnel -o IdentitiesOnly=yes -o BatchMode=yes \
    -N -R 18999:localhost:18999 "$TUNNEL_USER@$(ip route | awk '/default/{print $3; exit}')"
```

Teste ponta a ponta:

```bash
# no container
python3 -m http.server 18780 --bind 127.0.0.1
# no host (em até ~2s)
curl http://localhost:18780
```

## Como funciona

| Comportamento | Detalhe |
|---|---|
| Detecção | Poll em `/proc/net/tcp[6]` a cada `TUNNEL_POLL_INTERVAL` s. |
| Portas consideradas | Só as que escutam em `0.0.0.0`, `127.0.0.1`, `::` ou `::1` (alcançáveis via `localhost`). O DNS embutido do Docker (`127.0.0.11`) e serviços presos ao IP do container são ignorados. |
| Porta fechou | O túnel correspondente é encerrado. |
| Falha do ssh | Backoff por porta: 2s, 4s, 8s… até `TUNNEL_MAX_BACKOFF`. Um túnel que ficou de pé 60s zera o contador. |
| Instância única | `flock` em `/tmp/port-tunnel-ssh/watcher.lock`: um segundo watcher no mesmo container sai sem fazer nada. |
| Onde o túnel escuta no host | Só em `localhost` do host (`GatewayPorts no`, padrão do sshd). Outras máquinas da rede não acessam. |

### Vários containers ao mesmo tempo

Cada túnel abre a porta no `localhost` do host. Se dois containers
escutam na **mesma porta**, o primeiro a conectar fica com ela; o segundo
registra `remote port forwarding failed` no log da porta, entra em
backoff e assume quando o primeiro liberar. Não há quebra, mas não é
determinístico qual container responde em `localhost:<porta>`. O mesmo
vale para portas que o próprio host já usa.

## Variáveis de ambiente

| Variável | Default | Definida em |
|---|---|---|
| `TUNNEL_USER` | `whoami` (no container = `root`) | `containerEnv` → `${localEnv:USER}` |
| `TUNNEL_SSH_OPTS` | vazio | `containerEnv` → chave dedicada + `IdentitiesOnly=yes` |
| `TUNNEL_HOST` | gateway do `ip route` (hoje `172.19.0.1`), fallback `host.docker.internal` | — |
| `TUNNEL_EXCLUDE_PORTS` | `22` | — |
| `TUNNEL_POLL_INTERVAL` | `2` | — |
| `TUNNEL_MAX_BACKOFF` | `300` | — |

## Operação manual

```bash
# parar (SIGTERM derruba todos os túneis)
pkill -TERM -f '^bash .*port-watch-ssh\.sh'

# subir de novo
setsid nohup bash .devcontainer/port-watch-ssh.sh \
  >> .devcontainer/port-watch-ssh.log 2>&1 &
```

| Arquivo | Conteúdo |
|---|---|
| `.devcontainer/port-watch-ssh.log` | Log do watcher (ignorado pelo git). |
| `/tmp/port-tunnel-ssh/<porta>.log` | Saída do `ssh` de cada túnel — primeiro lugar a olhar em falhas. |
| `/tmp/port-tunnel-ssh/<porta>.pid` | PID do `ssh` de cada túnel. |

## Problemas comuns

| Sintoma (em `<porta>.log` ou no log do watcher) | Causa provável | Ação |
|---|---|---|
| `Permission denied (publickey)` | Chave não está no `authorized_keys`, ou permissões erradas em `~/.ssh` | Refazer o passo 2; conferir `chmod 700 ~/.ssh`, `600 authorized_keys` |
| `TUNNEL_USER=root` no log | `USER` vazio no ambiente do VS Code | Trocar `${localEnv:USER}` pelo usuário fixo no `devcontainer.json` |
| `Connection timed out` / `refused` | Firewall ou sshd parado | Passos 1 e 3 |
| `remote port forwarding failed for listen port N` | Porta já ocupada no host (outro container ou serviço do host), ou `N < 1024` sem root | Liberar a porta no host ou mudar a porta do serviço |
| Nenhum túnel abre | Serviço escuta só no IP do container | Fazer o serviço escutar em `0.0.0.0` ou `127.0.0.1` |
| Watcher não está rodando após start | Processo morreu com o fim do `postStartCommand` | Ver `.devcontainer/port-watch-ssh.log`; subir manualmente e reportar |

## Segurança

- O túnel não expõe portas na internet nem na rede local — só no
  `localhost` do host.
- A chave dedicada é limitada a port-forwarding (`restrict,port-forwarding`).
- O mount `~/.ssh → /tmp/host-ssh` é de leitura e escrita: o root do
  container pode alterar o `authorized_keys` do host. Considere
  `readonly=true` nesse mount, já que o `install.sh` só copia de lá.
