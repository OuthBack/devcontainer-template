# Devcontainer — rede do host

Este devcontainer roda com `--network=host`: ele **compartilha o namespace de
rede da máquina**. Não há `forwardPorts`, `appPort`, nem túnel reverso — um
serviço que escuta em `:3000` dentro do container já está em `localhost:3000`
no host, porque é literalmente o mesmo socket.

```
container (namespace de rede do host)      host
┌──────────────────────────┐               ┌──────────────────────────┐
│ app escutando :3000      │ ============= │ localhost:3000           │
│ localhost:5432  ─────────┼──────────────▶│ postgres (bridge, publish)│
└──────────────────────────┘               └──────────────────────────┘
```

## Consequência que mais causa erro

**Nome de container não resolve mais.** O devcontainer saiu da rede
`ms-infrastructure_default`, então `postgres`, `mysql`, `infra-redis` e
`dynamodb` deixaram de ser hostnames válidos. A infra continua em bridge
publicando portas no host, então o endereço correto é sempre `localhost`:

| Serviço | Endereço de dentro do container |
|---|---|
| PostgreSQL | `localhost:5432` |
| MySQL (wedding) | `localhost:3306` |
| Redis | `localhost:6379` |
| DynamoDB local | `http://localhost:8000` |
| DynamoDB admin | `http://localhost:8001` |
| pgAdmin | `http://localhost:5050` |
| RedisInsight | `http://localhost:5540` |

Ao migrar um repo, corrija o `.env` **antes** do rebuild: `DB_HOST`,
`REDIS_HOST` e `DYNAMODB_ENDPOINT` passam a apontar para `localhost`. IPs
fixos da rede Docker (`172.19.0.x`) também precisam sair.

## Portas: colisão é o novo modo de falha

Todos os devcontainers dividem o mesmo espaço de portas do host. Dois repos
tentando subir em `3000` colidem de verdade — o segundo recebe `EADDRINUSE`.

```bash
whoport 3000     # no host: quem está na porta, de qual projeto
whoport          # tabela completa, agrupada por dono
whoport -c bff   # todas as portas de um projeto
```

O mapa de portas reservadas por repo fica em
`~/.claude/skills/devcontainer-local/ports.md` (local da máquina, não
versionado aqui).

De **dentro** do container, `ss -ltn` mostra que a porta está ocupada, mas não
quem é o dono: o PID pertence a outro namespace. Nesse caso, rode `whoport` no
host.

## Segurança

`--network=host` remove o isolamento de rede do container: os processos bindam
portas do host diretamente, enxergam serviços do host em `localhost` (inclusive
o `sshd` em `:22`) e alcançam a LAN sem tradução. É um trade-off aceito
conscientemente para máquina de desenvolvimento.

O mount `~/.ssh → /tmp/host-ssh` é **readonly**, e o `install.sh` copia de lá
apenas `id_ed25519`, `id_ed25519.pub` e `known_hosts` — nunca o diretório
inteiro.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `devcontainer.json` | Imagem, mounts, features, `runArgs` |
| `install.sh` | Provisionamento do container (roda no `postCreateCommand`) |
| `postcreate.log` | Saída do `install.sh`, append por rebuild (ignorado pelo git) |

## Skill para agentes

A operação deste container por agentes (dos dois lados: host e dentro) está em
`~/.claude/skills/devcontainer-local/`, fora deste repositório — ela descreve a
máquina, não o template.

## Este diretório é um repositório próprio

`OuthBack/devcontainer-template`, branch `nodejs`, compartilhado por vários
projetos. Commit aqui **não** é commit do projeto. Para levar a mudança a outro
repo: corrija o `.env` dele, `git -C .devcontainer pull`, rebuild.
