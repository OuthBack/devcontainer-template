cat /etc/os-release

echo "nameserver 8.8.8.8" > /etc/resolv.conf

cat /etc/resolv.conf

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
apt -y install openssh-client openssh-server
mkdir -p /root/.ssh
cp -r /tmp/host-ssh/. /root/.ssh/
chown -R root:root /root/.ssh
chmod 700 /root/.ssh
find /root/.ssh -type f ! -name '*.pub' ! -name 'known_hosts*' -exec chmod 600 {} +

# ZSH
apt -y install zsh
chsh -s $(which zsh)

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
export TUNNEL_HOST="$(ip route | awk '/default/ {print $3; exit}')"
export TUNNEL_USER="$(whoami)"
export TUNNEL_EXCLUDE_PORTS="22"
export TUNNEL_POLL_INTERVAL="2"
# <<< devcontainer zshrc <<<
ZRC


git clone https://github.com/OuthBack/neovim-config.git ~/.config/nvim
git config --system --add safe.directory '*'

# NPM
npm install -g typescript-language-server typescript tree-sitter-cli @google/gemini-cli

# Claude
curl -fsSL https://claude.ai/install.sh | bash

# Clear
rm nvim-linux-x86_64.tar.gz

# DNS binding
# echo "172.19.0.3 dynamodb" >> /etc/hosts
# echo "172.19.0.4 dynamodb-admin" >> /etc/hosts
# echo "172.19.0.2 pgadmin" >> /etc/hosts
# echo "172.18.0.2 mysql" >> /etc/hosts

#
# colocar no docker do host {
#  "detachKeys": "ctrl-z,z"
# }
