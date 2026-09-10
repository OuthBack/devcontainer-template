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

# SSH
apt -y install openssh-client openssh-server
cp -r /tmp/host-ssh /root/.ssh
cp /tmp/host-ssh/id_ed25519 /root/.ssh/
cp /tmp/host-ssh/id_rsa /root/.ssh/
cp /tmp/host-ssh/known_hosts /root/.ssh/
chown -R root:root /root/.ssh
chmod 700 /root/.ssh 
chmod 600 /root/.ssh/*

# ZSH
apt -y install zsh
chsh -s $(which zsh)

# Oh my zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --skip-chsh --unattended

# Neovim
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
rm -rf /opt/nvim-linux-x86_64
tar -C /opt -xzf nvim-linux-x86_64.tar.gz

echo 'export PATH="$PATH:/opt/nvim-linux-x86_64/bin"' >> ~/.zshrc 

git clone https://github.com/OuthBack/neovim-config.git ~/.config/nvim
git config --global --add safe.directory $(pwd)

# NPM
npm install -g typescript-language-server typescript tree-sitter-cli @google/gemini-cli

# Clear
rm nvim-linux-x86_64.tar.gz

