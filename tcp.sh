#!/bin/bash

# ==================================================
# --- 0. 基础配置与环境检查 ---
# ==================================================
SCRIPT_PATH="/usr/local/bin/tcp.sh"
SHORTCUT_PATH="/usr/local/bin/t"

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m错误: 必须使用 root 权限运行此脚本！\033[0m"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

draw_line() {
    echo -e "${YELLOW}--------------------------------------------------${NC}"
}

# 带状态的输出辅助函数
print_ok() { echo -e "  ${GREEN}✔${NC} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_fail() { echo -e "  ${RED}✘${NC} $1"; }
print_info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

# ==================================================
# --- 1. 自动安装与快捷键设置 ---
# ==================================================
if [ "$_" != "$SCRIPT_PATH" ] && [ "$0" != "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}>>> 正在安装脚本到本地系统...${NC}"
    mkdir -p /usr/local/bin

    curl -sL "https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    if [ ! -f "$SHORTCUT_PATH" ] || [ ! -L "$SHORTCUT_PATH" ]; then
        ln -sf "$SCRIPT_PATH" "$SHORTCUT_PATH"
        echo -e "${GREEN}✅ 快捷命令 't' 已创建，以后在任意地方输入 t 即可打开面板。${NC}"
    fi

    exec bash "$SCRIPT_PATH"
    exit 0
fi

# ==================================================
# --- 2. 脚本维护模块 ---
# ==================================================
check_update() {
    printf "${YELLOW}正在同步最新脚本...${NC}\n"
    curl -sL "https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh" -o "$SCRIPT_PATH.tmp"
    if [ $? -eq 0 ] && [ -s "$SCRIPT_PATH.tmp" ]; then
        mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        printf "${GREEN}脚本更新成功！正在重新载入...${NC}\n"
        sleep 1
        exec bash "$SCRIPT_PATH"
    else
        rm -f "$SCRIPT_PATH.tmp"
        printf "${RED}更新失败，请检查网络。${NC}\n"
    fi
}

uninstall_script() {
    echo -e "\n${RED}>>> 正在准备完全卸载脚本与快捷键...${NC}"
    read -p "确定要卸载吗？(这也会同时回退所有网络优化设置) [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在回退脚本写入的网络配置...${NC}"
        rollback_all &>/dev/null
        rm -f "$SHORTCUT_PATH"
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}✅ 卸载成功！网络已恢复，脚本与快捷键 't' 已从系统中移除。${NC}\n"
        exit 0
    else
        echo -e "${GREEN}已取消卸载。${NC}"
        sleep 1
    fi
}

# ==================================================
# --- 3. 功能模块 ---
# ==================================================
SYSCTL_OPT="/etc/sysctl.d/99-network-performance.conf"
SYSCTL_BBR="/etc/sysctl.d/10-bbr.conf"
LIMITS_OPT="/etc/security/limits.d/99-network-performance.conf"
STATE_DIR="/var/lib/tcp-opt"
STATE_FILE="$STATE_DIR/original-values"

# --------------------------------------------------
# 3a. IPv4 优先解析
# --------------------------------------------------
set_ipv4_priority() {
    echo -e "\n${YELLOW}>>> 正在调整系统互联网协议优先级...${NC}"

    # 如果 gai.conf 不存在，创建标准模板
    if [ ! -f /etc/gai.conf ]; then
        cat > /etc/gai.conf <<'EOF'
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence  ::/96         20
precedence  ::ffff:0:0/96 10
EOF
    fi

    # 备份（只在第一次时创建）
    [ ! -f /etc/gai.conf.bak ] && cp /etc/gai.conf /etc/gai.conf.bak

    # 先删除所有相关行（不管有没有 #），再追加正确的行。幂等操作。
    sed -i '/precedence ::ffff:0:0\/96/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

    print_ok "系统已设置为 ${GREEN}IPv4 优先${NC}，DNS 解析将优先返回 A 记录。"
    print_info "这能避免 IPv6 默认路由绕路导致的握手卡顿。"
    read -p "按回车返回..."
}

# --------------------------------------------------
# 3b. BBR + FQ 拥塞控制
# --------------------------------------------------
enable_bbr() {
    echo -e "\n${YELLOW}>>> 正在激活 BBR + FQ 拥塞算法...${NC}"
    save_original_values

    # 检查内核是否支持 BBR
    if ! modprobe tcp_bbr &>/dev/null && ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        print_fail "当前内核不支持 BBR，请升级到 4.9+ 内核。"
        read -p "按回车返回..."
        return
    fi

    cat > "$SYSCTL_BBR" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system &>/dev/null

    # 验证是否生效
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
        print_ok "BBR + FQ 已成功激活。"
    else
        print_warn "设置已写入但可能未完全生效，当前状态: cc=$current_cc qdisc=$current_qdisc"
    fi

    # 检测实际 BBR 版本
    local kernel_ver=$(uname -r | cut -d. -f1-2)
    local major=$(echo "$kernel_ver" | cut -d. -f1)
    local minor=$(echo "$kernel_ver" | cut -d. -f2)
    if [ "$major" -gt 6 ] || ([ "$major" -eq 6 ] && [ "$minor" -ge 12 ]); then
        print_info "内核版本 $(uname -r) >= 6.12，当前运行的是 ${GREEN}BBRv3${NC}。"
    else
        print_info "内核版本 $(uname -r)，当前运行的是 ${CYAN}BBRv1/v2${NC}。升级到 6.12+ 可获得 BBRv3。"
    fi

    draw_line
    printf "  %-26s : ${GREEN}%s${NC}\n" "Congestion Control" "$current_cc"
    printf "  %-26s : ${GREEN}%s${NC}\n" "Packet Scheduler (qdisc)" "$current_qdisc"
    draw_line

    read -p "按回车返回..."
}

save_original_values() {
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_FILE" ] && return

    {
        printf 'tcp_congestion_control=%s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
        printf 'default_qdisc=%s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)"
        printf 'ip_forward=%s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
        printf 'ipv6_forwarding=%s\n' "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"
    } > "$STATE_FILE"
}

get_state_value() {
    local key="$1"
    local fallback="$2"
    if [ -f "$STATE_FILE" ]; then
        awk -F= -v key="$key" '$1 == key {print $2; found=1} END {exit !found}' "$STATE_FILE" 2>/dev/null || echo "$fallback"
    else
        echo "$fallback"
    fi
}

add_mss_clamp_rule() {
    command -v iptables &>/dev/null || return
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        print_info "MSS Clamp 规则已存在，跳过重复添加。"
    else
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        print_ok "MSS Clamp 规则已部署 (防止跨境 MTU 超限丢包)"
    fi
}

remove_mss_clamp_rules() {
    command -v iptables &>/dev/null || return
    while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
        true
    done
}

build_cpu_mask() {
    local cpu_count="$1"
    local full_groups=$((cpu_count / 32))
    local remainder=$((cpu_count % 32))
    local groups=()
    local i

    for ((i = 0; i < full_groups; i++)); do
        groups+=("ffffffff")
    done
    if [ "$remainder" -gt 0 ]; then
        groups+=("$(printf '%x' $(((1 << remainder) - 1)))")
    fi

    local mask=""
    for ((i = ${#groups[@]} - 1; i >= 0; i--)); do
        if [ -z "$mask" ]; then
            mask="${groups[$i]}"
        else
            mask="$mask,${groups[$i]}"
        fi
    done

    echo "$mask"
}

# --------------------------------------------------
# 3c. 内核深度调优
# --------------------------------------------------
smart_tune() {
    local mode="${1:-common}"
    local enable_forward=0
    local mode_name="通用保守调优"

    if [ "$mode" = "transit" ]; then
        enable_forward=1
        mode_name="中转增强调优"
    fi

    echo -e "\n${YELLOW}>>> 正在启动系统环境扫描...${NC}"
    save_original_values

    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local cpu_count=$(nproc)
    local mem_mb=$((mem_total_kb / 1024))

    # 动态缓冲区：基于总内存 5%，最小 4MB，最大 256MB
    local buf_bytes=$((mem_total_kb * 5 / 100 * 1024))
    local buf_min=$((4 * 1024 * 1024))
    local buf_max=$((256 * 1024 * 1024))
    [ "$buf_bytes" -lt "$buf_min" ] && buf_bytes=$buf_min
    [ "$buf_bytes" -gt "$buf_max" ] && buf_bytes=$buf_max

    # udp_mem 的单位是内存页，不是字节；按内存动态给上限，避免小内存机器被固定大值压住。
    local page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    local udp_max_pages=$((buf_bytes / page_size))
    [ "$udp_max_pages" -lt 65536 ] && udp_max_pages=65536
    local udp_pressure_pages=$((udp_max_pages / 2))
    local udp_min_pages=$((udp_max_pages / 4))

    # conntrack 表大小：基于内存动态计算，最小 65536
    local conntrack_max=$((mem_total_kb / 16))
    [ "$conntrack_max" -lt 65536 ] && conntrack_max=65536

    # 保存优化前的旧值用于对比
    local old_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local old_somax=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "128")
    local old_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    local old_file=$(ulimit -n)

    echo -e "  核心数: ${CYAN}${cpu_count}${NC} | 内存: ${CYAN}${mem_mb}MB${NC}"
    echo -e "  模式: ${CYAN}${mode_name}${NC}"
    echo -e "  动态缓冲区: ${CYAN}$((buf_bytes / 1024 / 1024))MB${NC} (总内存 5%, 范围 4-256MB)"
    echo -e "  Conntrack 表: ${CYAN}${conntrack_max}${NC} 条目"

    echo -e "\n${YELLOW}>>> 正在写入内核参数配置...${NC}"

    cat > "$SYSCTL_OPT" <<EOF
# ===== TCP/UDP 网络性能调优 =====
# 由 tcp.sh 自动生成，勿手动编辑

# --- BBR + FQ ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 连接队列与端口 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65535

# --- TCP 缓冲区 (动态计算: 总内存 5%) ---
net.core.rmem_max = ${buf_bytes}
net.core.wmem_max = ${buf_bytes}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 ${buf_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${buf_bytes}

# --- UDP 缓冲区 (Hysteria2/QUIC 高并发) ---
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = ${udp_min_pages} ${udp_pressure_pages} ${udp_max_pages}

# --- 连接稳定性与快速回收 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_orphans = 32768

# --- 跨境链路专项 ---
# 降低发送队列积压，减少 TTFB
net.ipv4.tcp_notsent_lowat = 16384
# MTU 探测：解决 ICMP 被阻断导致的连接黑洞
net.ipv4.tcp_mtu_probing = 1
# ECN: 设为 2 = 服务端被动响应，不主动请求（避免跨境 SYN 被干扰）
net.ipv4.tcp_ecn = 2

# --- 确保关键特性显式开启 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# --- Conntrack 连接跟踪表 (动态计算) ---
net.netfilter.nf_conntrack_max = ${conntrack_max}
# 缩短 conntrack 超时，加速条目回收
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF

    if [ "$enable_forward" -eq 1 ]; then
        cat >> "$SYSCTL_OPT" <<'EOF'

# --- 中转/VPN/代理转发专用 ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    fi

    # 确保 nf_conntrack 模块已加载（否则 sysctl 会报错）
    modprobe nf_conntrack &>/dev/null || true

    local sysctl_log="/tmp/tcp-opt-sysctl.log"
    sysctl --system >"$sysctl_log" 2>&1
    local sysctl_exit=$?

    # 文件句柄与进程限制
    mkdir -p /etc/security/limits.d/
    cat > "$LIMITS_OPT" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF

    # MSS Clamp 只在中转增强模式启用，普通 VPS 不默认改防火墙规则。
    if [ "$enable_forward" -eq 1 ]; then
        add_mss_clamp_rule
    else
        local saved_ip_forward=$(get_state_value "ip_forward" "0")
        local saved_ipv6_forwarding=$(get_state_value "ipv6_forwarding" "0")
        sysctl -w "net.ipv4.ip_forward=$saved_ip_forward" &>/dev/null
        sysctl -w "net.ipv6.conf.all.forwarding=$saved_ipv6_forwarding" &>/dev/null
        remove_mss_clamp_rules
    fi

    # 刷新当前会话限制
    ulimit -n 1048576 2>/dev/null || true

    # 输出对比结果
    echo -e "\n${GREEN}✅ 内核调优完成，配置变更对比:${NC}"
    draw_line
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "拥塞算法" "$old_cc" "bbr"
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "最大连接队列" "$old_somax" "65535"
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "文件句柄" "$old_file" "1048576"
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "网络缓冲" "$((old_rmem / 1024 / 1024))MB" "$((buf_bytes / 1024 / 1024))MB"
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "Conntrack" "65536" "$conntrack_max"
    if [ "$enable_forward" -eq 1 ]; then
        printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "IP 转发" "—" "已开启"
    else
        printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "IP 转发" "—" "已恢复/未改动"
    fi
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "ECN 模式" "—" "被动响应(2)"
    draw_line

    # 检查 sysctl 是否有参数写入失败（常见于 conntrack 模块未加载等）
    if [ $sysctl_exit -ne 0 ]; then
        print_warn "部分参数可能未生效，详情见 $sysctl_log。"
    fi

    print_info "调优配置已持久化至 ${PURPLE}$SYSCTL_OPT${NC}"
    print_info "systemd 服务如需高文件句柄，还应在 unit 中单独设置 LimitNOFILE。"
    print_info "重启后配置依然生效，回退请使用选项 6。"

    read -p "按回车返回..."
}

# --------------------------------------------------
# 3d. 网卡多核中断分发 (RPS)
# --------------------------------------------------
optimize_nic() {
    echo -e "\n${YELLOW}>>> 正在执行多核心中断分发 (RPS/RFS) 优化...${NC}"

    if ! command -v ethtool &>/dev/null; then
        echo -e "${YELLOW}正在安装 ethtool...${NC}"
        apt-get update -qq && apt-get install -y -qq ethtool 2>/dev/null || yum install -y -q ethtool 2>/dev/null || true
    fi

    # 过滤出物理/主网络接口，排除虚拟接口
    local interfaces=$(ls /sys/class/net | grep -vE '^(lo|docker[0-9]*|veth|br-|virbr|any|sit[0-9]*|tun[0-9]*|tap[0-9]*|wg[0-9]*|dummy)$')
    local cpu_count=$(nproc)

    if [ "$cpu_count" -le 1 ]; then
        print_warn "当前系统只有 1 个 CPU 核心，RPS 分发无实际效果。"
        read -p "按回车返回..."
        return
    fi

    # 计算 RPS CPU 掩码（所有核心参与）
    local rps_cpus=$(build_cpu_mask "$cpu_count")

    local configured=0
    for eth in $interfaces; do
        [ ! -d "/sys/class/net/$eth" ] && continue

        # 尝试调整环形缓冲区（VPS 上大概率失败，静默处理）
        local max_rx=$(ethtool -g "$eth" 2>/dev/null | awk '/Pre-set maximums/{found=1} found && /RX:/{print $2; exit}')
        local max_tx=$(ethtool -g "$eth" 2>/dev/null | awk '/Pre-set maximums/{found=1} found && /TX:/{print $2; exit}')
        if [ -n "$max_rx" ]; then
            ethtool -G "$eth" rx "$max_rx" 2>/dev/null || true
        fi
        if [ -n "$max_tx" ]; then
            ethtool -G "$eth" tx "$max_tx" 2>/dev/null || true
        fi

        # 设置 RPS：将每个 RX 队列的处理分发到所有 CPU
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do
            [ -f "$rps_file" ] && echo "$rps_cpus" > "$rps_file"
        done

        # 设置 RFS：每个 RX 队列的流表大小
        for rfc_file in /sys/class/net/$eth/queues/rx-*/rps_flow_cnt; do
            [ -f "$rfc_file" ] && echo "4096" > "$rfc_file"
        done

        print_ok "接口 ${CYAN}$eth${NC}: RPS 掩码=0x${rps_cpus} (覆盖 ${cpu_count} 核心)"
        configured=$((configured + 1))
    done

    # 全局 RFS 表
    sysctl -w net.core.rps_sock_flow_entries=32768 &>/dev/null

    if [ "$configured" -eq 0 ]; then
        print_warn "未找到可配置的网络接口。"
    else
        echo -e "\n${GREEN}✅ RPS/RFS 配置完成:${NC}"
        draw_line
        printf "  %-22s : ${GREEN}%s${NC}\n" "配置接口数" "$configured"
        printf "  %-22s : ${GREEN}%s 核心${NC}\n" "CPU 分发范围" "$cpu_count"
        printf "  %-22s : ${GREEN}%s${NC}\n" "全局流表 (RFS)" "32768"
        draw_line
        print_info "RPS 是软件级数据包分发（非硬件 RSS），在 VPS 虚拟网卡上是最佳方案。"
        print_info "注意：RPS 设置不持久化，重启后需重新执行。"
    fi

    read -p "按回车返回..."
}

# --------------------------------------------------
# 3e. 一键回退
# --------------------------------------------------
rollback_all() {
    # 1. 清理所有配置文件
    rm -f "$SYSCTL_OPT" "$LIMITS_OPT" "$SYSCTL_BBR"

    # 2. 恢复 gai.conf
    if [ -f /etc/gai.conf.bak ]; then
        mv /etc/gai.conf.bak /etc/gai.conf
    else
        sed -i '/precedence ::ffff:0:0\/96  100/d' /etc/gai.conf 2>/dev/null || true
    fi

    # 3. 尽量恢复首次运行前的关键值；没有状态文件时回落到常见默认值
    local old_cc=$(get_state_value "tcp_congestion_control" "cubic")
    local old_qdisc=$(get_state_value "default_qdisc" "fq_codel")
    local old_ip_forward=$(get_state_value "ip_forward" "0")
    local old_ipv6_forwarding=$(get_state_value "ipv6_forwarding" "0")
    sysctl -w "net.ipv4.tcp_congestion_control=$old_cc" &>/dev/null
    sysctl -w "net.core.default_qdisc=$old_qdisc" &>/dev/null
    sysctl -w "net.ipv4.ip_forward=$old_ip_forward" &>/dev/null
    sysctl -w "net.ipv6.conf.all.forwarding=$old_ipv6_forwarding" &>/dev/null

    # 4. 恢复 RPS/RFS
    sysctl -w net.core.rps_sock_flow_entries=0 &>/dev/null
    local interfaces=$(ls /sys/class/net | grep -vE '^(lo|docker[0-9]*|veth|br-|virbr|any|sit[0-9]*|tun[0-9]*|tap[0-9]*|wg[0-9]*|dummy)$')
    for eth in $interfaces; do
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do
            [ -f "$rps_file" ] && echo "0" > "$rps_file"
        done
    done

    # 5. 清理 MSS Clamp 规则
    remove_mss_clamp_rules

    # 6. 恢复当前会话文件句柄限制
    ulimit -n 1024 2>/dev/null || true

    # 7. 重载系统配置
    sysctl --system &>/dev/null

    echo -e "${GREEN}✅ 回退完成:${NC}"
    print_ok "配置文件已清理: sysctl, limits, bbr"
    print_ok "拥塞算法已恢复: $old_cc + $old_qdisc"
    print_ok "IP 转发已恢复: IPv4=$old_ip_forward IPv6=$old_ipv6_forwarding"
    print_ok "RPS/RFS 已关闭"
    print_ok "MSS Clamp 规则已移除"
    print_ok "IPv4 优先解析已恢复"
    rm -f "$STATE_FILE"
}

# ==================================================
# --- 4. 主菜单 ---
# ==================================================
while true; do
    # --- 实时状态检测 ---
    if [ -f /etc/gai.conf ] && grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        status_ipv4="${GREEN}[已激活]${NC}"
    else
        status_ipv4="${RED}[未开启]${NC}"
    fi

    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        status_bbr="${GREEN}[已激活]${NC}"
    else
        status_bbr="${RED}[未开启]${NC}"
    fi

    if [ -f "$SYSCTL_OPT" ]; then
        if grep -q "^net.ipv4.ip_forward = 1" "$SYSCTL_OPT" 2>/dev/null; then
            status_common="${GREEN}[已包含]${NC}"
            status_transit="${GREEN}[已激活]${NC}"
        else
            status_common="${GREEN}[已激活]${NC}"
            status_transit="${RED}[未开启]${NC}"
        fi
    else
        status_common="${RED}[未开启]${NC}"
        status_transit="${RED}[未开启]${NC}"
    fi

    if [ "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" = "32768" ]; then
        status_nic="${GREEN}[已激活]${NC}"
    else
        status_nic="${RED}[未开启]${NC}"
    fi

    # --- 渲染菜单 ---
    clear
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}         VPS NetPilot - TCP/UDP 调优面板        ${NC}"
    echo -e "${GREEN}  github.com/sanmussh/vps-netpilot${NC}"
    echo -e "${GREEN}                   快捷命令: t                     ${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "  1. 设置 IPv4 优先解析     $status_ipv4  解决 IPv6 绕路卡顿"
    echo -e "  2. 开启 BBR + FQ          $status_bbr  降低丢包/提升吞吐"
    echo -e "  3. 通用保守内核调优       $status_common  缓冲区/连接/conntrack"
    echo -e "  4. 中转增强调优           $status_transit  通用调优 + IP 转发/MSS Clamp"
    echo -e "  5. 网卡多核分发 (RPS)     $status_nic  消除单核 SoftIRQ 瓶颈"
    echo -e "  6. 一键回退脚本配置"
    echo -e "  7. 检查并强制同步更新脚本"
    echo -e "  8. 彻底卸载面板脚本"
    echo -e "  0. 退出脚本"
    draw_line
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    cur_fd=$(ulimit -n)
    cur_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    echo -e "  算法: ${GREEN}${cur_cc}${NC} | 队列: ${GREEN}${cur_qdisc}${NC} | 句柄: ${GREEN}${cur_fd}${NC} | 转发: ${GREEN}${cur_fwd}${NC}"
    draw_line

    read -p "请选择 [0-8]: " t_opt
    case "$t_opt" in
        1) set_ipv4_priority ;;
        2) enable_bbr ;;
        3) smart_tune common ;;
        4) smart_tune transit ;;
        5) optimize_nic ;;
        6) rollback_all && read -p "按回车返回..." ;;
        7) check_update ;;
        8) uninstall_script ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请输入 0-8！${NC}" && sleep 1 ;;
    esac
done
