#!/usr/bin/env bash
#
# port-watch-ssh.sh
#
# Detecta automaticamente novas portas em LISTEN dentro deste container e
# abre um túnel SSH reverso (ssh -R) para cada uma, encerrando o túnel
# quando a porta correspondente para de escutar.
#
# MECANISMO: polling em /proc/net/tcp e /proc/net/tcp6 a cada
# TUNNEL_POLL_INTERVAL segundos. Não é instantâneo — a latência de
# detecção é, no pior caso, igual ao intervalo de poll.
#
# REQUISITOS NO HOST:
#   - sshd acessível a partir do container (TUNNEL_HOST), com
#     AllowTcpForwarding habilitado.
#   - Chave pública do container já presente no ~/.ssh/authorized_keys
#     do usuário TUNNEL_USER no host.
#
# SEGURANÇA: o túnel fica acessível a qualquer processo que tenha acesso
# ao host/rede de destino via a porta encaminhada — isto NÃO expõe a porta
# publicamente na internet (diferente de ngrok/localtunnel), mas também
# não adiciona autenticação além da conexão SSH em si.
#
# VARIÁVEIS DE AMBIENTE:
#   TUNNEL_HOST           (opcional) host SSH de destino. Se vazio, tenta
#                         detectar via `ip route` (gateway da bridge
#                         Docker) e, falhando isso, usa
#                         "host.docker.internal" como último fallback.
#   TUNNEL_USER           (opcional) usuário SSH no host. Default: whoami.
#   TUNNEL_SSH_OPTS       (opcional) opções extras passadas ao `ssh`
#                         (ex: "-i ~/.ssh/devcontainer_tunnel -p 2222").
#                         Somadas às opções base abaixo, não as substitui.
#   TUNNEL_EXCLUDE_PORTS  (opcional) lista de portas separadas por espaço
#                         a ignorar. Default: "22".
#   TUNNEL_POLL_INTERVAL  (opcional) intervalo de poll em segundos.
#                         Default: 2.
#   TUNNEL_MAX_BACKOFF    (opcional) espera máxima, em segundos, entre
#                         tentativas de reabrir um túnel que falhou.
#                         Default: 300.
#
# PORTAS CONSIDERADAS: apenas as que escutam em 0.0.0.0, 127.0.0.1, :: ou
# ::1 — ou seja, as alcançáveis via "localhost", que é o destino do
# `ssh -R`. Isso exclui o DNS embutido do Docker (127.0.0.11, porta
# aleatória) e serviços presos a um IP específico da interface.
#
# BACKOFF: se o ssh de uma porta morre (auth recusada, porta já ocupada no
# host, etc.), a próxima tentativa espera 2s, 4s, 8s... até
# TUNNEL_MAX_BACKOFF. Um túnel que ficou de pé por TUNNEL_STABLE_AFTER
# segundos zera o contador ao cair.
#
# INSTÂNCIA ÚNICA: um lock (flock) em STATE_DIR impede dois watchers no
# mesmo container; o segundo sai sem fazer nada.
#
# VÁRIOS CONTAINERS: cada `-R` abre a porta no localhost do host. Se dois
# containers escutam na mesma porta, o primeiro a conectar fica com ela; o
# segundo falha com "remote port forwarding failed", entra em backoff e
# assume a porta quando o primeiro a liberar.
#
# Uso:
#   export TUNNEL_HOST=...   # opcional, ver detecção automática acima
#   bash .devcontainer/port-watch-ssh.sh
#
set -u

# --- Resolução de TUNNEL_HOST -----------------------------------------
# Prioridade: valor explícito > detecção via ip route > fallback fixo.
if [ -z "${TUNNEL_HOST:-}" ]; then
  TUNNEL_HOST="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
fi
if [ -z "${TUNNEL_HOST:-}" ]; then
  TUNNEL_HOST="host.docker.internal"
fi

TUNNEL_USER="${TUNNEL_USER:-$(whoami)}"
TUNNEL_SSH_OPTS="${TUNNEL_SSH_OPTS:-}"
TUNNEL_EXCLUDE_PORTS="${TUNNEL_EXCLUDE_PORTS:-22}"
TUNNEL_POLL_INTERVAL="${TUNNEL_POLL_INTERVAL:-2}"
TUNNEL_MAX_BACKOFF="${TUNNEL_MAX_BACKOFF:-300}"
TUNNEL_STABLE_AFTER=60

# Endereços locais (formato hex de /proc/net/tcp[6]) alcançáveis via
# "localhost": 0.0.0.0, 127.0.0.1, :: e ::1.
LOCALHOST_ADDRS="00000000 0100007F 00000000000000000000000000000000 00000000000000000000000001000000"

# Estado de backoff por porta, mantido só em memória.
declare -A fail_count=() next_try=() started_at=()

# Opções base necessárias para rodar em background sem TTY: sem elas, a
# primeira conexão trava esperando confirmação de host key ou prompt de
# senha. Não configuráveis via env — sempre aplicadas, além do que vier
# em TUNNEL_SSH_OPTS.
BASE_SSH_OPTS=(
  -o "StrictHostKeyChecking=accept-new"
  -o "BatchMode=yes"
  -o "ServerAliveInterval=15"
  -o "ExitOnForwardFailure=yes"
)

STATE_DIR="/tmp/port-tunnel-ssh"
mkdir -p "$STATE_DIR"

# Precisa vir antes das traps: uma segunda instância não pode rodar o
# cleanup, senão derrubaria os túneis da primeira.
exec 9>"$STATE_DIR/watcher.lock"
if ! flock -n 9; then
  echo "[port-watch-ssh] outro watcher já está rodando neste container, saindo"
  exit 0
fi

echo "[port-watch-ssh] TUNNEL_HOST=$TUNNEL_HOST TUNNEL_USER=$TUNNEL_USER" \
     "poll=${TUNNEL_POLL_INTERVAL}s exclude=[$TUNNEL_EXCLUDE_PORTS]"

# Confirma que o PID ainda é o ssh do túnel daquela porta, e não outro
# processo que herdou o número — comum após restart do container, quando
# os PIDs recomeçam do 1 e os .pid antigos continuam em /tmp.
tunnel_alive() {
  local pid="$1" port="$2"
  [ -n "$pid" ] || return 1
  tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null \
    | grep -qx -- "${port}:localhost:${port}"
}

# --- Cleanup ao encerrar o watcher -------------------------------------
cleanup() {
  echo "[port-watch-ssh] encerrando, derrubando túneis ativos..."
  for f in "$STATE_DIR"/*.pid; do
    [ -e "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if tunnel_alive "$pid" "$(basename "$f" .pid)"; then
      kill "$pid" 2>/dev/null
    fi
    rm -f "$f"
  done
}
# A trap de EXIT roda "cleanup" sempre que o script termina, seja
# naturalmente ou via `exit`. INT/TERM chamam apenas `exit 0`, que por sua
# vez dispara a trap de EXIT — sem isso, um trap handler para INT/TERM não
# encerra o processo automaticamente em bash, e o `while true` do loop
# principal continuaria rodando mesmo após o cleanup.
trap cleanup EXIT
trap 'exit 0' INT TERM

is_excluded() {
  local port="$1" p
  for p in $TUNNEL_EXCLUDE_PORTS; do
    [ "$p" = "$port" ] && return 0
  done
  return 1
}

# Lê /proc/net/tcp[6] e imprime, uma por linha, as portas locais em
# estado LISTEN (st == 0A) cujo endereço está em LOCALHOST_ADDRS.
#
# NOTA: a conversão hex->decimal é feita em bash ($((16#hex))), não em
# awk, porque `strtonum` é uma extensão do gawk e não existe no awk
# padrão (mawk) presente na maioria das imagens Debian/Ubuntu usadas em
# devcontainers.
listening_ports() {
  local proc_file="$1" hex_port
  [ -r "$proc_file" ] || return 0
  while IFS= read -r hex_port; do
    [ -n "$hex_port" ] && echo "$((16#$hex_port))"
  done < <(
    awk -v addrs="$LOCALHOST_ADDRS" '
      BEGIN { n = split(addrs, t, " "); for (i = 1; i <= n; i++) ok[t[i]] = 1 }
      NR>1 && $4 == "0A" { split($2, a, ":"); if (a[1] in ok) print a[2] }
    ' "$proc_file" 2>/dev/null
  )
}

# --- Loop principal ----------------------------------------------------
while true; do
  current_ports="$(
    { listening_ports /proc/net/tcp; listening_ports /proc/net/tcp6; } \
      | sort -nu
  )"

  # Abrir túneis para portas novas.
  for port in $current_ports; do
    is_excluded "$port" && continue
    pid_file="$STATE_DIR/${port}.pid"
    if [ -e "$pid_file" ]; then
      # Já tem túnel; confirmar que o processo ainda está vivo.
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      if tunnel_alive "$pid" "$port"; then
        continue
      fi
      rm -f "$pid_file"

      # O ssh morreu sozinho: contabilizar a falha e agendar a próxima
      # tentativa com backoff exponencial.
      printf -v now '%(%s)T' -1
      if (( now - ${started_at[$port]:-0} >= TUNNEL_STABLE_AFTER )); then
        fail_count[$port]=0
      fi
      fail_count[$port]=$(( ${fail_count[$port]:-0} + 1 ))
      n=${fail_count[$port]}
      delay=$(( 1 << (n < 20 ? n : 20) ))
      (( delay > TUNNEL_MAX_BACKOFF )) && delay=$TUNNEL_MAX_BACKOFF
      next_try[$port]=$(( now + delay ))
      echo "[port-watch-ssh] túnel da porta $port caiu (falha #$n)," \
           "nova tentativa em ${delay}s — ver $STATE_DIR/${port}.log"
    fi

    printf -v now '%(%s)T' -1
    (( now < ${next_try[$port]:-0} )) && continue

    echo "[port-watch-ssh] porta $port detectada, abrindo túnel para $TUNNEL_HOST"
    # `9>&-`: o ssh não herda o fd do lock; se o watcher morrer com
    # SIGKILL, um ssh órfão não impede um novo watcher de subir.
    # shellcheck disable=SC2086
    nohup ssh -N -R "${port}:localhost:${port}" \
      "${BASE_SSH_OPTS[@]}" $TUNNEL_SSH_OPTS \
      "${TUNNEL_USER}@${TUNNEL_HOST}" \
      >>"$STATE_DIR/${port}.log" 2>&1 9>&- &
    echo $! > "$pid_file"
    started_at[$port]=$now
  done

  # Fechar túneis de portas que pararam de escutar.
  for pid_file in "$STATE_DIR"/*.pid; do
    [ -e "$pid_file" ] || continue
    port="$(basename "$pid_file" .pid)"
    if ! grep -qx "$port" <<<"$current_ports"; then
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      echo "[port-watch-ssh] porta $port não escuta mais, encerrando túnel"
      if tunnel_alive "$pid" "$port"; then
        kill "$pid" 2>/dev/null
      fi
      rm -f "$pid_file"
    fi
  done

  # Esquecer o backoff de portas que pararam de escutar: se voltarem,
  # começam do zero.
  for port in "${!started_at[@]}"; do
    if ! grep -qx "$port" <<<"$current_ports"; then
      unset "started_at[$port]" "fail_count[$port]" "next_try[$port]"
    fi
  done

  sleep "$TUNNEL_POLL_INTERVAL"
done
