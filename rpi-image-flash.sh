#!/bin/bash
#====================================================================
# rpi-image-flash.sh - 树莓派系统远程刷写脚本 (v4.2 - WiFi 无头配置增强)
# 用法: sudo ./rpi-image-flash.sh
# 特性:
#   * 自动检测系统架构，仅支持 arm64 (64位)
#   * 自动检测并安装 rpi-imager 及 libopengl0 依赖  
#   * 镜像缓存复用 + SHA1 校验
#   * 支持树莓派5 NVMe
#   * 禁止向当前系统盘写入
#   * 官方 rpi-imager 烧录
#   * 交互式无头配置：SSH、用户、WiFi（国家码白名单+默认CN）
#   * online/offline 镜像选择
#   * firstrun.sh 通过 systemd.run 触发，自毁清理
#   * WiFi 使用 .nmconnection 注入（兼容 Bookworm+）
#====================================================================

#--------- 预置镜像变量 ----------
IMAGE_LITE="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-lite.img.xz"
IMAGE_FULL="https://downloads.raspberrypi.com/raspios_full_arm64/images/raspios_full_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-full.img.xz"
MOUNT_POINT="/mnt"
CACHE_DIR="/tmp/rpi_image_cache"
TMP_IMAGE=""

#--------- 颜色定义 ----------
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

#--------- 系统架构检查 ----------
check_architecture() {
    local arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ "$arch" != "arm64" ]] && [[ "$arch" != "aarch64" ]]; then
        echo -e "${BOLD_RED}错误: 此脚本仅支持 64 位树莓派系统 (arm64/aarch64).${NC}"
        echo -e "${RED}当前系统架构: $arch${NC}"
        exit 1
    fi
    echo -e "${GREEN}系统架构检查通过: $arch${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}错误: 此脚本必须以 root 权限运行 (sudo).${NC}"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${BOLD_RED}错误: 未找到必需命令 $1. 请先安装 (例如 apt install $2).${NC}"
        exit 1
    fi
}

ensure_rpi_imager() {
    if ! command -v rpi-imager &> /dev/null; then
        echo -e "${YELLOW}未检测到 rpi-imager, 正在自动安装...${NC}"
        apt-get update && apt-get install -y rpi-imager || {
            echo -e "${BOLD_RED}自动安装 rpi-imager 失败, 请手动安装后重试.${NC}"
            exit 1
        }
    fi
    if ! ldconfig -p | grep -q libOpenGL.so; then
        echo -e "${YELLOW}正在安装 libopengl0 ...${NC}"
        apt-get install -y libopengl0 || {
            echo -e "${BOLD_RED}安装 libopengl0 失败.${NC}"
            exit 1
        }
    fi
}

#--------- 获取当前系统盘 ----------
get_current_disk() {
    local root_part=$(findmnt -n -o SOURCE /)
    local disk_name=$(lsblk -no PKNAME "$root_part" 2>/dev/null)
    [[ -z "$disk_name" ]] && { echo -e "${BOLD_RED}无法确定当前系统磁盘.${NC}"; exit 1; }
    echo "/dev/$disk_name"
}

#--------- 设备扫描 ----------
list_target_devices() {
    local current_disk="$1"
    echo -e "${YELLOW}正在扫描可用存储设备 (>1GB) ...${NC}"
    local devices=()
    local idx=1
    while read -r name size type; do
        [[ "$type" != "disk" || ! "$name" =~ ^(sd|mmcblk|nvme) ]] && continue
        local bytes=$(lsblk -b -d -n -o SIZE "/dev/$name" 2>/dev/null)
        [[ -z "$bytes" || "$bytes" -lt 1000000000 ]] && continue
        devices+=("/dev/$name")
        local model=$(lsblk -d -n -o MODEL "/dev/$name" 2>/dev/null || echo "未知")
        local display_size=$(lsblk -d -n -o SIZE "/dev/$name")
        if [[ "/dev/$name" == "$current_disk" ]]; then
            printf "%s) ${BOLD_RED}/dev/%-12s %8s %s [当前系统盘 - 禁止写入]${NC}\n" "$idx" "$name" "$display_size" "$model"
        else
            printf "%s) /dev/%-12s %8s %s\n" "$idx" "$name" "$display_size" "$model"
        fi
        ((idx++))
    done < <(lsblk -d -n -o NAME,SIZE,TYPE)
    [[ ${#devices[@]} -eq 0 ]] && { echo -e "${BOLD_RED}没有可写入设备.${NC}"; exit 1; }
    TARGET_DEVICE_LIST=("${devices[@]}")
}

#--------- 在线镜像列表 ----------
fetch_online_image_list() {
    local json_url="https://downloads.raspberrypi.com/os_list_imagingutility_v4.json"
    local json_data=$(curl -sS --max-time 10 "$json_url" 2>/dev/null)
    [[ -z "$json_data" ]] && { echo -e "${RED}无法获取在线列表，使用离线内置列表。${NC}"; return 1; }

    local parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except:
    sys.exit(1)
entries = []
for item in data.get('os_list', []):
    if 'url' in item:
        name = item['name']
        if '64' in name or 'arm64' in name.lower():
            entries.append((item.get('release_date', '未知'), name, item['url']))
    if 'subitems' in item:
        for sub in item['subitems']:
            if 'url' in sub:
                name = sub['name']
                if '64' in name or 'arm64' in name.lower():
                    entries.append((sub.get('release_date', '未知'), name, sub['url']))
entries.sort(key=lambda x: x[0] if x[0] != '未知' else '0000-00-00', reverse=True)
for date, name, url in entries:
    print(f'{date}|{name}|{url}')
" <<< "$json_data" 2>/dev/null)

    if [[ -z "$parsed" ]]; then
        echo -e "${RED}解析在线列表失败。${NC}"
        return 1
    fi

    ONLINE_DATES=(); ONLINE_NAMES=(); ONLINE_URLS=()
    while IFS='|' read -r date name url; do
        [[ -z "$name" || -z "$url" ]] && continue
        ONLINE_DATES+=("$date")
        ONLINE_NAMES+=("$name")
        ONLINE_URLS+=("$url")
    done <<< "$parsed"
    [[ ${#ONLINE_NAMES[@]} -eq 0 ]] && { echo -e "${RED}无64位在线镜像.${NC}"; return 1; }
    echo -e "${GREEN}获取到 ${#ONLINE_NAMES[@]} 个在线镜像。${NC}"
    return 0
}

show_online_menu() {
    echo "===================================="
    echo " 在线镜像列表（64位，按日期排列）"
    echo "===================================="
    printf "%-4s %-12s %-45s\n" "编号" "发布日期" "镜像名称"
    echo "--------------------------------------------------------------"
    for i in "${!ONLINE_NAMES[@]}"; do
        printf "%2d)  %-12s %s\n" "$((i+1))" "${ONLINE_DATES[$i]}" "${ONLINE_NAMES[$i]}"
    done
    echo "--------------------------------------------------------------"
    echo " 0) 自定义镜像 URL"
}

show_offline_menu() {
    echo "===================================="
    echo " 离线镜像列表（预置）"
    echo "===================================="
    echo "1) Raspberry Pi OS Lite (64-bit)"
    echo "2) Raspberry Pi OS Full (64-bit)"
    echo "0) 自定义镜像 URL"
}

choose_image() {
    local online_mode=0
    fetch_online_image_list && online_mode=1

    while true; do
        if [[ $online_mode -eq 1 ]]; then
            show_online_menu
            local total=${#ONLINE_NAMES[@]}
            read -p "请输入编号 [0-$total]: " img_choice
            if [[ "$img_choice" == "0" ]]; then
                read -p "自定义镜像下载链接: " custom_url
                [[ -n "$custom_url" ]] && { IMAGE_URL="$custom_url"; IMAGE_NAME="自定义镜像"; break; }
            elif [[ "$img_choice" =~ ^[0-9]+$ ]] && (( img_choice >= 1 && img_choice <= total )); then
                IMAGE_URL="${ONLINE_URLS[$((img_choice-1))]}"
                IMAGE_NAME="${ONLINE_NAMES[$((img_choice-1))]} (${ONLINE_DATES[$((img_choice-1))]})"
                break
            fi
        else
            show_offline_menu
            read -p "请输入数字 [0-2]: " img_choice
            if [[ "$img_choice" == "0" ]]; then
                read -p "自定义镜像下载链接: " custom_url
                [[ -n "$custom_url" ]] && { IMAGE_URL="$custom_url"; IMAGE_NAME="自定义镜像"; break; }
            elif [[ "$img_choice" == "1" ]]; then
                IMAGE_URL="$IMAGE_LITE"; IMAGE_NAME="Raspberry Pi OS Lite (64-bit)"; break
            elif [[ "$img_choice" == "2" ]]; then
                IMAGE_URL="$IMAGE_FULL"; IMAGE_NAME="Raspberry Pi OS Full (64-bit)"; break
            fi
        fi
        echo "输入无效，请重试。"
    done
    echo -e "${GREEN}已选择: $IMAGE_NAME${NC}"
    TMP_IMAGE="${CACHE_DIR}/$(basename "$IMAGE_URL" || echo "rpi_image.img.xz")"
}

choose_target() {
    local current_disk="$1"
    echo ""
    echo "===================================="
    echo " 选择目标存储设备"
    echo "===================================="
    list_target_devices "$current_disk"
    local num=${#TARGET_DEVICE_LIST[@]}
    while true; do
        read -p "请输入设备编号 [1-$num]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num )); then
            local selected="${TARGET_DEVICE_LIST[$((choice-1))]}"
            [[ "$selected" == "$current_disk" ]] && { echo -e "${BOLD_RED}禁止向当前系统盘写入!${NC}"; continue; }
            TARGET_DEVICE="$selected"
            break
        fi
        echo "输入无效。"
    done
    echo -e "${GREEN}目标设备: $TARGET_DEVICE${NC}"
}

final_confirmation() {
    echo ""
    echo "===================================="
    echo -e " ${BOLD_RED}⚠ 最后确认 ⚠${NC}"
    echo "===================================="
    echo -e "镜像: ${GREEN}$IMAGE_NAME${NC}"
    echo -e "目标: ${BOLD_RED}$TARGET_DEVICE${NC}"
    echo -e "所有数据将被 ${RED}永久销毁${NC} !"
    read -p "请输入大写 YES 确认: " confirm
    [[ "$confirm" != "YES" ]] && { echo "已取消."; exit 0; }
}

#--------- 下载与校验 ----------
download_image() {
    mkdir -p "$CACHE_DIR"
    if [[ -f "$TMP_IMAGE" && -s "$TMP_IMAGE" ]]; then
        echo -e "${YELLOW}已有缓存: $TMP_IMAGE${NC}"
        select reuse in "使用缓存" "重新下载" "退出"; do
            case $REPLY in
                1) verify_checksum && return || { echo "校验失败，重新下载。"; rm -f "$TMP_IMAGE" "${TMP_IMAGE}.sha1"; break; } ;;
                2) rm -f "$TMP_IMAGE" "${TMP_IMAGE}.sha1"; break ;;
                3) echo "已取消."; exit 0 ;;
            esac
        done
    fi

    echo -e "${YELLOW}下载镜像: $IMAGE_URL${NC}"
    wget -O "$TMP_IMAGE" "$IMAGE_URL" || { echo -e "${BOLD_RED}下载失败.${NC}"; exit 1; }
    wget -O "${TMP_IMAGE}.sha1" "${IMAGE_URL}.sha1" 2>/dev/null && echo "校验文件已下载." || echo "无校验文件."
    verify_checksum || { echo -e "${BOLD_RED}SHA1 校验失败！${NC}"; exit 1; }
}

verify_checksum() {
    local sha1_file="${TMP_IMAGE}.sha1"
    [[ ! -f "$sha1_file" ]] && return 1
    local expected=$(awk '{print $1; exit}' "$sha1_file")
    local actual=$(sha1sum "$TMP_IMAGE" | awk '{print $1}')
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}SHA1 校验通过.${NC}"
        return 0
    else
        echo -e "${BOLD_RED}SHA1 校验失败.${NC}"
        return 1
    fi
}

flash_image() {
    echo -e "${YELLOW}正在烧录到 $TARGET_DEVICE ...${NC}"
    # 卸载已挂载的分区
    for part in $(lsblk -n -o NAME "$TARGET_DEVICE" 2>/dev/null | tail -n +2); do
        umount "/dev/$part" 2>/dev/null || true
    done
    rpi-imager --cli "$TMP_IMAGE" "$TARGET_DEVICE" || { echo -e "${BOLD_RED}烧录失败.${NC}"; exit 1; }
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 1
}

#--------- 挂载 boot 分区 ----------
get_boot_part() {
    [[ "$TARGET_DEVICE" =~ /dev/(mmcblk|nvme) ]] && echo "${TARGET_DEVICE}p1" || echo "${TARGET_DEVICE}1"
}

wait_for_boot_part() {
    local boot_part="$1"
    echo "等待 boot 分区 $boot_part ..."
    for i in $(seq 1 15); do
        [[ -b "$boot_part" ]] && { echo -e "${GREEN}已检测到.${NC}"; return 0; }
        sleep 1
    done
    echo -e "${BOLD_RED}boot 分区未出现.${NC}"
    return 1
}

mount_boot() {
    local boot_part="$1"
    mkdir -p "$MOUNT_POINT"
    echo "挂载 $boot_part ..."
    for i in $(seq 5 -1 1); do
        mount "$boot_part" "$MOUNT_POINT" 2>/dev/null && { echo -e "${GREEN}挂载成功.${NC}"; return 0; }
        sleep 1
    done
    echo -e "${BOLD_RED}挂载失败.${NC}"
    return 1
}

#--------- 系统预配置 (SSH, 用户, WiFi) ----------
configure_system() {
    echo ""
    echo "===================================="
    echo " 目标系统预配置（无头模式）"
    echo "===================================="

    # 1. SSH
    touch "$MOUNT_POINT/ssh"
    echo -e "${GREEN}✓ SSH 已启用.${NC}"

    # 2. 用户
    echo ""
    echo "--- 用户创建 ---"
    local username
    while true; do
        read -p "用户名 [默认 pi]: " username
        username=${username:-pi}
        if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            break
        else
            echo -e "${RED}用户名不合法。${NC}"
        fi
    done

    local password
    while true; do
        read -s -p "密码: " password; echo
        [[ -z "$password" ]] && { echo "密码不能为空"; continue; }
        read -s -p "再次输入: " password2; echo
        [[ "$password" == "$password2" ]] && break || echo "密码不一致"
    done
    local encrypted=$(echo "$password" | openssl passwd -6 -stdin 2>/dev/null)
    [[ -z "$encrypted" ]] && { echo -e "${BOLD_RED}密码哈希生成失败.${NC}"; exit 1; }
    echo "${username}:${encrypted}" > "$MOUNT_POINT/userconf.txt"
    echo -e "${GREEN}✓ 用户 $username 已配置.${NC}"

    # 3. WiFi (可选)
    CONFIG_WIFI="no"
    echo ""
    read -p "是否配置 WiFi? [y/N]: " wifi_choice
    if [[ "$wifi_choice" =~ ^[yY] ]]; then
        CONFIG_WIFI="yes"

        # 国家码选择（白名单验证，回车默认 CN）
        local allowed=("AU" "BR" "CA" "CN" "DE" "FR" "GB" "HK" "IN" "JP" "KR" "MX" "RU" "SG" "TW" "US" "ZA")
        local wifi_country
        while true; do
            read -p "WiFi 国家码（2位大写字母，回车默认 CN）: " wifi_country
            wifi_country=${wifi_country:-CN}
            # 统一转为大写
            wifi_country=$(echo "$wifi_country" | tr '[:lower:]' '[:upper:]')
            # 白名单校验
            if printf '%s\n' "${allowed[@]}" | grep -qx "$wifi_country"; then
                break
            else
                echo -e "${RED}无效国家码，请从以下列表中选择：${allowed[*]}${NC}"
            fi
        done

        # SSID
        local ssid
        while true; do
            read -p "WiFi SSID: " ssid
            [[ -z "$ssid" ]] && echo "SSID 不能为空" || break
        done

        # 密码
        local psk
        while true; do
            read -s -p "WiFi 密码: " psk; echo
            [[ -z "$psk" ]] && { echo "密码不能为空"; continue; }
            read -s -p "再次输入: " psk2; echo
            [[ "$psk" == "$psk2" ]] && break || echo "密码不一致"
        done

        # 转义特殊字符（用于 .nmconnection 文件中的双引号格式）
        local ssid_safe=$(echo "$ssid" | sed -e 's/\\/\\\\/g' -e 's/\$/\\$/g' -e 's/`/\\`/g' -e 's/"/\\"/g')
        local psk_safe=$(echo "$psk" | sed -e 's/\\/\\\\/g' -e 's/\$/\\$/g' -e 's/`/\\`/g' -e 's/"/\\"/g')

        # 生成 .nmconnection 文件（直接写入 boot 分区）
        cat > "$MOUNT_POINT/wifi-connection.nmconnection" << NMCONN
[connection]
id=${ssid_safe}
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid_safe}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk_safe}

[ipv4]
method=auto

[ipv6]
method=auto
NMCONN
        echo -e "${GREEN}✓ WiFi 配置文件已生成.${NC}"
    fi

    # 4. 生成 firstrun.sh
    cat > "$MOUNT_POINT/firstrun.sh" << 'FIRSTRUN_HEADER'
#!/bin/bash
set +ex
LOG=/boot/firmware/customise.log
[ ! -d "$(dirname "$LOG")" ] && LOG=/boot/customise.log
exec > "$LOG" 2>&1
echo "=== Firstrun started $(date) ==="

# SSH
systemctl enable ssh
systemctl start ssh

# 免密 sudo
NEW_USER=$(getent passwd 1000 | cut -d: -f1)
echo "${NEW_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/010_${NEW_USER}-nopasswd"

# 移除向导
rm -f /etc/xdg/autostart/piwiz.desktop /etc/xdg/autostart/piwiz.desktop.disabled
FIRSTRUN_HEADER

    if [[ "$CONFIG_WIFI" == "yes" ]]; then
        # 插入 WiFi 配置代码（变量展开）
        cat >> "$MOUNT_POINT/firstrun.sh" << FIRSTRUN_WIFI
# --- WiFi 部署 ---
echo "Setting WiFi country to ${wifi_country}"
raspi-config nonint do_wifi_country ${wifi_country} 2>/dev/null || true
iw reg set ${wifi_country} 2>/dev/null || true

echo "Installing WiFi profile..."
if [ -f /boot/firmware/wifi-connection.nmconnection ]; then
    cp /boot/firmware/wifi-connection.nmconnection /etc/NetworkManager/system-connections/
elif [ -f /boot/wifi-connection.nmconnection ]; then
    cp /boot/wifi-connection.nmconnection /etc/NetworkManager/system-connections/
fi

if [ -f /etc/NetworkManager/system-connections/wifi-connection.nmconnection ]; then
    chmod 600 /etc/NetworkManager/system-connections/wifi-connection.nmconnection
    echo "WiFi profile installed."
fi

systemctl enable NetworkManager 2>/dev/null || true
systemctl start NetworkManager 2>/dev/null || true
sleep 2
if command -v nmcli &>/dev/null; then
    nmcli connection reload 2>/dev/null || true
    echo "NetworkManager reloaded."
fi
FIRSTRUN_WIFI
    fi

    # 清理和自毁
    cat >> "$MOUNT_POINT/firstrun.sh" << 'FIRSTRUN_TAIL'
# 清理 cmdline.txt
if [ -f /boot/firmware/cmdline.txt ]; then
    sed -i 's| systemd.run=[^ ]*||g; s| systemd.run_success_action=[^ ]*||g; s| systemd.unit=[^ ]*||g' /boot/firmware/cmdline.txt
elif [ -f /boot/cmdline.txt ]; then
    sed -i 's| systemd.run=[^ ]*||g; s| systemd.run_success_action=[^ ]*||g; s| systemd.unit=[^ ]*||g' /boot/cmdline.txt
fi
rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh
rm -f /boot/firmware/wifi-connection.nmconnection /boot/wifi-connection.nmconnection
echo "Selfdestruct complete"
echo "=== Firstrun finished $(date) ==="
FIRSTRUN_TAIL

    chmod +x "$MOUNT_POINT/firstrun.sh"

    # 修改 cmdline.txt 触发 firstrun
    local cmdline_file
    if [[ -f "$MOUNT_POINT/cmdline.txt" ]]; then
        cmdline_file="$MOUNT_POINT/cmdline.txt"
    elif [[ -f "$MOUNT_POINT/firmware/cmdline.txt" ]]; then
        cmdline_file="$MOUNT_POINT/firmware/cmdline.txt"
    fi
    if [[ -n "$cmdline_file" ]] && ! grep -q 'systemd.run=' "$cmdline_file"; then
        sed -i '1s|$| systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target|' "$cmdline_file"
        echo -e "${GREEN}✓ cmdline.txt 已修改.${NC}"
    else
        echo -e "${YELLOW}cmdline.txt 未找到或已包含触发参数.${NC}"
    fi
}

cleanup() {
    echo "卸载 boot 分区..."
    umount "$MOUNT_POINT" 2>/dev/null || true
}

complete_message() {
    echo -e "\n===================================="
    echo -e "${GREEN} 配置完成！${NC}"
    echo "目标设备: $TARGET_DEVICE"
    if [[ "$CONFIG_WIFI" == "yes" ]]; then
        echo "WiFi 已预配置，开机自动连接。"
    fi
    echo "执行以下命令切换启动介质："
    echo "curl -O http://192.168.31.8:3000/yaha/rpi-image-tools/raw/branch/main/rpi-boot-switch.sh && chmod +x rpi-boot-switch.sh && sudo ./rpi-boot-switch.sh"
    echo "===================================="
}

#======================== 主流程 ========================
main() {
    check_root
    check_architecture
    check_command curl curl
    check_command wget wget
    check_command openssl openssl
    check_command lsblk util-linux
    check_command findmnt util-linux
    ensure_rpi_imager

    CURRENT_DISK=$(get_current_disk)
    echo -e "当前系统盘: ${BOLD_RED}${CURRENT_DISK}${NC}"

    choose_image
    choose_target "$CURRENT_DISK"
    final_confirmation
    download_image
    flash_image

    BOOT_PART=$(get_boot_part)
    wait_for_boot_part "$BOOT_PART" || exit 1
    mount_boot "$BOOT_PART" || exit 1
    configure_system
    cleanup
    complete_message
}

main "$@"