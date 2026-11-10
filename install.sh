set -e

cat /etc/os-release

apt -y update

# CURL
apt -y install curl

# Make
apt -y install make

# GCC
apt -y install gcc

# Git
apt -y install git

# Ripgrep
apt -y install ripgrep

# Fuzzy finder
apt -y install fzf

# Wl-clipboard
apt -y install wl-clipboard

# Ip route
apt -y install iproute2

# SSH
# Só o client: com --network=host não existe mais túnel reverso, e portanto
# nenhum motivo para um sshd dentro do container.
apt -y install openssh-client
mkdir -p /root/.ssh
# Cópia seletiva. O ~/.ssh do host é montado em /tmp/host-ssh (readonly) e
# NÃO deve ser copiado inteiro: só a chave usada para git e os known_hosts.
for f in id_ed25519 id_ed25519.pub known_hosts; do
  if [ -f "/tmp/host-ssh/$f" ]; then
    cp "/tmp/host-ssh/$f" /root/.ssh/
  fi
done
chown -R root:root /root/.ssh
chmod 700 /root/.ssh
find /root/.ssh -type f ! -name '*.pub' ! -name 'known_hosts*' -exec chmod 600 {} +

# ZSH
apt -y install zsh
chsh -s "$(which zsh)" || true

# Oh my zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --skip-chsh --unattended

# Neovim
curl -fsSL -O https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
rm -rf /opt/nvim-linux-x86_64
tar -C /opt -xzf nvim-linux-x86_64.tar.gz

grep -qF '# >>> devcontainer zshrc >>>' ~/.zshrc 2>/dev/null || cat >> ~/.zshrc <<'ZRC'

# >>> devcontainer zshrc >>>
# ssh-agent: um por container, socket fixo, sem pedir passphrase ao abrir shell.
# Carregue a chave sob demanda com `sshkey`.
export SSH_AUTH_SOCK=/tmp/ssh-agent.sock
ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then          # 2 = nao conseguiu falar com o agent
  rm -f "$SSH_AUTH_SOCK"
  ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1
fi
alias sshkey='ssh-add ~/.ssh/id_ed25519'

export PATH="$HOME/.local/bin:$PATH"
export PATH="$PATH:/opt/nvim-linux-x86_64/bin"

function _is_in_container() {
  [[ -n "$REMOTE_CONTAINERS" ]] && return 0
  grep -qE "docker|container|lxc" /proc/1/cgroup 2>/dev/null
}
function _container_prompt() {
  _is_in_container && echo "%F{cyan}🐳 devcontainer%f "
}
PROMPT='$(_container_prompt)'"$PROMPT"
alias vim='nvim'
# <<< devcontainer zshrc <<<
ZRC

[ -d ~/.config/nvim ] || git clone https://github.com/OuthBack/neovim-config.git ~/.config/nvim
git config --system --add safe.directory '*'

# NPM
npm install -g typescript-language-server typescript tree-sitter-cli @google/gemini-cli

# Claude
curl -fsSL https://claude.ai/install.sh | bash

# Clear
rm nvim-linux-x86_64.tar.gz

#
# colocar no docker do host {
#  "detachKeys": "ctrl-z,z"
# }
