#!/usr/bin/env bash
set -Eeuo pipefail

# ================== Config & State ==================
APP="wf-recorder"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
STATE_DIR="$RUNTIME_DIR/wfrec"
PIDFILE="$STATE_DIR/pid"
STARTFILE="$STATE_DIR/start"
SAVEPATH_FILE="$STATE_DIR/save_path"
MODEFILE="$STATE_DIR/mode"
GIF_MARKER="$STATE_DIR/is_gif"
TICKPIDFILE="$STATE_DIR/tickpid"
WAYBAR_PIDS_CACHE="$STATE_DIR/waybar.pids"

XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
CONFIG_DIR="$XDG_CACHE_HOME/wf-recorder-sh"
CFG_CODEC="$CONFIG_DIR/codec"
CFG_FPS="$CONFIG_DIR/framerate"
CFG_AUDIO="$CONFIG_DIR/audio"
CFG_DRM="$CONFIG_DIR/drm_device"
CFG_EXT="$CONFIG_DIR/container_ext"

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# Defaults
_DEFAULT_CODEC="libx264"
_DEFAULT_FRAMERATE="60"
_DEFAULT_AUDIO="on"
_DEFAULT_SAVE_EXT="mkv"

# GIF Settings
GIF_WIDTH=720
GIF_FPS=30
GIF_DITHER_MODE="bayer:bayer_scale=5"
GIF_STATS_MODE="diff"

# Load Configs
codec_from_file=$(cat "$CFG_CODEC" 2>/dev/null || true)
fps_from_file=$(cat "$CFG_FPS" 2>/dev/null || true)
audio_from_file=$(cat "$CFG_AUDIO" 2>/dev/null || true)
drm_from_file=$(cat "$CFG_DRM" 2>/dev/null || true)
ext_from_file=$(cat "$CFG_EXT" 2>/dev/null || true)

CODEC="${CODEC:-${codec_from_file:-$_DEFAULT_CODEC}}"
FRAMERATE="${FRAMERATE:-${fps_from_file:-$_DEFAULT_FRAMERATE}}"
AUDIO="${AUDIO:-${audio_from_file:-$_DEFAULT_AUDIO}}"
DRM_DEVICE="${DRM_DEVICE:-${drm_from_file:-}}"
SAVE_EXT="${SAVE_EXT:-${ext_from_file:-$_DEFAULT_SAVE_EXT}}"

TITLE="${TITLE:-}"
SAVE_DIR_ENV="${SAVE_DIR:-}"
SAVE_SUBDIR_FS="${SAVE_SUBDIR_FS:-fullscreen}"
OUTPUT="${OUTPUT:-}"
OUTPUT_SELECT="${OUTPUT_SELECT:-auto}"
MENU_BACKEND="${MENU_BACKEND:-auto}"
RECORD_MODE="${RECORD_MODE:-ask}"
WAYBAR_POKE="${WAYBAR_POKE:-on}"
WAYBAR_SIG="${WAYBAR_SIG:-9}"
ICON_REC="${ICON_REC:-⏺}"
ICON_IDLE="${ICON_IDLE:-}"

# ================== Utils ==================
has() { command -v "$1" >/dev/null 2>&1; }

lang_code() {
  local l="${LC_MESSAGES:-${LANG:-en}}"
  l="${l,,}"; l="${l%%.*}"; l="${l%%-*}"; l="${l%%_*}"
  case "$l" in zh|zh-cn|zh-tw|zh-hk) echo zh ;; *) echo en ;; esac
}

msg() {
  local id="$1"; shift
  case "$(lang_code)" in
    zh)
      case "$id" in
        already_running) printf "录制进行中" ;;
        not_running) printf "未在录制" ;;
        menu_fullscreen) printf "全屏" ;;
        menu_region) printf "区域" ;;
        menu_gif_region) printf "GIF (区域)" ;;
        menu_settings) printf "设置" ;;
        menu_exit) printf "退出" ;;
        title_mode) printf "录制模式" ;;
        notif_started_full) printf "开始录制 (全屏) → %s" "$@" ;;
        notif_started_region) printf "开始录制 (区域) → %s" "$@" ;;
        notif_saved) printf "已保存：%s" "$@" ;;
        notif_stopped) printf "已停止" ;;
        notif_processing_gif) printf "转换 GIF 中..." ;;
        notif_gif_failed) printf "GIF 转换失败" ;;
        notif_copied) printf " (已复制)" ;;
        err_wf_not_found) printf "未找到 wf-recorder" ;;
        err_need_slurp) printf "需要 slurp" ;;
        err_need_ffmpeg) printf "需要 ffmpeg" ;;
        cancel_no_mode) printf "已取消" ;;
        *) printf "%s" "$id" ;;
      esac ;;
    *)
      case "$id" in
        already_running) printf "Recording" ;;
        not_running) printf "Idle" ;;
        menu_fullscreen) printf "Fullscreen" ;;
        menu_region) printf "Region" ;;
        menu_gif_region) printf "GIF (Region)" ;;
        menu_settings) printf "Settings" ;;
        menu_exit) printf "Exit" ;;
        title_mode) printf "Mode" ;;
        notif_started_full) printf "Started (Full) → %s" "$@" ;;
        notif_started_region) printf "Started (Region) → %s" "$@" ;;
        notif_saved) printf "Saved: %s" "$@" ;;
        notif_stopped) printf "Stopped" ;;
        notif_processing_gif) printf "Converting GIF..." ;;
        notif_gif_failed) printf "GIF Failed" ;;
        notif_copied) printf " (Copied)" ;;
        err_wf_not_found) printf "wf-recorder not found" ;;
        err_need_slurp) printf "slurp required" ;;
        err_need_ffmpeg) printf "ffmpeg required" ;;
        cancel_no_mode) printf "Canceled" ;;
        *) printf "%s" "$id" ;;
      esac ;;
  esac
}

is_running() {
  [[ -r "$PIDFILE" ]] || return 1
  local pid; read -r pid <"$PIDFILE" 2>/dev/null || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

notify() { has notify-send && notify-send "wf-recorder" "$1" || true; }

signal_waybar() {
  local pids=""
  if [[ -r "$WAYBAR_PIDS_CACHE" ]]; then
    pids="$(tr '\n' ' ' <"$WAYBAR_PIDS_CACHE")"
  fi
  if [[ -z "$pids" ]]; then
    pids="$(pgrep -x -u "$UID" waybar 2>/dev/null | tr '\n' ' ')"
    [[ -n "$pids" ]] && printf '%s\n' $pids >"$WAYBAR_PIDS_CACHE"
  fi
  [[ -n "$pids" ]] && kill -RTMIN+"$WAYBAR_SIG" $pids 2>/dev/null || true
}

emit_waybar_signal() { [[ "${WAYBAR_POKE,,}" == "off" ]] && return 0; signal_waybar; }

start_tick() {
  [[ -f "$TICKPIDFILE" ]] && { read -r tpid <"$TICKPIDFILE" 2>/dev/null; [[ -n "$tpid" ]] && kill -TERM "$tpid" 2>/dev/null; rm -f "$TICKPIDFILE"; }
  ( while :; do
      [[ -r "$PIDFILE" ]] || break
      read -r p <"$PIDFILE" 2>/dev/null || p=""
      [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null || break
      signal_waybar
      sleep 1
    done ) & echo $! >"$TICKPIDFILE"
}

stop_tick() {
  [[ -f "$TICKPIDFILE" ]] && { read -r tpid <"$TICKPIDFILE" 2>/dev/null; [[ -n "$tpid" ]] && kill -TERM "$tpid" 2>/dev/null; rm -f "$TICKPIDFILE"; }
}

get_save_dir() {
  local videos="$(xdg-user-dir VIDEOS 2>/dev/null || true)"
  videos="${videos:-$HOME/Videos}"
  echo "${SAVE_DIR_ENV:-$videos/wf-recorder}"
}

list_render_nodes() { for d in /dev/dri/renderD*; do [[ -r "$d" ]] && echo "$d"; done 2>/dev/null || true; }

ext_for_codec(){ case "${1,,}" in *h264*|*hevc*) echo mp4 ;; *vp9*) echo webm ;; *) echo mkv ;; esac; }
choose_ext(){
  local e="${SAVE_EXT,,}"
  [[ -z "$e" || "$e" == "auto" ]] && { ext_for_codec "$CODEC"; return; }
  case "$e" in mp4|mkv|webm) echo "$e" ;; *) echo mkv ;; esac
}

__norm() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

_pick_menu_backend() {
  local pref="${MENU_BACKEND,,}"
  [[ "$pref" != "auto" ]] && { has "$pref" && echo "$pref" || { [[ -t 0 ]] && echo "term" || echo "none"; }; return; }
  for b in fuzzel wofi rofi bemenu fzf; do has "$b" && { echo "$b"; return; }; done
  [[ -t 0 ]] && echo "term" || echo "none"
}

menu_pick() {
  local title="${1:-Select}"; shift
  local items=("$@")
  ((${#items[@]})) || return 130
  local backend; backend="$(_pick_menu_backend)"
  local sel rc=130
  case "$backend" in
    fuzzel) set +e; sel="$(printf '%s\n' "${items[@]}" | fuzzel --dmenu -p "$title")"; rc=$?; set -e ;;
    wofi)   set +e; sel="$(printf '%s\n' "${items[@]}" | wofi --dmenu --prompt "$title")"; rc=$?; set -e ;;
    rofi)   set +e; sel="$(printf '%s\n' "${items[@]}" | rofi -dmenu -p "$title")"; rc=$?; set -e ;;
    bemenu) set +e; sel="$(printf '%s\n' "${items[@]}" | bemenu -p "$title")"; rc=$?; set -e ;;
    fzf)    set +e; sel="$(printf '%s\n' "${items[@]}" | fzf --prompt "$title> ")"; rc=$?; set -e ;;
    term)
      echo "$title"
      local i=1; for it in "${items[@]}"; do printf '  %d) %s\n' "$i" "$it"; ((i++)); done
      printf "Enter number: "
      local idx; set +e; read -r idx; rc=$?; set -e
      [[ $rc -eq 0 && -n "$idx" && "$idx" =~ ^[0-9]+$ && idx -ge 1 && idx -le ${#items[@]} ]] && sel="${items[$((idx-1))]}"
      ;;
    none) return 130 ;;
  esac
  [[ $rc -ne 0 || -z "${sel:-}" ]] && return 130
  printf '%s' "$(__norm "$sel")"
}

list_outputs() {
  local raw=""
  if has wf-recorder; then raw="$(wf-recorder -L 2>/dev/null)" 
  elif has wlr-randr; then raw="$(wlr-randr 2>/dev/null | awk '/^[^ ]/{print $1}')"
  fi
  echo "$raw" | awk 'BEGIN{RS="[ \t\r\n,]+"} /^[A-Za-z0-9_.:-]+$/ { if ($0 ~ /^(e?DP|HDMI|DVI|VGA|LVDS|Virtual|XWAYLAND)/) seen[$0]=1 } END{for(k in seen) print k}' | sort -u
}

decide_output() {
  [[ -n "$OUTPUT" ]] && { printf '%s' "$OUTPUT"; return 0; }
  local -a outs; mapfile -t outs < <(list_outputs)
  if [[ "${OUTPUT_SELECT}" == "menu" ]] || { [[ "${OUTPUT_SELECT}" == "auto" ]] && ((${#outs[@]} > 1)); }; then
    local pick; pick="$(menu_pick "Select Output" "${outs[@]}")" || return 130
    printf '%s' "$pick"; return 0
  fi
  ((${#outs[@]} == 1)) && { printf '%s' "${outs[0]}"; return 0; }
  echo "Multiple outputs, please select via menu or env" >&2; return 130
}

show_settings_menu() {
  while :; do
    local fps_display="${FRAMERATE:-Unlimited}"
    local audio_display="${AUDIO}"
    local pick; pick="$(menu_pick "Settings" \
                      "FPS: $fps_display" \
                      "Audio: $audio_display" \
                      "Codec: $CODEC" \
                      "Format: ${SAVE_EXT:-auto}" \
                      "Back")" || return 0
    
    if [[ "$pick" == "FPS: $fps_display" ]]; then
      local newf; newf="$(menu_pick "Select FPS" "60" "30" "120" "Unlimited")" || continue
      [[ "$newf" == "Unlimited" ]] && { FRAMERATE=""; rm -f "$CFG_FPS"; } || { [[ "$newf" =~ ^[0-9]+$ ]] && { FRAMERATE="$newf"; echo "$FRAMERATE" > "$CFG_FPS"; }; }
    elif [[ "$pick" == "Audio: $audio_display" ]]; then
      [[ "$AUDIO" == "on" ]] && AUDIO="off" || AUDIO="on"
      echo "$AUDIO" > "$CFG_AUDIO"
    elif [[ "$pick" == "Codec: $CODEC" ]]; then
      local newc; newc="$(menu_pick "Select Codec" "h264_vaapi" "hevc_vaapi" "av1_vaapi" "libx264")" || continue
      CODEC="$newc"; echo "$CODEC" > "$CFG_CODEC"
    elif [[ "$pick" == "Format: ${SAVE_EXT:-auto}" ]]; then
      local newe; newe="$(menu_pick "Select Format" "auto" "mkv" "mp4" "webm")" || continue
      [[ "$newe" == "auto" ]] && { SAVE_EXT="auto"; rm -f "$CFG_EXT"; } || { SAVE_EXT="$newe"; echo "$SAVE_EXT" > "$CFG_EXT"; }
    elif [[ "$pick" == "Back" ]]; then return 0; fi
  done
}

decide_mode() {
  case "${RECORD_MODE,,}" in full|fullscreen) MODE_DECIDED="full"; return 0 ;; region|area) MODE_DECIDED="region"; return 0 ;; esac
  local L_FULL="$(msg menu_fullscreen)" L_REGION="$(msg menu_region)" L_GIF="$(msg menu_gif_region)" L_SETTINGS="$(msg menu_settings)" L_EXIT="$(msg menu_exit)"
  while :; do
    local pick; pick="$(menu_pick "$(msg title_mode)" "$L_FULL" "$L_REGION" "$L_GIF" "$L_SETTINGS" "$L_EXIT")" || return 130
    if    [[ "$pick" == "$L_FULL"   ]]; then MODE_DECIDED="full"; return 0
    elif [[ "$pick" == "$L_REGION"  ]]; then MODE_DECIDED="region"; return 0
    elif [[ "$pick" == "$L_GIF"     ]]; then MODE_DECIDED="region"; IS_GIF_MODE="true"; return 0
    elif [[ "$pick" == "$L_SETTINGS" ]]; then show_settings_menu; continue
    elif [[ "$pick" == "$L_EXIT"    ]]; then return 130
    fi
  done
}

pretty_dur() {
  local dur="${1:-0}"; [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
  ((dur>=3600)) && { printf "%d:%02d:%02d" $((dur/3600)) $(((dur%3600)/60)) $((dur%60)); return; }
  printf "%02d:%02d" $((dur/60)) $((dur%60))
}

json_escape() { sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g'; }

# ================== Start / Stop ==================
start_rec() {
  is_running && { echo "$(msg already_running)"; exit 0; }
  has wf-recorder || { echo "$(msg err_wf_not_found)"; exit 1; }

  MODE_DECIDED="" ; IS_GIF_MODE="false"
  decide_mode || { echo "$(msg cancel_no_mode)"; emit_waybar_signal; exit 130; }
  local mode="$MODE_DECIDED"

  [[ "$IS_GIF_MODE" == "true" ]] && { has ffmpeg || { echo "$(msg err_need_ffmpeg)"; exit 1; }; SAVE_EXT="mp4"; touch "$GIF_MARKER"; } || rm -f "$GIF_MARKER"

  local output="" GEOM=""
  local -a args=( -c "$CODEC" )
  
  # 【关键修复】强制使用 SHM 模式，避免 DMA-BUF 格式不支持导致的崩溃
  args+=( -f shm )

  local ROOT_DIR="$(get_save_dir)"
  local TARGET_DIR="$ROOT_DIR"
  [[ "$mode" == "full" ]] && TARGET_DIR="$ROOT_DIR/${SAVE_SUBDIR_FS}"
  mkdir -p "$TARGET_DIR"

  if [[ "$mode" == "full" ]]; then
    output="$(decide_output)" || { echo "Cancel"; emit_waybar_signal; exit 130; }
    [[ -n "$output" ]] && args+=( -o "$output" )
  else
    has slurp || { echo "$(msg err_need_slurp)"; exit 1; }
    set +e; GEOM="$(slurp)"; local rc=$?; set -e
    [[ $rc -ne 0 || -z "${GEOM// /}" ]] && { echo "$(msg cancel_no_mode)"; emit_waybar_signal; exit 130; }
    args+=( -g "$GEOM" )
  fi

  local ts="$(date +'%Y-%m-%d-%H%M%S')"
  local base="$ts-${mode^^}"
  local ext="$(choose_ext)"
  local SAVE_PATH="$TARGET_DIR/$base.$ext"
  args=( --file "$SAVE_PATH" "${args[@]}" )

  [[ -n "$DRM_DEVICE" && -r "$DRM_DEVICE" ]] && args+=( -d "$DRM_DEVICE" )

  if [[ "$AUDIO" == "on" ]]; then
      args+=( --audio )
  fi

  [[ -n "$FRAMERATE" && "$FRAMERATE" =~ ^[0-9]+$ ]] && args+=( --framerate "$FRAMERATE" )
  
  # 像素格式设置
  args+=( -F "format=yuv420p" )

  setsid nohup wf-recorder "${args[@]}" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >"$PIDFILE"
  date +%s >"$STARTFILE"
  echo "$SAVE_PATH" >"$SAVEPATH_FILE"
  echo "$mode" >"$MODEFILE"

  local note=""
  [[ "$mode" == "full" ]] && note="$(msg notif_started_full "$output" "$SAVE_PATH")" || note="$(msg notif_started_region "$SAVE_PATH")"
  notify "$note"
  emit_waybar_signal
  start_tick
}

stop_rec() {
  is_running || { echo "$(msg not_running)"; emit_waybar_signal; exit 0; }
  read -r pid <"$PIDFILE"
  kill -INT "$pid" 2>/dev/null || true
  for _ in {1..40}; do sleep 0.1; is_running || break; done
  is_running && kill -TERM "$pid" 2>/dev/null || true
  sleep 0.2
  is_running && kill -KILL "$pid" 2>/dev/null || true

  rm -f "$PIDFILE" "$MODEFILE"
  stop_tick

  local save_path=""; [[ -r "$SAVEPATH_FILE" ]] && read -r save_path <"$SAVEPATH_FILE"
  
  if [[ -f "$GIF_MARKER" ]]; then
    rm -f "$GIF_MARKER"
    if [[ -n "$save_path" && -f "$save_path" ]]; then
        notify "$(msg notif_processing_gif)"
        local gif_dir="$(get_save_dir)/gif"
        mkdir -p "$gif_dir"
        local filename=$(basename "$save_path")
        local gif_out="$gif_dir/${filename%.*}.gif"
        local filters="fps=$GIF_FPS,scale=$GIF_WIDTH:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=$GIF_STATS_MODE[p];[s1][p]paletteuse=dither=$GIF_DITHER_MODE"
        if ffmpeg -y -v error -i "$save_path" -vf "$filters" "$gif_out"; then
             rm "$save_path"; save_path="$gif_out"; echo "$save_path" > "$SAVEPATH_FILE"
        else notify "$(msg notif_gif_failed)"; fi
    fi
  fi

  if [[ -n "$save_path" && -f "$save_path" ]]; then
    ln -sf "$(basename "$save_path")" "$(dirname "$save_path")/latest" || true
    local cp_note=""
    if has wl-copy; then
        echo "file://${save_path}" | wl-copy --type text/uri-list
        cp_note="$(msg notif_copied)"
    fi
    notify "$(msg notif_saved "$save_path")${cp_note}"
  else notify "$(msg notif_stopped)"; fi

  emit_waybar_signal
}

# ================== Waybar JSON ==================
pretty_status_json() {
  local text tooltip class alt
  if is_running; then
    local start=0; [[ -r "$STARTFILE" ]] && read -r start <"$STARTFILE" || true
    [[ "$start" =~ ^[0-9]+$ ]] || start=0
    local now dur; now="$(date +%s)"; dur=$((now - start)); (( dur < 0 )) && dur=0
    local t="$(pretty_dur "$dur")"
    local save_path=""; [[ -r "$SAVEPATH_FILE" ]] && read -r save_path <"$SAVEPATH_FILE" || true
    local mode=""; [[ -r "$MODEFILE" ]] && read -r mode <"$MODEFILE" || true
    
    text="$ICON_REC$t"
    tooltip="Recording ($mode)\nTime: $t\nFile: $save_path"
    class="recording"
    alt="rec"
  else
    text="$ICON_IDLE"
    tooltip="Click to start recording"
    class="idle"
    alt="idle"
  fi
  printf '{"text":"%s","tooltip":"%s","class":"%s","alt":"%s"}\n' \
     "$(printf '%s' "$text" | json_escape)" \
     "$(printf '%s' "$tooltip" | json_escape)" \
     "$class" "$alt"
}

case "${1:-toggle}" in
  start) start_rec ;;
  stop) stop_rec ;;
  toggle) is_running && stop_rec || start_rec ;;
  settings) show_settings_menu ;;
  waybar) pretty_status_json ;;
  *) echo "Usage: $0 {start|stop|toggle|settings|waybar}" ;;
esac
