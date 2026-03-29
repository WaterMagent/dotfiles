#!/bin/bash

WALLPAPER_DIR="$HOME/图片/Wallpapers"

# 检查壁纸目录
if [[ ! -d "$WALLPAPER_DIR" ]]; then
    notify-send "错误" "壁纸目录不存在：$WALLPAPER_DIR"
    exit 1
fi

# 确保 swww daemon 运行
if ! pgrep -x "swww-daemon" > /dev/null; then
    swww-daemon --format xrgb &
    sleep 1
fi

# 缓存目录
CACHE_DIR="$HOME/.cache/rofi-wallpaper"
mkdir -p "$CACHE_DIR"

# 收集壁纸并生成缩略图
declare -a wallpapers
declare -a thumbs
idx=0

for file in "$WALLPAPER_DIR"/*.{jpg,jpeg,png,webp,gif}; do
    [[ -f "$file" ]] || continue
    
    wallpapers+=("$file")
    thumb="$CACHE_DIR/thumb_$idx.png"
    
    # 生成缩略图
    convert "$file" -resize 200x300^ -gravity center -extent 200x300 "$thumb" 2>/dev/null
    thumbs+=("$thumb")
    
    ((idx++))
done

if [[ ${#wallpapers[@]} -eq 0 ]]; then
    notify-send "错误" "未找到壁纸文件"
    exit 1
fi

# 构建 rofi 选项
options=""
for i in "${!thumbs[@]}"; do
    options+="${wallpapers[$i]}\x00icon\x1f${thumbs[$i]}\n"
done

# 显示 rofi
selected=$(echo -en "$options" | rofi -dmenu -i -markup-rows \
    -p "️ 壁纸" \
    -config /dev/null \
    -kb-cancel "Escape,Control+g" \
    -theme-str 'window {width: 800px; height: 600px;} listview {columns: 4; lines: 5;} element-icon {size: 180px; border-radius: 8px;} element-text {enabled: false;}')

# 设置壁纸
if [[ -n "$selected" ]]; then
    swww img "$selected" --transition-type grow --transition-duration 0.5
    notify-send "壁纸已设置" "$(basename "$selected")"
fi

exit 0
