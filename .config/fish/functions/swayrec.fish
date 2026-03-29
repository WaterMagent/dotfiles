function swayrec
    # 生成带时间戳的文件名 (格式：recording_YYYYMMDD_HHMMSS.mp4)
    set timestamp (date +%Y%m%d_%H%M%S)
    set filename "recording_$timestamp.mp4"

    echo "🎬 开始录屏..."
    echo "📁 保存文件：$filename"
    echo "🔊 音频源：桌面系统声音"
    echo "⚡ 编码：NVIDIA NVENC (H.264)"
    echo "----------------------------------------"
    echo "按 Ctrl + C 停止录制"
    echo ""

    # 执行录制命令
    # 注意：wf-recorder 接收到 SIGINT (Ctrl+C) 后会正常关闭文件
    wf-recorder \
        -f $filename \
        -c h264_nvenc \
        -t \
        --framerate 60 \
        --audio=alsa_output.pci-0000_00_1f.3.analog-stereo.monitor

    # 检查退出状态
    if test $status -eq 0
        echo ""
        echo "✅ 录制成功完成！"
        echo "📂 文件位置：(pwd)/$filename"
        
        # 可选：如果你安装了 notify-send，可以发送桌面通知
        if command -q notify-send
            notify-send "录屏完成" "文件已保存为：$filename"
        end
    else
        echo ""
        echo "❌ 录制过程中发生错误或被强制终止。"
    end
end
