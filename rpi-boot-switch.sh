#!/bin/bash
# 用于树莓派4B切换启动介质

# 检查是否以root身份运行
if [[ $EUID -ne 0 ]]; then
    echo "此脚本需要root权限或使用sudo运行"
    echo "请使用: sudo $0"
    exit 1
fi

# 检查rpi-eeprom-config是否存在
if ! command -v rpi-eeprom-config &> /dev/null; then
    echo "错误: rpi-eeprom-config 未找到"
    echo "请确保已安装raspi-config或相关工具"
    exit 1
fi

# 定义已知启动模式
declare -A boot_modes
boot_modes["0xf41"]="SD卡优先"
boot_modes["0xf14"]="USB优先"
boot_modes["0xf12"]="网络启动优先"

# 读取当前BOOT_ORDER
current_boot=$(rpi-eeprom-config | grep BOOT_ORDER | awk -F'=' '{print $2}' | tr -d ' ')

echo "============================================"
echo "       树莓派4B 启动介质切换工具"
echo "============================================"
echo ""

# 显示当前启动介质
if [[ -n "$current_boot" ]]; then
    if [[ -n "${boot_modes[$current_boot]}" ]]; then
        echo "📌 当前启动介质: ${boot_modes[$current_boot]}"
    else
        echo "📌 当前启动配置: BOOT_ORDER=$current_boot (自定义/未知模式)"
    fi
else
    echo "📌 当前未设置BOOT_ORDER (使用默认值)"
    current_boot="unknown"
fi

echo ""

# 构建可选选项（排除当前模式）
declare -a options
declare -a codes
index=1

if [[ "$current_boot" != "0xf41" ]]; then
    echo "  $index. SD卡优先 (0xf41)"
    options+=("SD卡优先")
    codes+=("0xf41")
    index=$((index + 1))
fi

if [[ "$current_boot" != "0xf14" ]]; then
    echo "  $index. USB优先 (0xf14)"
    options+=("USB优先")
    codes+=("0xf14")
    index=$((index + 1))
fi

if [[ "$current_boot" != "0xf12" ]]; then
    echo "  $index. 网络启动优先 (0xf12)"
    options+=("网络启动优先")
    codes+=("0xf12")
    index=$((index + 1))
fi

# 如果当前已经是所有已知模式之一，理论上不会出现无可选项的情况
if [[ ${#options[@]} -eq 0 ]]; then
    echo "  ✅ 当前已经是标准启动模式，无需切换。"
    echo ""
    echo "  如需修改为其他自定义启动顺序，请手动编辑EEPROM配置。"
    exit 0
fi

echo "  0. 退出 (不修改)"
echo ""

read -p "请输入选项 [0-${#options[@]}]: " choice

# 处理退出
if [[ "$choice" == "0" ]]; then
    echo "操作取消，未做任何修改。"
    exit 0
fi

# 验证选择
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#options[@]} ]]; then
    echo "❌ 无效选择！请输入 1-${#options[@]} 或 0 退出。"
    exit 1
fi

# 获取选中的启动顺序
selected_index=$((choice - 1))
selected_boot="${codes[$selected_index]}"
selected_name="${options[$selected_index]}"

echo ""
echo "============================================"
echo "  当前: ${boot_modes[$current_boot]:-$current_boot}"
echo "  目标: $selected_name ($selected_boot)"
echo "============================================"
read -p "确认修改？(y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作取消"
    exit 0
fi

# 创建临时配置文件
temp_conf=$(mktemp /tmp/boot_conf.XXXXXX)
trap 'rm -f "$temp_conf"' EXIT

echo "[all]" > "$temp_conf"
echo "BOOT_ORDER=$selected_boot" >> "$temp_conf"

# 应用设置
if rpi-eeprom-config --apply "$temp_conf"; then
    echo ""
    echo "✅ 设置成功！"
    echo ""
    echo "新的启动顺序:"
    new_boot=$(rpi-eeprom-config | grep BOOT_ORDER | awk -F'=' '{print $2}' | tr -d ' ')
    echo "  BOOT_ORDER=$new_boot → $selected_name"
    echo ""
    echo "⚠️  需要重启才能生效。"
    read -p "是否立即重启？(y/N): " reboot_confirm
    
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        echo "正在重启..."
        reboot
    else
        echo "请稍后手动重启: sudo reboot"
    fi
else
    echo "❌ 设置失败！请检查系统环境。"
    exit 1
fi
