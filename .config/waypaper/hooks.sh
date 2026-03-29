#!/usr/bin/env bash

# ==============================================================================
# Waypaper Hook: Ultimate Stable Version (Fixed Nautilus + Waybar)
# 策略：
# 1. 尝试直接运行 matugen (带超时)
# 2. 如果失败，使用纯 Python 脚本提取颜色 (无需终端，永不卡死)
# 3. 应用 GTK、Sway 和 Waybar 配色
# 4. 强制使用浅色系文字和控件颜色
# ==============================================================================

MATUGEN_BIN="/usr/bin/matugen"
JQ_BIN="/usr/bin/jq"
SWAYMSG_BIN="/usr/bin/swaymsg"
PYTHON_BIN="/usr/bin/python3"
LOG_FILE="$HOME/.waypaper_hook_debug.log"

echo "========================================" > "$LOG_FILE"
echo "Start: $(date)" >> "$LOG_FILE"

# --- 1. 获取壁纸 ---
AWWW_BIN="/usr/bin/awww"
if ! command -v awww &> /dev/null; then echo "ERR: awww missing" >> "$LOG_FILE"; exit 1; fi

AWWW_OUTPUT=$($AWWW_BIN query 2>> "$LOG_FILE")
WALLPAPER_LINE=$(echo "$AWWW_OUTPUT" | grep "currently displaying: image:")
if [ -z "$WALLPAPER_LINE" ]; then echo "ERR: No wallpaper found" >> "$LOG_FILE"; exit 1; fi

WALLPAPER=$(echo "$WALLPAPER_LINE" | sed 's/.*currently displaying: image: //' | xargs)
[[ "$WALLPAPER" == ~* ]] && WALLPAPER="${HOME}${WALLPAPER:1}"

if [ ! -f "$WALLPAPER" ]; then echo "ERR: File not found: $WALLPAPER" >> "$LOG_FILE"; exit 1; fi
echo "Wallpaper: $WALLPAPER" >> "$LOG_FILE"

# --- 2. 生成配色 (Matugen 或 Python fallback) ---
COLORS_JSON=""

# 尝试 Matugen (带 5 秒超时，防止卡死)
echo "Trying matugen (timeout 5s)..." >> "$LOG_FILE"
RAW_OUTPUT=$(timeout 5s "$MATUGEN_BIN" image "$WALLPAPER" -m dark --json hex 2>&1)
MTG_EXIT=$?

if [[ "$RAW_OUTPUT" == *"{"* ]]; then
    TEMP="{${RAW_OUTPUT#*\{}"
    CLEAN=$(echo "$TEMP" | sed 's/^[[:space:]]*//')
    if echo "$CLEAN" | $JQ_BIN . > /dev/null 2>&1; then
        COLORS_JSON="$CLEAN"
        echo "Matugen success." >> "$LOG_FILE"
    fi
fi

# 如果 Matugen 失败，使用 Python 备用方案
if [ -z "$COLORS_JSON" ]; then
    echo "Matugen failed (exit:$MTG_EXIT or no JSON). Using Python fallback..." >> "$LOG_FILE"

    if ! command -v python3 &> /dev/null; then
        echo "ERR: python3 not found for fallback" >> "$LOG_FILE"
        exit 1
    fi

    COLORS_JSON=$($PYTHON_BIN -W ignore << PYEOF
import sys, json
from PIL import Image
import colorsys

def lighten_color(hex_color, percent):
    """将颜色变亮"""
    hex_color = hex_color.lstrip('#')
    r = int(hex_color[0:2], 16)
    g = int(hex_color[2:4], 16)
    b = int(hex_color[4:6], 16)
    r = min(255, r + (255 - r) * percent // 100)
    g = min(255, g + (255 - g) * percent // 100)
    b = min(255, b + (255 - b) * percent // 100)
    return '#{:02x}{:02x}{:02x}'.format(r, g, b)

def get_colors(path):
    try:
        img = Image.open(path).convert('RGB')
        img = img.resize((100, 100))
        pixels = list(img.getdata())

        r_sum, g_sum, b_sum = 0, 0, 0
        for r, g, b in pixels:
            r_sum += r
            g_sum += g
            b_sum += b

        count = len(pixels)
        avg_r, avg_g, avg_b = r_sum // count, g_sum // count, b_sum // count

        def to_hex(r, g, b):
            return '#{:02x}{:02x}{:02x}'.format(max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))

        # 主色（原始）
        primary_raw = to_hex(avg_r, avg_g, avg_b)
        
        # 强制将主色变亮到浅色系（亮度 > 180）
        # 先计算当前亮度
        brightness = (avg_r * 0.299 + avg_g * 0.587 + avg_b * 0.114)
        
        if brightness < 180:
            # 太暗了，需要提亮
            lighten_percent = int((180 - brightness) / 255 * 100)
            lighten_percent = min(80, max(30, lighten_percent))
            primary = lighten_color(primary_raw, lighten_percent)
        else:
            primary = primary_raw
        
        # 副色：基于提亮后的主色，稍微偏移色相
        r_norm, g_norm, b_norm = int(primary[1:3], 16)/255, int(primary[3:5], 16)/255, int(primary[5:7], 16)/255
        h, s, v = colorsys.rgb_to_hsv(r_norm, g_norm, b_norm)
        h2 = (h + 0.05) % 1.0
        r2, g2, b2 = colorsys.hsv_to_rgb(h2, min(1.0, s * 1.2), v)
        secondary = to_hex(int(r2*255), int(g2*255), int(b2*255))

        # 背景色：强制压暗（用于 GTK 窗口背景）
        bg_r, bg_g, bg_b = int(avg_r * 0.12), int(avg_g * 0.12), int(avg_b * 0.12)
        if bg_r < 10 and bg_g < 10 and bg_b < 10:
            bg_r, bg_g, bg_b = 20, 20, 25
        background = to_hex(bg_r, bg_g, bg_b)

        # 文字颜色：统一用浅色（不用壁纸判断）
        text = '#e4e1e9'  # 浅灰白

        result = {
            "colors": {
                "primary": {"default": {"color": primary}},
                "secondary": {"default": {"color": secondary}},
                "background": {"default": {"color": background}},
                "on_background": {"default": {"color": text}}
            }
        }
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

get_colors("$WALLPAPER")
PYEOF
)

    if [[ "$COLORS_JSON" == *"error"* ]] || [ -z "$COLORS_JSON" ]; then
        echo "ERR: Python fallback failed: $COLORS_JSON" >> "$LOG_FILE"
        exit 1
    fi
    echo "Python fallback success." >> "$LOG_FILE"
fi

# --- 3. 解析颜色 ---
PRIMARY=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.primary.default.color' 2>/dev/null)
SECONDARY=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.secondary.default.color' 2>/dev/null)
BG=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.background.default.color' 2>/dev/null)
TEXT=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.on_background.default.color' 2>/dev/null)

# 兼容旧结构
if [ -z "$PRIMARY" ] || [ "$PRIMARY" == "null" ]; then
    PRIMARY=$(echo "$COLORS_JSON" | $JQ_BIN -r '.primary.default' 2>/dev/null)
    SECONDARY=$(echo "$COLORS_JSON" | $JQ_BIN -r '.secondary.default' 2>/dev/null)
    BG=$(echo "$COLORS_JSON" | $JQ_BIN -r '.background.default' 2>/dev/null)
    TEXT=$(echo "$COLORS_JSON" | $JQ_BIN -r '.on_background.default' 2>/dev/null)
fi

# 确保有副色
if [ -z "$SECONDARY" ] || [ "$SECONDARY" == "null" ]; then
    SECONDARY="$PRIMARY"
fi

# 确保文字颜色是浅色
if [ -z "$TEXT" ] || [ "$TEXT" == "null" ]; then
    TEXT="#e4e1e9"
fi

if [ -z "$PRIMARY" ] || [ -z "$BG" ]; then
    echo "ERR: Color extraction failed. P=$PRIMARY B=$BG" >> "$LOG_FILE"
    exit 1
fi
echo "Colors: P=$PRIMARY, S=$SECONDARY, B=$BG, T=$TEXT" >> "$LOG_FILE"

# --- 计算变暗颜色 ---
darken_color() {
    local hex=$1
    local percent=$2
    hex=${hex#\#}
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    r=$((r * (100 - percent) / 100))
    g=$((g * (100 - percent) / 100))
    b=$((b * (100 - percent) / 100))
    r=$((r < 10 ? 10 : r))
    g=$((g < 10 ? 10 : g))
    b=$((b < 10 ? 10 : b))
    printf '#%02x%02x%02x' $r $g $b
}

BG_DIM=$(darken_color "$BG" 20)
PRIMARY_DIM=$(darken_color "$PRIMARY" 30)

# waybar 背景：半透明深色
WAYBAR_BG="rgba(20, 20, 30, 0.85)"
# 模块背景：半透明深色
MODULE_BG="rgba(35, 35, 50, 0.75)"

echo "Dim colors: BG_DIM=$BG_DIM" >> "$LOG_FILE"

# ==============================================================================
# 4. 生成 Waybar CSS (使用浅色主色作为文字和控件颜色)
# ==============================================================================
WAYBAR_CSS_DIR="$HOME/.config/waybar"
WAYBAR_CSS="$WAYBAR_CSS_DIR/style.css"
WAYBAR_COLORS_CSS="$WAYBAR_CSS_DIR/colors.css"

mkdir -p "$WAYBAR_CSS_DIR"

# 生成颜色变量文件
cat > "$WAYBAR_COLORS_CSS" << CSSEOF
/* Auto-generated by waypaper hook - DO NOT EDIT */
@define-color primary $PRIMARY;
@define-color secondary $SECONDARY;
@define-color primary_dim $PRIMARY_DIM;
@define-color background $BG;
@define-color text $TEXT;
@define-color background_dim $BG_DIM;
@define-color waybar_bg $WAYBAR_BG;
@define-color module_bg $MODULE_BG;
CSSEOF

# 生成完整的 style.css
cat > "$WAYBAR_CSS" << 'CSSEOF'
/* Auto-generated by waypaper hook - 配色跟随壁纸 */
@import "colors.css";

/* 强制重置所有默认边距 */
* {
    border: none;
    border-radius: 0;
    font-family: "JetBrains Mono Nerd Font", "HYLeMiaoTiJ", sans-serif;
    font-size: 14px;
    min-height: 0;
    margin: 0;
    padding: 0;
}

/* Waybar 主窗口 */
window#waybar {
    background-color: @waybar_bg;
    color: @text;
    margin-top: 10px;
    margin-bottom: 10px;
    margin-left: 15px;
    margin-right: 15px;
    border-radius: 12px;
    padding: 0;
    transition: none;
}

/* 模块通用容器样式 */
#clock, #custom-sysinfo, #workspaces, #tray, #backlight, #pulseaudio, #custom-power, #custom-wf-recorder {
    padding: 0 12px;
    margin: 6px 4px;
    border-radius: 10px;
    transition: all 0.3s ease;
    background-color: @module_bg;
    color: @primary;
}

/* --- 左侧模块 --- */
#clock, #custom-sysinfo {
    background-color: @module_bg;
    color: @primary;
    font-weight: normal;
}

/* 录制模块 */
#custom-wf-recorder {
    color: @primary;
    background-color: @module_bg;
    padding: 0 12px;
    margin: 6px 4px;
    border-radius: 8px;
    font-weight: bold;
    transition: all 0.3s ease;
}

/* 录制中状态 - 保持红色醒目 */
#custom-wf-recorder.recording {
    background-color: #ff5555;
    color: #ffffff;
    animation: blink 1s step-end infinite;
}

@keyframes blink {
    50% { opacity: 0.7; }
}

/* --- 中间模块 (工作区) --- */
#workspaces {
    background-color: @module_bg;
}

#workspaces button {
    padding: 0 10px;
    color: @primary;
    background: transparent;
    border-radius: 8px;
    margin: 2px;
}

#workspaces button.focused {
    background-color: @primary;
    color: @background;
    font-weight: bold;
}

#workspaces button:hover {
    background-color: alpha(@primary, 0.2);
    color: @primary;
}

/* --- 右侧模块 --- */
#tray, #backlight, #pulseaudio, #custom-power {
    background-color: @module_bg;
    color: @primary;
}

#custom-power {
    color: @primary;
    font-weight: bold;
    background-color: @module_bg;
}

/* 电源按钮悬停效果 - 使用主色辉光 */
#custom-power:hover {
    background-color: @primary;
    color: @background;
    box-shadow: 0 0 12px alpha(@primary, 0.8);
    text-shadow: 0 0 4px rgba(0, 0, 0, 0.3);
}

/* 其他模块悬停效果 */
#clock:hover, #custom-sysinfo:hover,
#backlight:hover, #pulseaudio:hover, #tray:hover,
#custom-wf-recorder:hover {
    background-color: alpha(@primary, 0.15);
    color: @primary;
}

/* 音量滑块样式 */
#pulseaudio slider {
    min-height: 4px;
}

/* 系统托盘图标样式 */
#tray > .passive {
    -gtk-icon-effect: dim;
}

#tray > .needs-attention {
    -gtk-icon-effect: highlight;
}

/* 背光亮度模块 */
#backlight {
    color: @primary;
}

/* 音量模块 */
#pulseaudio {
    color: @primary;
}

/* 时钟模块 */
#clock {
    font-weight: 500;
}

/* 系统信息模块 */
#custom-sysinfo {
    font-family: "JetBrains Mono Nerd Font", monospace;
}
CSSEOF

echo "Waybar CSS generated" >> "$LOG_FILE"

# 重启 waybar 使配色生效
if pgrep -x waybar > /dev/null; then
    killall waybar
    sleep 0.5
    waybar &
    echo "Waybar restarted" >> "$LOG_FILE"
fi

# ==============================================================================
# 5. 生成 GTK CSS
# ==============================================================================
GTK3_DIR="$HOME/.config/gtk-3.0"
GTK4_DIR="$HOME/.config/gtk-4.0"
mkdir -p "$GTK3_DIR" "$GTK4_DIR"

GTK_CONTENT="
/* 基础颜色定义 */
@define-color accent_color $PRIMARY;
@define-color accent_bg_color $PRIMARY;
@define-color accent_fg_color $BG;
@define-color window_bg_color $BG;
@define-color window_fg_color $TEXT;
@define-color theme_bg_color $BG;
@define-color theme_fg_color $TEXT;
@define-color base_color $BG;
@define-color text_color $TEXT;
@define-color headerbar_bg_color $BG;
@define-color headerbar_fg_color $TEXT;
@define-color view_bg_color $BG;
@define-color view_fg_color $TEXT;
@define-color selected_bg_color $PRIMARY;
@define-color selected_fg_color $BG;
@define-color sidebar_bg_color $BG;
@define-color sidebar_fg_color $TEXT;
@define-color popover_bg_color $BG;
@define-color popover_fg_color $TEXT;

/* 失焦状态 */
@define-color backdrop_window_bg_color $BG_DIM;
@define-color backdrop_window_fg_color $TEXT;
@define-color backdrop_theme_bg_color $BG_DIM;
@define-color backdrop_theme_fg_color $TEXT;
@define-color backdrop_base_color $BG_DIM;
@define-color backdrop_text_color $TEXT;
@define-color backdrop_headerbar_bg_color $BG_DIM;
@define-color backdrop_headerbar_fg_color $TEXT;
@define-color backdrop_sidebar_bg_color $BG_DIM;
@define-color backdrop_sidebar_fg_color $TEXT;

window.background { 
    background-color: $BG; 
    color: $TEXT; 
}

window.background:backdrop {
    background-color: $BG_DIM;
    color: $TEXT;
}

headerbar { 
    background-color: $BG; 
    color: $TEXT; 
}

headerbar:backdrop {
    background-color: $BG_DIM;
    color: $TEXT;
}

sidebar, .sidebar, .sidebar-pane, .sidebar-view {
    background-color: $BG;
    color: $TEXT;
}

sidebar:backdrop, .sidebar:backdrop {
    background-color: $BG_DIM;
    color: $TEXT;
}

sidebar row:selected, .sidebar row:selected {
    background-color: $PRIMARY;
    color: $BG;
}

list row:selected {
    background-color: $PRIMARY;
    color: $BG;
}

.nautilus-window .sidebar {
    background-color: $BG;
}

.nautilus-window .sidebar:backdrop {
    background-color: $BG_DIM;
}

.nautilus-window .sidebar row:selected {
    background-color: $PRIMARY;
    color: $BG;
}
"

echo "$GTK_CONTENT" > "$GTK3_DIR/colors.css"
echo "$GTK_CONTENT" > "$GTK4_DIR/colors.css"

for dir in "$GTK3_DIR" "$GTK4_DIR"; do
    css_file="$dir/gtk.css"
    if [ ! -f "$css_file" ]; then
        echo "@import \"colors.css\";" > "$css_file"
    elif ! grep -q "@import.*colors.css" "$css_file"; then
        echo "@import \"colors.css\";" >> "$css_file"
    fi
done
echo "GTK CSS Updated" >> "$LOG_FILE"

# ==============================================================================
# 6. 更新 Sway 边框
# ==============================================================================
echo "Updating Sway..." >> "$LOG_FILE"
if command -v swaymsg &> /dev/null; then
    if [ -n "$SWAYSOCK" ] || pgrep -x sway > /dev/null; then
        $SWAYMSG_BIN client.focused "$PRIMARY" "$BG" "$TEXT" "$PRIMARY" "$PRIMARY" >> "$LOG_FILE" 2>&1
        $SWAYMSG_BIN client.unfocused "#333333" "$BG_DIM" "$TEXT" "#333333" "#333333" >> "$LOG_FILE" 2>&1
        echo "Sway Updated" >> "$LOG_FILE"
    else
        echo "WARN: Not in Sway session" >> "$LOG_FILE"
    fi
fi

echo "=== ALL DONE ===" >> "$LOG_FILE"
