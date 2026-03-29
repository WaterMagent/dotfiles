#!/usr/bin/env bash

# ==============================================================================
# Waypaper Hook: Ultimate Stable Version (Fixed Nautilus Blur Issue)
# 策略：
# 1. 尝试直接运行 matugen (带超时)
# 2. 如果失败，使用纯 Python 脚本提取颜色 (无需终端，永不卡死)
# 3. 应用 GTK 和 Sway
# 修复：添加 backdrop (失焦) 状态的颜色定义，修复 Nautilus 侧边栏变白问题
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

        primary = to_hex(avg_r, avg_g, avg_b)

        # 背景色：强制压暗
        bg_r, bg_g, bg_b = int(avg_r * 0.12), int(avg_g * 0.12), int(avg_b * 0.12)
        if bg_r < 10 and bg_g < 10 and bg_b < 10:
            bg_r, bg_g, bg_b = 20, 20, 25
        background = to_hex(bg_r, bg_g, bg_b)

        # 文字颜色：浅灰白
        text = '#e4e1e9'

        result = {
            "colors": {
                "primary": {"default": {"color": primary}},
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
BG=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.background.default.color' 2>/dev/null)
TEXT=$(echo "$COLORS_JSON" | $JQ_BIN -r '.colors.on_background.default.color' 2>/dev/null)

if [ -z "$PRIMARY" ] || [ "$PRIMARY" == "null" ]; then
    PRIMARY=$(echo "$COLORS_JSON" | $JQ_BIN -r '.primary.default' 2>/dev/null)
    BG=$(echo "$COLORS_JSON" | $JQ_BIN -r '.background.default' 2>/dev/null)
    TEXT=$(echo "$COLORS_JSON" | $JQ_BIN -r '.on_background.default' 2>/dev/null)
fi

if [ -z "$PRIMARY" ] || [ -z "$BG" ] || [ -z "$TEXT" ]; then
    echo "ERR: Color extraction failed. P=$PRIMARY B=$BG T=$TEXT" >> "$LOG_FILE"
    exit 1
fi
echo "Colors: P=$PRIMARY, B=$BG, T=$TEXT" >> "$LOG_FILE"

# --- 计算失焦状态的变暗颜色 ---
# 将背景色变暗 20%，用于 backdrop 状态
darken_color() {
    local hex=$1
    local percent=$2
    # 去掉 # 号
    hex=${hex#\#}
    # 提取 RGB
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    # 变暗
    r=$((r * (100 - percent) / 100))
    g=$((g * (100 - percent) / 100))
    b=$((b * (100 - percent) / 100))
    # 确保不低于 10
    r=$((r < 10 ? 10 : r))
    g=$((g < 10 ? 10 : g))
    b=$((b < 10 ? 10 : b))
    printf '#%02x%02x%02x' $r $g $b
}

BG_DIM=$(darken_color "$BG" 20)
TEXT_DIM=$(darken_color "$TEXT" 30)

echo "Dim colors: BG_DIM=$BG_DIM, TEXT_DIM=$TEXT_DIM" >> "$LOG_FILE"

# --- 4. 生成 GTK CSS (修复 backdrop 状态) ---
GTK3_DIR="$HOME/.config/gtk-3.0"
GTK4_DIR="$HOME/.config/gtk-4.0"
mkdir -p "$GTK3_DIR" "$GTK4_DIR"

GTK_CONTENT="
/* 基础颜色定义 */
@define-color accent_color $PRIMARY;
@define-color accent_bg_color $PRIMARY;
@define-color accent_fg_color $TEXT;
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
@define-color selected_fg_color $TEXT;
@define-color sidebar_bg_color $BG;
@define-color sidebar_fg_color $TEXT;
@define-color popover_bg_color $BG;
@define-color popover_fg_color $TEXT;

/* 失焦 (backdrop) 状态的颜色 - 修复 Nautilus 侧边栏变白问题 */
@define-color backdrop_window_bg_color $BG_DIM;
@define-color backdrop_window_fg_color $TEXT_DIM;
@define-color backdrop_theme_bg_color $BG_DIM;
@define-color backdrop_theme_fg_color $TEXT_DIM;
@define-color backdrop_base_color $BG_DIM;
@define-color backdrop_text_color $TEXT_DIM;
@define-color backdrop_headerbar_bg_color $BG_DIM;
@define-color backdrop_headerbar_fg_color $TEXT_DIM;
@define-color backdrop_sidebar_bg_color $BG_DIM;
@define-color backdrop_sidebar_fg_color $TEXT_DIM;

/* 主窗口背景 */
window.background { 
    background-color: $BG; 
    color: $TEXT; 
}

/* 失焦时的主窗口 */
window.background:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

/* 标题栏 */
headerbar { 
    background-color: $BG; 
    color: $TEXT; 
}

headerbar:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

/* 侧边栏 - 关键修复 */
sidebar, .sidebar, .sidebar-pane, .sidebar-view {
    background-color: $BG;
    color: $TEXT;
}

/* 失焦时的侧边栏 - 解决变白问题 */
sidebar:backdrop, .sidebar:backdrop, .sidebar-pane:backdrop, .sidebar-view:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

/* 侧边栏行 */
sidebar row, .sidebar row {
    background-color: $BG;
    color: $TEXT;
}

sidebar row:backdrop, .sidebar row:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

/* 选中的行 */
sidebar row:selected, .sidebar row:selected {
    background-color: $PRIMARY;
    color: $TEXT;
}

sidebar row:selected:backdrop, .sidebar row:selected:backdrop {
    background-color: $PRIMARY;
    color: $TEXT_DIM;
}

/* 列表视图 */
list row {
    background-color: $BG;
    color: $TEXT;
}

list row:selected {
    background-color: $PRIMARY;
    color: $TEXT;
}

list row:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

list row:selected:backdrop {
    background-color: $PRIMARY;
    color: $TEXT_DIM;
}

/* 视图和弹出框 */
view, .view {
    background-color: $BG;
    color: $TEXT;
}

view:backdrop, .view:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

popover, .popover {
    background-color: $BG;
    color: $TEXT;
}

popover:backdrop, .popover:backdrop {
    background-color: $BG_DIM;
    color: $TEXT_DIM;
}

/* Nautilus 特定修复 */
.nautilus-window .sidebar {
    background-color: $BG;
}

.nautilus-window .sidebar:backdrop {
    background-color: $BG_DIM;
}

.nautilus-window .sidebar row:hover {
    background-color: rgba(255, 255, 255, 0.1);
}

.nautilus-window .sidebar row:selected {
    background-color: $PRIMARY;
}

.nautilus-window .sidebar row:selected:backdrop {
    background-color: $PRIMARY;
    color: $TEXT_DIM;
}
"

echo "$GTK_CONTENT" > "$GTK3_DIR/colors.css"
echo "$GTK_CONTENT" > "$GTK4_DIR/colors.css"

# 创建或更新主 gtk.css
for dir in "$GTK3_DIR" "$GTK4_DIR"; do
    css_file="$dir/gtk.css"
    if [ ! -f "$css_file" ]; then
        echo "@import \"colors.css\";" > "$css_file"
    elif ! grep -q "@import.*colors.css" "$css_file"; then
        echo "@import \"colors.css\";" >> "$css_file"
    fi
done
echo "GTK CSS Updated (with backdrop states)" >> "$LOG_FILE"

# --- 5. 更新 Sway 边框 ---
echo "Updating Sway..." >> "$LOG_FILE"
if command -v swaymsg &> /dev/null; then
    if [ -n "$SWAYSOCK" ] || pgrep -x sway > /dev/null; then
        $SWAYMSG_BIN client.focused "$PRIMARY" "$BG" "$TEXT" "$PRIMARY" "$PRIMARY" >> "$LOG_FILE" 2>&1
        $SWAYMSG_BIN client.unfocused "#333333" "$BG_DIM" "$TEXT_DIM" "#333333" "#333333" >> "$LOG_FILE" 2>&1
        echo "Sway Updated" >> "$LOG_FILE"
    else
        echo "WARN: Not in Sway session" >> "$LOG_FILE"
    fi
fi

# --- 6. 强制刷新 GTK 应用 (可选) ---
echo "Refreshing GTK apps..." >> "$LOG_FILE"
# 通知 GTK 应用重新加载主题
if command -v gsettings &> /dev/null; then
    CURRENT_THEME=$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)
    if [ -n "$CURRENT_THEME" ]; then
        # 切换主题再切回来，强制刷新
        gsettings set org.gnome.desktop.interface gtk-theme 'Default' 2>/dev/null
        gsettings set org.gnome.desktop.interface gtk-theme "$CURRENT_THEME" 2>/dev/null
        echo "GTK theme refreshed" >> "$LOG_FILE"
    fi
fi

echo "=== ALL DONE ===" >> "$LOG_FILE"
