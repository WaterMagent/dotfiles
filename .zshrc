export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  z
  history
  command-not-found
  colored-man-pages
)
source $ZSH/oh-my-zsh.sh
autoload -Uz colors && colors
autoload -Uz vcs_info
precmd_vcs_info() {
    vcs_info
    [[ -n "$vcs_info_msg_0_" ]] && vcs_info_msg_0_="${vcs_info_msg_0_}"
}
precmd_functions+=( precmd_vcs_info )
zstyle ':vcs_info:git:*' formats '%b'
zstyle ':vcs_info:git:*' actionformats '%b|%a'
git_status_info() {
    local git_branch git_version git_status
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || echo "detached")
        git_version=$(git describe --tags --abbrev=0 2>/dev/null || echo "no-tag")
        if [[ -n $(git status -s 2>/dev/null) ]]; then
            git_status="*"  # 有未提交的更改
        else
            git_status=""   # 干净的工作区
        fi
        echo "[$git_status$git_branch via $git_version]"
    fi
}
setopt PROMPT_SUBST
PROMPT='%F{red}[%*]%f ❯ '
RPROMPT='%F{208}$(git_status_info)%f%F{green}[%~]%f%F{blue}[%M@%n]%f'
alias ls='eza --icons'
alias ll='eza -l --icons'
alias la='eza -la --icons'
alias lt='eza --tree --icons'
function swayrec() {
    local timestamp=$(date +%Y-%m-%d_%H:%M:%S)
    local filename="recording_$timestamp.mkv"
    echo "🎬 开始录屏..."
    echo "📁 保存文件：$filename"
    echo "🔊 音频源：桌面系统声音"
    echo "⚡ 编码：NVIDIA NVENC (H.264)"
    echo "----------------------------------------"
    echo "按 Ctrl + C 停止录制"
    echo ""
    wf-recorder \
        -f "$filename" \
        -c h264_nvenc \
        -t \
        --framerate 60 \
        --audio=alsa_output.pci-0000_00_1f.3.analog-stereo.monitor
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✅ 录制成功完成！"
        echo "📂 文件位置：$(pwd)/$filename"
        if command -v notify-send &>/dev/null; then
            notify-send "录屏完成" "文件已保存为：$filename"
        fi
    else
        echo ""
        echo "❌ 录制过程中发生错误或被强制终止。"
    fi
}
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias cat='bat --style=plain'  # 如果你安装了 bat
alias top='btm'                 # 如果你安装了 bottom
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS
setopt SHARE_HISTORY
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
setopt AUTO_CD
setopt INTERACTIVE_COMMENTS
if [[ -o login ]] && [[ "$(tty)" == "/dev/tty1" ]] && [[ -z "$WAYLAND_DISPLAY" ]] && [[ -z "$DISPLAY" ]]; then
    echo "Starting Sway from tty1..."
    exec sway --unsupported-gpu
fi
