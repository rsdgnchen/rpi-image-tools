#!/bin/bash
#====================================================================
# rpi-image-flash.sh - 树莓派系统远程刷写脚本 (双向,交互式)
# 用法: sudo ./rpi-image-flash.sh
# 特性:
#   * 自动检测系统架构，仅支持 arm64 (64位)
#   * 自动检测并安装 rpi-imager 及 libopengl0 依赖  
#   * 镜像缓存复用 (避免重复下载)
#   * 支持树莓派5 NVMe (自动识别 nvme0n1)
#   * 检测当前系统盘, 禁止向其写入
#   * 使用官方 rpi-imager 烧录 (禁用 dd)
#   * 健壮的 boot 分区挂载 (节点探测 + mount 重试)
#   * 交互式无头配置 (SSH, 用户, WiFi)
#   * 在线自动获取最新镜像列表 (按发布日期排序)
#====================================================================

exec </dev/tty 2>/dev/null || true
#--------- 预置镜像变量 (离线回退用) ----------
IMAGE_LITE="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-lite.img.xz"
IMAGE_FULL="https://downloads.raspberrypi.com/raspios_full_arm64/images/raspios_full_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-full.img.xz"
TMP_IMAGE="/tmp/rpi_flash_image.img.xz"
MOUNT_POINT="/mnt"

#--------- 颜色定义 ----------
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#--------- 系统架构检查 ----------
check_architecture() {
    local arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ "$arch" != "arm64" ]] && [[ "$arch" != "aarch64" ]]; then
        echo -e "${BOLD_RED}错误: 此脚本仅支持 64 位树莓派系统 (arm64/aarch64).${NC}"
        echo -e "${RED}当前系统架构: $arch${NC}"
        echo -e "${YELLOW}请使用 Raspberry Pi OS (64-bit) 系统运行此脚本.${NC}"
        exit 1
    fi
    echo -e "${GREEN}系统架构检查通过: $arch${NC}"
}

#--------- 工具依赖检查 ----------
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

# 自动安装 rpi-imager 及其 OpenGL 依赖
ensure_rpi_imager() {
    if ! command -v rpi-imager &> /dev/null; then
        echo -e "${YELLOW}未检测到 rpi-imager, 正在自动安装...${NC}"
        if apt-get install -y rpi-imager; then
            echo -e "${GREEN}rpi-imager 安装成功.${NC}"
        else
            echo -e "${BOLD_RED}自动安装 rpi-imager 失败, 请手动安装后重试: sudo apt install rpi-imager${NC}"
            echo -e "${YELLOW}提示: 确保使用 64 位系统，并已执行 sudo apt update${NC}"
            exit 1
        fi
    fi

    if ! ldconfig -p | grep -q libOpenGL.so; then
        echo -e "${YELLOW}rpi-imager 依赖 libOpenGL.so.0 未找到, 正在自动安装 libopengl0 ...${NC}"
        if apt-get install -y libopengl0; then
            echo -e "${GREEN}libopengl0 安装成功.${NC}"
        else
            echo -e "${BOLD_RED}自动安装 libopengl0 失败, 请手动安装后重试: sudo apt install libopengl0${NC}"
            exit 1
        fi
    fi
}

#--------- 获取当前系统运行所在的磁盘 ----------
get_current_disk() {
    local root_part
    root_part=$(findmnt -n -o SOURCE /)
    local disk_name
    disk_name=$(lsblk -no PKNAME "$root_part" 2>/dev/null)
    if [[ -z "$disk_name" ]]; then
        echo -e "${BOLD_RED}错误: 无法确定当前系统磁盘.${NC}"
        exit 1
    fi
    echo "/dev/$disk_name"
}

#--------- 列出符合条件的设备 (>1GB, sd*, mmcblk*, nvme*) ----------
list_target_devices() {
    local current_disk="$1"
    echo -e "${YELLOW}正在扫描可用存储设备 (>1GB) ...${NC}"
    local devices=()
    local idx=1
    while read -r name size type; do
        if [[ "$type" != "disk" ]]; then continue; fi
        # 支持 sd*, mmcblk*, nvme*
        if [[ ! "$name" =~ ^(sd|mmcblk|nvme) ]]; then continue; fi
        local bytes
        bytes=$(lsblk -b -d -n -o SIZE "/dev/$name" 2>/dev/null)
        if [[ -z "$bytes" ]] || [[ "$bytes" -lt 1000000000 ]]; then continue; fi
        local model
        model=$(lsblk -d -n -o MODEL "/dev/$name" 2>/dev/null || echo "未知")
        devices+=("/dev/$name")
        local display_size
        display_size=$(lsblk -d -n -o SIZE "/dev/$name")
        if [[ "/dev/$name" == "$current_disk" ]]; then
            printf "%s) ${BOLD_RED}/dev/%-12s %8s %s [当前系统盘 - 禁止写入]${NC}\n" "$idx" "$name" "$display_size" "$model"
        else
            printf "%s) /dev/%-12s %8s %s\n" "$idx" "$name" "$display_size" "$model"
        fi
        ((idx++))
    done < <(lsblk -d -n -o NAME,SIZE,TYPE)
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo -e "${BOLD_RED}错误: 没有找到可写入的目标设备 (容量 > 1GB 的 sd/mmcblk/nvme 磁盘).${NC}"
        exit 1
    fi
    TARGET_DEVICE_LIST=("${devices[@]}")
}

#--------- 在线获取镜像列表 (解析官方 JSON，仅保留64位，按发布日期排序) ----------
fetch_online_image_list() {
    local json_url="https://downloads.raspberrypi.com/os_list_imagingutility_v4.json"
    local json_data
    echo -e "${YELLOW}正在从官方源获取最新镜像列表...${NC}"
    json_data=$(curl -sS --max-time 10 "$json_url" 2>/dev/null)
    if [[ -z "$json_data" ]]; then
        echo -e "${RED}无法获取镜像列表，将使用离线内置列表。${NC}"
        return 1
    fi

    # 使用 python3 解析 JSON，仅保留名称中包含 "64" 或 "arm64" 的条目
    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except:
    sys.exit(1)

entries = []
for item in data.get('os_list', []):
    if 'url' in item:
        name = item['name']
        # 仅保留 64 位镜像（名中包含 64-bit 或 arm64）
        if '64' in name or 'arm64' in name.lower():
            entries.append((item.get('release_date', '未知'), name, item['url']))
    if 'subitems' in item:
        for sub in item['subitems']:
            if 'url' in sub:
                name = sub['name']
                if '64' in name or 'arm64' in name.lower():
                    entries.append((sub.get('release_date', '未知'), name, sub['url']))

# 按发布日期倒序（最新的在前）
entries.sort(key=lambda x: x[0] if x[0] != '未知' else '0000-00-00', reverse=True)

for date, name, url in entries:
    print(f'{date}|{name}|{url}')
" <<< "$json_data" 2>/dev/null)

    if [[ -z "$parsed" ]]; then
        echo -e "${RED}解析镜像列表失败或无可用的64位镜像，将使用离线内置列表。${NC}"
        return 1
    fi

    # 保存到全局数组
    ONLINE_DATES=()
    ONLINE_NAMES=()
    ONLINE_URLS=()
    while IFS='|' read -r date name url; do
        [[ -z "$name" || -z "$url" ]] && continue
        ONLINE_DATES+=("$date")
        ONLINE_NAMES+=("$name")
        ONLINE_URLS+=("$url")
    done <<< "$parsed"

    if [[ ${#ONLINE_NAMES[@]} -eq 0 ]]; then
        echo -e "${RED}在线64位镜像列表为空，将使用离线内置列表。${NC}"
        return 1
    fi
    echo -e "${GREEN}成功获取 ${#ONLINE_NAMES[@]} 个64位在线镜像（按发布日期排列）。${NC}"
    return 0
}

#--------- 显示在线镜像菜单（仅64位，按发布日期排列）---------
show_online_menu() {
    echo "===================================="
    echo " 在线镜像列表（仅64位，按发布日期降序）"
    echo "===================================="
    printf "%-4s %-12s %-45s\n" "编号" "发布日期" "镜像名称"
    echo "--------------------------------------------------------------"
    local idx=1
    for i in "${!ONLINE_NAMES[@]}"; do
        printf "%2d)  %-12s %s\n" "$idx" "${ONLINE_DATES[$i]}" "${ONLINE_NAMES[$i]}"
        ((idx++))
    done
    echo "--------------------------------------------------------------"
    echo " 0) 自定义镜像 URL"
    echo "===================================="
}

#--------- 离线镜像菜单（硬编码）---------
show_offline_menu() {
    echo "===================================="
    echo " 离线镜像列表（预置）"
    echo "===================================="
    echo "1) Raspberry Pi OS Lite (64-bit)"
    echo "2) Raspberry Pi OS Full (64-bit)"
    echo "0) 自定义镜像 URL"
    echo "===================================="
}

#--------- 选择镜像 ----------
choose_image() {
    # 尝试在线获取
    local online_mode=0
    if fetch_online_image_list; then
        online_mode=1
    fi

    while true; do
        if [[ $online_mode -eq 1 ]]; then
            show_online_menu
            local total=${#ONLINE_NAMES[@]}
            read -p "请输入编号 [0-${total}]: " img_choice
            if [[ "$img_choice" == "0" ]]; then
                read -p "请输入自定义镜像下载链接: " custom_url
                if [[ -n "$custom_url" ]]; then
                    IMAGE_URL="$custom_url"
                    IMAGE_NAME="自定义镜像"
                    break
                else
                    echo "URL 不能为空。"
                    continue
                fi
            elif [[ "$img_choice" =~ ^[0-9]+$ ]] && (( img_choice >= 1 && img_choice <= total )); then
                local index=$(( img_choice - 1 ))
                IMAGE_URL="${ONLINE_URLS[$index]}"
                IMAGE_NAME="${ONLINE_NAMES[$index]} (${ONLINE_DATES[$index]})"
                break
            else
                echo "输入无效，请重试。"
            fi
        else
            show_offline_menu
            read -p "请输入数字 [0-2]: " img_choice
            if [[ "$img_choice" == "0" ]]; then
                read -p "请输入自定义镜像下载链接: " custom_url
                if [[ -n "$custom_url" ]]; then
                    IMAGE_URL="$custom_url"
                    IMAGE_NAME="自定义镜像"
                    break
                else
                    echo "URL 不能为空。"
                    continue
                fi
            elif [[ "$img_choice" == "1" ]]; then
                IMAGE_URL="$IMAGE_LITE"
                IMAGE_NAME="Raspberry Pi OS Lite (64-bit)"
                break
            elif [[ "$img_choice" == "2" ]]; then
                IMAGE_URL="$IMAGE_FULL"
                IMAGE_NAME="Raspberry Pi OS Full (64-bit)"
                break
            else
                echo "输入无效，请重试。"
            fi
        fi
    done
    echo -e "${GREEN}已选择: $IMAGE_NAME${NC}"
}

#--------- 选择目标设备 ----------
choose_target() {
    local current_disk="$1"
    echo ""
    echo "===================================="
    echo " 选择目标存储设备"
    echo "===================================="
    list_target_devices "$current_disk"
    local num=${#TARGET_DEVICE_LIST[@]}
    local choice
    while true; do
        read -p "请输入设备编号 [1-$num]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num )); then
            local selected="${TARGET_DEVICE_LIST[$((choice-1))]}"
            if [[ "$selected" == "$current_disk" ]]; then
                echo -e "${BOLD_RED}安全拒绝: 禁止向当前系统磁盘 ($selected) 写入! 请选择其他设备.${NC}"
                continue
            fi
            TARGET_DEVICE="$selected"
            break
        else
            echo "输入无效, 请重试."
        fi
    done
    echo -e "${GREEN}目标设备: $TARGET_DEVICE${NC}"
}

#--------- 最终确认 ----------
final_confirmation() {
    echo ""
    echo "===================================="
    echo -e " ${BOLD_RED}⚠ 最后确认 ⚠${NC}"
    echo "===================================="
    echo -e "将使用镜像: ${GREEN}$IMAGE_NAME${NC}"
    echo -e "烧录至设备: ${BOLD_RED}$TARGET_DEVICE${NC}"
    echo -e "该设备上的所有数据将被 ${RED}永久销毁${NC} !"
    echo "===================================="
    read -p "请输入大写 YES 确认操作: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "操作已取消."
        exit 0
    fi
}

#--------- 下载镜像 (带缓存复用) ----------
download_image() {
    echo ""
    # 检查是否已有缓存文件
    if [[ -f "$TMP_IMAGE" ]] && [[ -s "$TMP_IMAGE" ]]; then
        echo -e "${YELLOW}检测到已有镜像文件: $TMP_IMAGE${NC}"
        local file_size
        file_size=$(stat -c %s "$TMP_IMAGE" 2>/dev/null || echo 0)
        echo -e "文件大小: $file_size 字节"
        echo "1) 使用已有镜像 (跳过下载)"
        echo "2) 重新下载 (覆盖)"
        echo "3) 退出脚本"
        read -p "请选择 [1-3]: " reuse_choice
        case "$reuse_choice" in
            1)
                echo -e "${GREEN}使用缓存镜像, 跳过下载.${NC}"
                return
                ;;
            2)
                echo "将重新下载并覆盖旧镜像..."
                rm -f "$TMP_IMAGE"
                ;;
            3)
                echo "操作已取消."
                exit 0
                ;;
            *)
                echo "输入无效, 默认重新下载."
                rm -f "$TMP_IMAGE"
                ;;
        esac
    fi

    echo -e "${YELLOW}正在下载镜像到 $TMP_IMAGE ...${NC}"
    rm -f "$TMP_IMAGE"
    if wget -O "$TMP_IMAGE" "$IMAGE_URL"; then
        echo -e "${GREEN}下载成功.${NC}"
    else
        echo -e "${BOLD_RED}错误: 镜像下载失败, 请检查网络或镜像地址.${NC}"
        rm -f "$TMP_IMAGE"
        exit 1
    fi
}

#--------- 烧录镜像 (使用 rpi-imager) ----------
flash_image() {
    echo ""
    echo -e "${YELLOW}正在烧录镜像到 $TARGET_DEVICE ...${NC}"

    # 先卸载目标设备的所有分区
    local part_prefix
    if [[ "$TARGET_DEVICE" =~ /dev/(mmcblk|nvme) ]]; then
        part_prefix="${TARGET_DEVICE}p"
    else
        part_prefix="${TARGET_DEVICE}"
    fi
    for part in $(lsblk -n -o NAME "$TARGET_DEVICE" 2>/dev/null | tail -n +2); do
        umount "/dev/$part" 2>/dev/null || true
    done

    if rpi-imager --cli "$TMP_IMAGE" "$TARGET_DEVICE"; then
        echo -e "${GREEN}烧录完成.${NC}"
    else
        echo -e "${BOLD_RED}错误: rpi-imager 烧录失败.${NC}"
        exit 1
    fi
    partprobe "$TARGET_DEVICE" 2>/dev/null || true
    sleep 1
}

#--------- 获取 boot 分区设备名 ----------
get_boot_part() {
    if [[ "$TARGET_DEVICE" =~ /dev/(mmcblk|nvme) ]]; then
        echo "${TARGET_DEVICE}p1"
    else
        echo "${TARGET_DEVICE}1"
    fi
}

#--------- 等待 boot 分区节点出现 ----------
wait_for_boot_part() {
    local boot_part="$1"
    echo -e "${YELLOW}等待 boot 分区 $boot_part 出现 (最多 15 秒) ...${NC}"
    for i in $(seq 1 15); do
        if [[ -b "$boot_part" ]]; then
            echo -e "${GREEN}Boot 分区已检测到.${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${BOLD_RED}错误: $boot_part 在 15 秒内未出现.${NC}"
    return 1
}

#--------- 挂载 boot 分区 (带重试) ----------
mount_boot() {
    local boot_part="$1"
    mkdir -p "$MOUNT_POINT"
    echo -e "${YELLOW}尝试挂载 $boot_part ...${NC}"
    local retries=5
    while (( retries > 0 )); do
        if mount "$boot_part" "$MOUNT_POINT" 2>/dev/null; then
            echo -e "${GREEN}挂载成功.${NC}"
            return 0
        fi
        echo "挂载失败, 1秒后重试 (剩余 $retries 次)..."
        sleep 1
        ((retries--))
    done
    echo -e "${BOLD_RED}错误: 无法挂载 $boot_part , 请检查.${NC}"
    return 1
}

#--------- 预配置系统 (SSH, 用户, WiFi) ----------
configure_system() {
    echo ""
    echo "===================================="
    echo " 目标系统预配置 (无头模式)"
    echo "===================================="

    # 1) 开启 SSH
    touch "$MOUNT_POINT/ssh"
    echo -e "${GREEN}✓ SSH 已启用 (ssh 文件已创建).${NC}"

    # 2) 创建用户
    echo ""
    read -p "请输入用户名 [默认 pi]: " username
    username=${username:-pi}
    while true; do
        read -s -p "请输入密码 (隐藏输入): " password
        echo
        if [[ -z "$password" ]]; then
            echo "密码不能为空, 请重试."
            continue
        fi
        read -s -p "再次输入密码: " password2
        echo
        if [[ "$password" != "$password2" ]]; then
            echo "两次密码不一致, 请重试."
        else
            break
        fi
    done
    local encrypted
    encrypted=$(echo "$password" | openssl passwd -6 -stdin)
    if [[ -z "$encrypted" ]]; then
        echo -e "${BOLD_RED}错误: 密码哈希生成失败.${NC}"
        exit 1
    fi
    echo "${username}:${encrypted}" > "$MOUNT_POINT/userconf.txt"
    echo -e "${GREEN}✓ 用户 $username 已配置 (userconf.txt).${NC}"

    # 3) 可选 WiFi 配置
    echo ""
    read -p "是否配置 WiFi? (y/N): " set_wifi
    if [[ "$set_wifi" =~ ^[Yy]$ ]]; then
        read -p "请输入 SSID: " wifi_ssid
        if [[ -z "$wifi_ssid" ]]; then
            echo "SSID 不能为空, 跳过 WiFi 配置."
        else
            read -s -p "请输入 WiFi 密码: " wifi_psk
            echo
            if [[ -z "$wifi_psk" ]]; then
                echo "密码不能为空, 跳过 WiFi 配置."
            else
                local country
                read -p "请输入国家码 (2字母, 默认 CN): " country
                country=${country:-CN}
                country=${country^^}
                cat > "$MOUNT_POINT/wpa_supplicant.conf" << EOF
country=$country
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="$wifi_ssid"
    psk="$wifi_psk"
}
EOF
                echo -e "${GREEN}✓ WiFi 配置已写入 (wpa_supplicant.conf).${NC}"
            fi
        fi
    else
        echo "跳过 WiFi 配置."
    fi
}

#--------- 清理 ----------
cleanup() {
    echo ""
    echo -e "${YELLOW}正在卸载 boot 分区...${NC}"
    umount "$MOUNT_POINT" 2>/dev/null || true
    echo "临时挂载点已清理."
}

complete_message() {
    echo ""
    echo "===================================="
    echo -e "${GREEN} 系统刷写与预配置已完成!${NC}"
    echo "===================================="
    echo -e "目标设备: ${BOLD_RED}$TARGET_DEVICE${NC}"
    echo ""
    echo "请使用已有的介质启动切换脚本, 将系统切换到"
    echo "目标设备, 然后重启。"
    echo "例如: sudo reboot"
    echo "===================================="
}

#======================== 主流程 ========================
main() {
    check_root
    check_architecture  # 新增架构检查，禁止32位系统
    check_command curl curl
    check_command wget wget
    check_command openssl openssl
    check_command lsblk util-linux
    check_command findmnt util-linux
    ensure_rpi_imager

    CURRENT_DISK=$(get_current_disk)
    echo -e "当前系统运行在磁盘: ${BOLD_RED}${CURRENT_DISK}${NC}"

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