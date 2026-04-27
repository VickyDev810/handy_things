#!/usr/bin/env bash
# RunPod quick-setup script
# Usage on a fresh pod:
#   curl -fsSL https://your-host.example/runpod-setup.sh | bash
# Or:
#   wget -qO- https://your-host.example/runpod-setup.sh | bash
#
# Idempotent: safe to re-run. Skips work that's already done.

set -euo pipefail

# ─── Pretty logging ──────────────────────────────────────────────────────────
log()  { printf "\033[1;36m[setup]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  !\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m  ✗\033[0m %s\n" "$*" >&2; }

START_TS=$(date +%s)

# ─── Sanity ──────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  warn "Not running as root — apt installs may need sudo. Continuing anyway."
  SUDO="sudo"
else
  SUDO=""
fi

export DEBIAN_FRONTEND=noninteractive

# ─── 1. APT update + core tools ──────────────────────────────────────────────
log "Updating apt and installing core tools…"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq --no-install-recommends \
  rsync          `# resumable transfers` \
  openssh-client `# scp / ssh` \
  curl wget      `# downloads` \
  git git-lfs    `# repos + large files` \
  htop btop      `# process monitors` \
  nvtop          `# GPU monitor` \
  tmux screen    `# persistent sessions` \
  vim nano       `# editors` \
  jq             `# JSON wrangling` \
  unzip zip tar  `# archives` \
  tree           `# directory listing` \
  ncdu           `# disk usage TUI` \
  net-tools iputils-ping dnsutils \
  ca-certificates \
  build-essential \
  python3-pip python3-venv \
  aria2          `# parallel downloader (huge speedup over wget)` \
  pv             `# pipe progress` \
  ripgrep fd-find `# fast search/find` \
  bc             `# math in shell` \
  || warn "Some apt packages failed — continuing"

git lfs install --skip-repo >/dev/null 2>&1 || true
ok "Core apt packages installed"

# ─── 2. Python tools ─────────────────────────────────────────────────────────
log "Installing Python tools (gdown, huggingface_hub, hf_transfer)…"
pip install --quiet --upgrade pip
pip install --quiet --upgrade \
  gdown                `# Google Drive downloads` \
  huggingface_hub[cli] `# huggingface-cli download/upload` \
  hf_transfer          `# fast multi-threaded HF transfers` \
  requests tqdm
ok "Python tools installed"

# Enable HF fast transfer by default
if ! grep -q "HF_HUB_ENABLE_HF_TRANSFER" ~/.bashrc 2>/dev/null; then
  echo 'export HF_HUB_ENABLE_HF_TRANSFER=1' >> ~/.bashrc
fi

# ─── 3. runpodctl ────────────────────────────────────────────────────────────
if ! command -v runpodctl >/dev/null 2>&1; then
  log "Installing runpodctl…"
  wget -qO- cli.runpod.net | $SUDO bash >/dev/null 2>&1 \
    && ok "runpodctl installed" \
    || warn "runpodctl install failed — skip"
else
  ok "runpodctl already installed"
fi

# ─── 4. rclone (for gdrive/onedrive/s3) ──────────────────────────────────────
if ! command -v rclone >/dev/null 2>&1; then
  log "Installing rclone…"
  curl -fsSL https://rclone.org/install.sh | $SUDO bash >/dev/null 2>&1 \
    && ok "rclone installed (run \`rclone config\` to set up remotes)" \
    || warn "rclone install failed"
else
  ok "rclone already installed"
fi

# ─── 5. Shell quality of life ────────────────────────────────────────────────
log "Configuring shell aliases…"
ALIASES_BLOCK=$(cat <<'EOF'

# ── runpod-setup aliases ──
alias ll='ls -lah --color=auto'
alias l='ls -CF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias gpu='nvidia-smi'
alias gpuw='watch -n1 nvidia-smi'
alias df-='df -h | grep -v tmpfs'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me; echo'
alias rs='rsync -avzP'
# ── end runpod-setup ──
EOF
)

if ! grep -q "runpod-setup aliases" ~/.bashrc 2>/dev/null; then
  echo "$ALIASES_BLOCK" >> ~/.bashrc
  ok "Aliases added to ~/.bashrc"
else
  ok "Aliases already in ~/.bashrc"
fi

# ─── 6. tmux config (sane defaults) ──────────────────────────────────────────
if [[ ! -f ~/.tmux.conf ]]; then
  cat > ~/.tmux.conf <<'EOF'
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
bind r source-file ~/.tmux.conf \; display "reloaded"
bind | split-window -h
bind - split-window -v
EOF
  ok "Wrote ~/.tmux.conf"
fi

# ─── 7. Git defaults (only if unset) ─────────────────────────────────────────
git config --global --get pull.rebase >/dev/null 2>&1 || git config --global pull.rebase false
git config --global --get init.defaultBranch >/dev/null 2>&1 || git config --global init.defaultBranch main
git config --global --get core.editor >/dev/null 2>&1 || git config --global core.editor vim

# ─── 8. Diagnostics ──────────────────────────────────────────────────────────
log "Environment summary:"
echo "  hostname     : $(hostname)"
echo "  public IP    : $(curl -s --max-time 3 ifconfig.me || echo 'unknown')"
echo "  disk (/)     : $(df -h / | awk 'NR==2 {print $4 " free of " $2}')"
echo "  disk (/work) : $(df -h /workspace 2>/dev/null | awk 'NR==2 {print $4 " free of " $2}' || echo 'no /workspace')"
echo "  RAM          : $(free -h | awk '/^Mem:/ {print $7 " avail of " $2}')"
echo "  CPUs         : $(nproc)"
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "  GPU          : $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
  echo "  CUDA         : $(nvidia-smi | grep -oP 'CUDA Version: \K[0-9.]+' || echo 'unknown')"
else
  warn "nvidia-smi not found"
fi
echo "  Python       : $(python3 --version 2>&1)"

ELAPSED=$(( $(date +%s) - START_TS ))
log "✅ Done in ${ELAPSED}s"
echo
echo "Next steps:"
echo "  • Reload shell:   source ~/.bashrc"
echo "  • Set up gdrive:  rclone config        (then 'rclone copy file gdrive:path -P')"
echo "  • HF download:    huggingface-cli download <repo> --local-dir ./model"
echo "  • Send a file:    runpodctl send <file>"
