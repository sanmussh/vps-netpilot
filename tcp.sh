#!/bin/bash

# ==================================================
# --- 0. 基础配置与环境检查 ---
# ==================================================
SCRIPT_PATH="/usr/local/bin/tcp.sh"
SHORTCUT_PATH="/usr/local/bin/t"
SCRIPT_URL="https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh"
umask 022
set -o pipefail

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

download_script() {
    local tmp
    command -v curl >/dev/null || { print_fail "请先安装 curl。"; return 1; }
    tmp=$(mktemp "${SCRIPT_PATH}.XXXXXX") || return 1
    if ! curl -fSL --connect-timeout 10 --max-time 90 --retry 2 "$SCRIPT_URL" -o "$tmp" ||
       ! head -n 1 "$tmp" | grep -Eq '^#!/(bin/bash|usr/bin/env bash)$' ||
       ! grep -q 'VPS NetPilot' "$tmp" || ! bash -n "$tmp"; then
        rm -f -- "$tmp"
        print_fail "下载或脚本校验失败，原脚本未替换。"
        return 1
    fi
    if ! chmod 755 "$tmp" || ! mv -f -- "$tmp" "$SCRIPT_PATH"; then
        rm -f -- "$tmp"
        print_fail "脚本写入失败。"
        return 1
    fi
}

# ==================================================
# --- 1. 自动安装与快捷键设置 ---
# ==================================================
if [ "$(readlink -f -- "$0" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}>>> 正在安装脚本到本地系统...${NC}"
    mkdir -p /usr/local/bin || exit 1
    download_script || exit 1

    if [ ! -f "$SHORTCUT_PATH" ] || [ ! -L "$SHORTCUT_PATH" ]; then
        ln -sf "$SCRIPT_PATH" "$SHORTCUT_PATH" || exit 1
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
    if download_script; then
        printf "${GREEN}脚本更新成功！正在重新载入...${NC}\n"
        exec 9>&-
        exec bash "$SCRIPT_PATH"
    fi
}

uninstall_script() {
    echo -e "\n${RED}>>> 正在准备完全卸载脚本与快捷键...${NC}"
    read -p "确定要卸载吗？(这也会同时回退所有网络优化设置) [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}正在回退脚本写入的网络配置...${NC}"
        if ! rollback_all; then
            print_fail "回退尚未完成，保留脚本和快照，请先处理上面的失败项。"
            return 1
        fi
        rm -f "$SHORTCUT_PATH" "$SCRIPT_PATH" || return 1
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
GAI_FILE="/etc/gai.conf"
NET_CLASS_DIR="/sys/class/net"
MSS_TAG="vps-netpilot"
RESOLV_FILE="/etc/resolv.conf"
DNS_STUB_FILE="/run/systemd/resolve/stub-resolv.conf"
DNS_UPLINK_FILE="/run/systemd/resolve/resolv.conf"
DNS_RESOLVED_CONF="/etc/systemd/resolved.conf.d/99-vps-netpilot-dns.conf"
DNS_NM_CONF="/etc/NetworkManager/conf.d/99-vps-netpilot-dns.conf"
DNS_NM_UPSTREAM="/run/NetworkManager/no-stub-resolv.conf"

# 同目录临时文件保证替换原子性；写入失败时保留原文件。
atomic_write() {
    local target="$1" mode="${2:-600}" tmp
    [ ! -L "$target" ] || { print_fail "拒绝覆盖符号链接: $target" >&2; return 1; }
    tmp=$(mktemp "${target}.XXXXXX") || return 1
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}

ensure_state() {
    [ "${STATE_READY:-0}" = 1 ] && return 0
    mkdir -p "$STATE_DIR/files" || return 1
    chmod 700 "$STATE_DIR" "$STATE_DIR/files" || return 1
    if { [ -f "$STATE_FILE" ] && ! grep -qx '# vps-netpilot-state-v2' "$STATE_FILE"; } ||
       { [ ! -f "$STATE_FILE" ] && [ -f "$SYSCTL_OPT" ]; }; then
        printf '%s\n' '旧版未记录完整原值；补充快照仅代表升级时的状态。' |
            atomic_write "$STATE_DIR/legacy-incomplete" || return 1
    fi
    if [ ! -f "$STATE_FILE" ] || ! grep -qx '# vps-netpilot-state-v2' "$STATE_FILE"; then
        local tmp
        tmp=$(mktemp "${STATE_FILE}.XXXXXX") || return 1
        if ! printf '# vps-netpilot-state-v2\n' > "$tmp"; then rm -f -- "$tmp"; return 1; fi
        if [ -f "$STATE_FILE" ]; then
            if ! awk -F= '
                    $1=="tcp_congestion_control" {$1="net.ipv4.tcp_congestion_control"}
                    $1=="default_qdisc" {$1="net.core.default_qdisc"}
                    $1=="ip_forward" {$1="net.ipv4.ip_forward"}
                    $1=="ipv6_forwarding" {$1="net.ipv6.conf.all.forwarding"}
                    /^net\./ {print $1 "=" $2}
                ' "$STATE_FILE" >> "$tmp"; then rm -f -- "$tmp"; return 1; fi
        fi
        if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$STATE_FILE"; then
            rm -f -- "$tmp"; return 1
        fi
    fi
    if [ -f "$STATE_DIR/legacy-incomplete" ]; then
        print_warn "旧版快照不完整：已知原值保留，其余仅能恢复到升级时的状态。"
    fi
    STATE_READY=1
}

snapshot_value() {
    local key="$1" value="$2" tmp
    ensure_state || return 1
    if awk -F= -v k="$key" '$1==k {found=1} END {exit !found}' "$STATE_FILE"; then
        return 0
    fi
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || return 1
    if ! cp -- "$STATE_FILE" "$tmp" || ! printf '%s=%s\n' "$key" "$value" >> "$tmp" ||
       ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$STATE_FILE"; then
        rm -f -- "$tmp"; return 1
    fi
}

get_state_value() {
    local key="$1"
    [ -f "$STATE_FILE" ] || return 1
    awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1); found=1; exit}
        END {exit !found}' "$STATE_FILE"
}

backup_managed_file() {
    local target="$1" id="$2" kind
    ensure_state || return 1
    kind="$STATE_DIR/files/$id.kind"
    [ -f "$kind" ] && return 0
    [ ! -L "$target" ] || { print_fail "拒绝修改符号链接: $target"; return 1; }
    # 旧版生成文件应在回退时删除，不能把它们当作调优前的配置恢复。
    if [ -f "$STATE_DIR/legacy-incomplete" ] && [[ "$id" =~ ^(bbr|opt|limits)$ ]]; then
        printf 'absent\n' | atomic_write "$kind"
    elif [ -e "$target" ]; then
        local tmp
        tmp=$(mktemp "$STATE_DIR/files/$id.XXXXXX") || return 1
        if ! cp -p -- "$target" "$tmp" || ! mv -f -- "$tmp" "$STATE_DIR/files/$id.original"; then
            rm -f -- "$tmp"; return 1
        fi
        printf 'present\n' | atomic_write "$kind"
    else
        printf 'absent\n' | atomic_write "$kind"
    fi
}

restore_managed_file() {
    local target="$1" id="$2" kind="$STATE_DIR/files/$2.kind" tmp
    [ -f "$kind" ] || return 0
    case "$(cat "$kind")" in
        absent) rm -f -- "$target" ;;
        present)
            [ ! -L "$target" ] || return 1
            tmp=$(mktemp "${target}.XXXXXX") || return 1
            if ! cp -p -- "$STATE_DIR/files/$id.original" "$tmp" || ! mv -f -- "$tmp" "$target"; then
                rm -f -- "$tmp"; return 1
            fi ;;
        *) return 1 ;;
    esac
}

normalize_value() { awk '{$1=$1; print}'; }

restore_sysctl_values() {
    local file="$1" key value actual failed=0
    while IFS='=' read -r key value; do
        [[ "$key" == net.* ]] || continue
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_value)
        [ "$actual" != "$(printf '%s\n' "$value" | normalize_value)" ] || continue
        if ! sysctl -q -w "$key=$value" 2>/dev/null; then
            print_warn "未能恢复 $key"; failed=1; continue
        fi
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_value)
        if [ "$actual" != "$(printf '%s\n' "$value" | normalize_value)" ]; then
            print_warn "恢复后读回不一致: $key"; failed=1
        fi
    done < "$file"
    return "$failed"
}

# 仅应用本脚本的参数；失败项不持久化，提交失败则恢复本次调用前的值。
# 返回值: 0 全部成功，2 部分参数被拒绝，1 文件/快照错误。
apply_sysctl_config() {
    local source="$1" target="$2" id="$3" strict="${4:-0}"
    local output journal line key value before actual rejected=0 failed=0
    [ -s "$source" ] && [ -r "$source" ] || return 1
    backup_managed_file "$target" "$id" || return 1
    output=$(mktemp "${target}.XXXXXX") || return 1
    journal=$(mktemp "$STATE_DIR/apply.XXXXXX") || { rm -f -- "$output"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
            printf '%s\n' "$line" >> "$output" || { failed=1; break; }
            continue
        fi
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        value=$(printf '%s\n' "${line#*=}" | normalize_value)
        if [[ ! "$key" =~ ^net\.[a-zA-Z0-9_.]+$ ]] || [[ "$line" != *=* ]]; then
            print_fail "无效参数行: $line"; failed=1; break
        fi
        if ! before=$(sysctl -n "$key" 2>/dev/null); then
            print_warn "跳过不可读取的参数: $key"
            printf '# skipped: %s\n' "$line" >> "$output" || { failed=1; break; }
            rejected=$((rejected + 1)); continue
        fi
        if ! snapshot_value "$key" "$before" || ! printf '%s=%s\n' "$key" "$before" >> "$journal"; then
            failed=1; break
        fi
        if sysctl -q -w "$key=$value" 2>/dev/null &&
           actual=$(sysctl -n "$key" 2>/dev/null | normalize_value) && [ "$actual" = "$value" ]; then
            printf '%s = %s\n' "$key" "$value" >> "$output" || { failed=1; break; }
        else
            print_warn "内核拒绝或读回不一致: $key = $value"
            actual=$(sysctl -n "$key" 2>/dev/null | normalize_value)
            if [ "$actual" != "$(printf '%s\n' "$before" | normalize_value)" ]; then
                if ! sysctl -q -w "$key=$before" 2>/dev/null ||
                   [ "$(sysctl -n "$key" 2>/dev/null | normalize_value)" != "$(printf '%s\n' "$before" | normalize_value)" ]; then
                    print_warn "无法恢复本次尝试前的值: $key"; failed=1; break
                fi
            fi
            printf '# rejected: %s\n' "$line" >> "$output" || { failed=1; break; }
            rejected=$((rejected + 1))
        fi
    done < "$source"
    if [ "$strict" = 1 ] && [ "$rejected" -gt 0 ]; then failed=1; fi
    if [ "$failed" = 0 ]; then
        chmod 644 "$output" && mv -f -- "$output" "$target" || failed=1
    fi
    if [ "$failed" != 0 ]; then
        restore_sysctl_values "$journal" || print_warn "本次参数未完全恢复，请使用选项 6 重试。"
        rm -f -- "$output" "$journal"
        return 1
    fi
    rm -f -- "$journal"
    [ "$rejected" -eq 0 ] || return 2
}

# --------------------------------------------------
# 3a. IPv4 优先解析
# --------------------------------------------------
set_ipv4_priority() {
    echo -e "\n${YELLOW}>>> 正在调整系统互联网协议优先级...${NC}"
    backup_managed_file "$GAI_FILE" gai || return 1
    local tmp
    tmp=$(mktemp "${GAI_FILE}.XXXXXX") || return 1
    if [ -f "$GAI_FILE" ]; then
        if ! sed '/^[[:space:]]*precedence[[:space:]]*::ffff:0:0\/96[[:space:]]/d' "$GAI_FILE" > "$tmp"; then
            rm -f -- "$tmp"; return 1
        fi
    fi
    if ! printf '\nprecedence ::ffff:0:0/96  100\n' >> "$tmp" ||
       ! chmod 644 "$tmp" || ! mv -f -- "$tmp" "$GAI_FILE"; then
        rm -f -- "$tmp"; print_fail "IPv4 优先配置写入失败。"; return 1
    fi
    print_ok "已调整使用 glibc 地址选择规则的应用的 IPv4 优先级。"
    read -p "按回车返回..."
}

# --------------------------------------------------
# 3b. BBR + FQ 拥塞控制
# --------------------------------------------------
get_actual_qdiscs() {
    local interfaces iface output names
    command -v ip >/dev/null && command -v tc >/dev/null || { echo '无法检测（缺少 ip/tc）'; return; }
    interfaces=$({ ip -o -4 route show default; ip -o -6 route show default; } 2>/dev/null |
        awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
    [ -n "$interfaces" ] || { echo '未发现默认出口'; return; }
    for iface in $interfaces; do
        if ! output=$(tc qdisc show dev "$iface" 2>/dev/null); then
            printf '%s: 无法读取队列\n' "$iface"; continue
        fi
        # 展示根队列和去重后的子队列类型，不将 ingress/clsact 算作发送队列。
        names=$(printf '%s\n' "$output" | awk '
            $1=="qdisc" {
                if($2=="ingress" || $2=="clsact") next
                for(i=1;i<=NF;i++) if($i=="root") root=$2
                for(i=1;i<NF;i++) if($i=="parent" && !seen[$2]++) kinds[++n]=$2
            }
            END {
                if(root=="") {print "无法识别根队列"; exit}
                printf "%s", root
                for(j=1;j<=n;j++) printf "%s%s", (j==1 ? " + " : ", "), kinds[j]
                printf "\n"
            }')
        printf '%s: %s\n' "$iface" "$names"
    done
}

get_bbr_state() {
    local current_cc="${1-$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)}"
    case "$current_cc" in
        bbr|bbr2|bbr3) echo active ;;
        '') echo unknown ;;
        *) echo inactive ;;
    esac
}

ensure_bbr_fq() {
    # 尝试加载模块后，以内核公布的可用算法列表为准。
    modprobe tcp_bbr &>/dev/null || true
    modprobe sch_fq &>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        return 1
    fi
    ensure_state || return 2
    local source result
    source=$(mktemp "$STATE_DIR/bbr.XXXXXX") || return 2
    if ! cat > "$source" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    then
        rm -f -- "$source"; return 2
    fi
    apply_sysctl_config "$source" "$SYSCTL_BBR" bbr 1
    result=$?
    rm -f -- "$source"
    [ "$result" = 0 ] || return 2
    # 仅设置系统默认值，不覆盖现有网卡队列/整形规则。
    return 0
}

enable_bbr() {
    echo -e "\n${YELLOW}>>> 正在设置 BBR 与默认 FQ 队列...${NC}"

    ensure_bbr_fq
    local bbr_result=$?
    local current_cc
    local current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [ "$bbr_result" -eq 0 ]; then
        print_ok "BBR 已设为系统默认 TCP 算法，默认队列配置已设为 FQ。"
    elif [ "$bbr_result" -eq 1 ]; then
        print_fail "当前内核未提供 BBR，请先升级到支持 BBR 的系统内核。"
    else
        print_fail "配置或校验失败，当前状态: cc=${current_cc:-未知} default_qdisc=${current_qdisc:-未知}"
    fi

    print_info "当前内核: $(uname -r)；BBR 实现版本由系统内核提供，脚本不根据内核版本号推测。"
    print_info "网卡实际队列保持不变，与默认队列不同不代表 BBR 未启用。"

    draw_line
    printf "  %-26s : ${GREEN}%s${NC}\n" "Congestion Control" "$current_cc"
    printf "  %-26s : %s\n" "Default qdisc" "$current_qdisc"
    printf '  实际出口队列:\n'
    get_actual_qdiscs | sed 's/^/    /'
    draw_line

    read -p "按回车返回..."
}

add_mss_clamp_rule() {
    command -v iptables &>/dev/null || { print_warn "未安装 iptables，MSS Clamp 未设置。"; return 1; }
    local -a rule=(-p tcp --tcp-flags SYN,RST SYN -m comment --comment "$MSS_TAG" -j TCPMSS --clamp-mss-to-pmtu)
    if iptables -t mangle -C POSTROUTING "${rule[@]}" 2>/dev/null; then
        return 0
    fi
    if iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        print_info "已有未标记的 MSS Clamp 规则，保留并复用；回退不会删除它。"
        return 0
    fi
    ensure_state || return 1
    printf 'owned\n' | atomic_write "$STATE_DIR/mss-owned" || return 1
    if ! iptables -t mangle -A POSTROUTING "${rule[@]}" ||
       ! iptables -t mangle -C POSTROUTING "${rule[@]}"; then
        print_warn "MSS Clamp 添加或验证失败。"; return 1
    fi
    print_ok "已添加带脚本标记的 MSS Clamp 规则（当前运行期有效）。"
}

mss_clamp_present() {
    command -v iptables >/dev/null || return 1
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -m comment --comment "$MSS_TAG" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||
        iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

remove_mss_clamp_rules() {
    [ -f "$STATE_DIR/mss-owned" ] || return 0
    command -v iptables &>/dev/null || return 1
    local -a rule=(-p tcp --tcp-flags SYN,RST SYN -m comment --comment "$MSS_TAG" -j TCPMSS --clamp-mss-to-pmtu)
    local result
    while true; do
        iptables -t mangle -C POSTROUTING "${rule[@]}" 2>/dev/null
        result=$?
        [ "$result" = 1 ] && break
        [ "$result" = 0 ] || return 1
        iptables -t mangle -D POSTROUTING "${rule[@]}" || return 1
    done
    rm -f -- "$STATE_DIR/mss-owned"
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
    local old_cc
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    if [ "$mode" = "transit" ]; then
        enable_forward=1
        mode_name="中转增强调优"
    fi

    echo -e "\n${YELLOW}>>> 正在启动系统环境扫描...${NC}"
    echo -e "${YELLOW}>>> 正在检查并激活 BBR + FQ...${NC}"
    ensure_bbr_fq
    local bbr_result=$?
    if [ "$bbr_result" -eq 1 ]; then
        print_fail "当前内核未提供 BBR，本次调优未执行。"
        print_info "请先升级到支持 BBR 的系统内核，再重新运行选项 3 或 4。"
        read -p "按回车返回..."
        return 1
    elif [ "$bbr_result" -ne 0 ]; then
        local current_cc
        local current_qdisc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        print_fail "BBR 配置未通过校验，停止后续调优；已保存的快照可用于回退。"
        print_info "当前状态: cc=${current_cc:-未知} qdisc=${current_qdisc:-未知}"
        read -p "按回车返回..."
        return 1
    fi
    print_ok "系统默认 BBR 和默认 FQ 配置已验证，网卡实际队列保持不变。"

    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local cpu_count=$(nproc)
    [[ "$mem_total_kb" =~ ^[1-9][0-9]*$ ]] || { print_fail "无法读取系统内存。"; return 1; }
    local mem_mb=$((mem_total_kb / 1024))

    # 动态缓冲区：基于总内存 5%，最小 4MB，最大 256MB
    local buf_bytes=$((mem_total_kb * 5 / 100 * 1024))
    local buf_min=$((4 * 1024 * 1024))
    local buf_max=$((256 * 1024 * 1024))
    [ "$buf_bytes" -lt "$buf_min" ] && buf_bytes=$buf_min
    [ "$buf_bytes" -gt "$buf_max" ] && buf_bytes=$buf_max

    # UDP 全局阈值使用内核自行计算的值，不再强制至少 65536 页。
    if [ -f "$SYSCTL_OPT" ] && grep -q '^net.ipv4.udp_mem[[:space:]]*=' "$SYSCTL_OPT"; then
        print_warn "将移除旧版 udp_mem 持久化项；缺少原值时，当前旧阈值需重启后由内核重新计算。"
    fi

    # conntrack 表大小：基于内存动态计算，最小 65536
    local conntrack_max=$((mem_total_kb / 16))
    [ "$conntrack_max" -lt 65536 ] && conntrack_max=65536

    # 保存优化前的旧值用于对比
    local old_somax=$(sysctl -n net.core.somaxconn 2>/dev/null || echo '不可读')
    local old_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo '不可读')
    local old_file=$(ulimit -n)
    local old_conntrack=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '不可读')
    local old_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '不可读')
    local old_ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo '不可读')

    echo -e "  核心数: ${CYAN}${cpu_count}${NC} | 内存: ${CYAN}${mem_mb}MB${NC}"
    echo -e "  模式: ${CYAN}${mode_name}${NC}"
    echo -e "  动态缓冲区: ${CYAN}$((buf_bytes / 1024 / 1024))MB${NC} (总内存 5%, 范围 4-256MB)"
    echo -e "  Conntrack 表: ${CYAN}${conntrack_max}${NC} 条目"

    echo -e "\n${YELLOW}>>> 正在写入内核参数配置...${NC}"

    local source
    source=$(mktemp "$STATE_DIR/tune.XXXXXX") || return 1
    if ! cat > "$source" <<EOF
# ===== TCP/UDP 网络性能调优 =====
# 由 tcp.sh 自动生成，勿手动编辑
# mode=$mode

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
# udp_mem 保留内核全局内存阈值

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
    then
        rm -f -- "$source"; print_fail "生成调优配置失败。"; return 1
    fi

    if [ "$enable_forward" -eq 1 ]; then
        if ! cat >> "$source" <<'EOF'

# --- 中转/VPN/代理转发专用 ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
        then rm -f -- "$source"; return 1; fi
    else
        # 从中转切回通用时，持久化恢复值，避免重启后再被旧转发配置开启。
        local key saved
        for key in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
            if saved=$(get_state_value "$key"); then
                printf '%s = %s\n' "$key" "$saved" >> "$source" || { rm -f -- "$source"; return 1; }
            fi
        done
    fi

    # 确保 nf_conntrack 模块已加载（否则 sysctl 会报错）
    modprobe nf_conntrack &>/dev/null || true

    apply_sysctl_config "$source" "$SYSCTL_OPT" opt
    local sysctl_exit=$?
    rm -f -- "$source"
    if [ "$sysctl_exit" = 1 ]; then
        print_fail "配置提交失败，停止后续修改；快照保留，可使用选项 6。"; return 1
    fi

    # 文件句柄与进程限制
    if ! mkdir -p "$(dirname "$LIMITS_OPT")" || ! backup_managed_file "$LIMITS_OPT" limits; then
        print_fail "无法备份 limits 配置，已保留网络参数快照。"; return 1
    fi
    if ! atomic_write "$LIMITS_OPT" 644 <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    then
        print_fail "limits 写入失败；网络参数已应用，快照保留。"; return 1
    fi

    # MSS Clamp 只在中转增强模式启用，普通 VPS 不默认改防火墙规则。
    if [ "$enable_forward" -eq 1 ]; then
        add_mss_clamp_rule || sysctl_exit=2
    else
        remove_mss_clamp_rules || { print_warn "脚本的 MSS Clamp 规则未能移除。"; sysctl_exit=2; }
    fi

    # 输出对比结果
    if [ "$sysctl_exit" = 0 ]; then
        print_ok "配置已应用，以下为实际读回值。"
    else
        print_warn "部分调优未生效，失败项已在上方列出；以下为实际读回值。"
    fi
    draw_line
    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    printf "  %-14s: %-15s -> ${GREEN}%-15s${NC}\n" "拥塞算法" "$old_cc" "$new_cc"
    printf '  %-14s: %s -> %s\n' '最大连接队列' "$old_somax" "$(sysctl -n net.core.somaxconn 2>/dev/null || echo '不可读')"
    printf '  %-14s: %s -> %s\n' '当前脚本句柄' "$old_file" "$(ulimit -n)"
    printf '  %-14s: %s -> %s\n' '接收上限(字节)' "$old_rmem" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo '不可读')"
    printf '  %-14s: %s -> %s\n' 'Conntrack' "$old_conntrack" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '不可读')"
    printf '  %-14s: %s -> %s\n' 'IPv4 转发' "$old_forward" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '不可读')"
    printf '  %-14s: %s -> %s\n' 'ECN 模式' "$old_ecn" "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo '不可读')"
    draw_line

    print_info "调优配置已持久化至 ${PURPLE}$SYSCTL_OPT${NC}"
    print_info "systemd 服务如需高文件句柄，还应在 unit 中单独设置 LimitNOFILE。"
    print_info "limits 对后续登录生效，不会修改已运行服务；回退请使用选项 6。"
    print_info "其他系统配置仍可能在重启时覆盖同名参数，请重启后复查状态。"

    read -p "按回车返回..."
    return "$sysctl_exit"
}

# --------------------------------------------------
# 3d. 网卡多核中断分发 (RPS)
# --------------------------------------------------
network_interfaces() {
    local path iface
    for path in "$NET_CLASS_DIR"/*; do
        [ -d "$path" ] || continue
        iface="${path##*/}"
        case "$iface" in lo|docker*|veth*|br-*|virbr*|sit*|tun*|tap*|wg*|dummy*) continue ;; esac
        printf '%s\n' "$iface"
    done
}

normalize_rps_value() {
    awk -F, '{for(i=1;i<=NF;i++) {sub(/^0+/,"",$i); if($i=="") $i="0"}
        start=1; while(start<NF && $start=="0") start++
        for(i=start;i<=NF;i++) printf "%s%s", (i>start ? "," : ""), $i; print ""}'
}

set_rps_value() {
    local file="$1" key="$2" value="$3" before actual
    before=$(cat "$file") || return 1
    snapshot_value "$key" "$before" || return 1
    printf '%s\n' "$value" > "$file" || return 1
    actual=$(cat "$file" | normalize_rps_value) || return 1
    [ "$actual" = "$(printf '%s\n' "$value" | normalize_rps_value)" ]
}

restore_rps_values() {
    local key value rest iface queue name file actual failed=0
    [ -f "$STATE_FILE" ] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" == rps:* ]] || continue
        rest="${key#rps:}"
        if [[ ! "$rest" =~ ^[a-zA-Z0-9_.:-]+/rx-[0-9]+/(rps_cpus|rps_flow_cnt)$ ]]; then
            print_warn "无效 RPS 快照键: $key"; failed=1; continue
        fi
        IFS=/ read -r iface queue name <<< "$rest"
        file="$NET_CLASS_DIR/$iface/queues/$queue/$name"
        if [ ! -f "$file" ]; then
            print_warn "网卡队列已不存在，保留快照: $file"; failed=1; continue
        fi
        if ! printf '%s\n' "$value" > "$file"; then failed=1; continue; fi
        actual=$(cat "$file" | normalize_rps_value)
        [ "$actual" = "$(printf '%s\n' "$value" | normalize_rps_value)" ] || failed=1
    done < "$STATE_FILE"
    return "$failed"
}

optimize_nic() {
    echo -e "\n${YELLOW}>>> 正在执行多核心中断分发 (RPS/RFS) 优化...${NC}"

    local interfaces=$(network_interfaces)
    local cpu_count=$(nproc)

    if [ "$cpu_count" -le 1 ]; then
        print_warn "当前系统只有 1 个 CPU 核心，RPS 分发无实际效果。"
        read -p "按回车返回..."
        return
    fi

    # 计算 RPS CPU 掩码（所有核心参与）
    local rps_cpus=$(build_cpu_mask "$cpu_count")

    local configured=0 failed=0 eth file queue before
    ensure_state || return 1
    for eth in $interfaces; do
        for file in "$NET_CLASS_DIR/$eth"/queues/rx-*/rps_cpus "$NET_CLASS_DIR/$eth"/queues/rx-*/rps_flow_cnt; do
            [ -f "$file" ] || continue
            queue="${file%/*}"; queue="${queue##*/}"
            local value=4096
            [ "${file##*/}" != rps_cpus ] || value="$rps_cpus"
            if set_rps_value "$file" "rps:$eth/$queue/${file##*/}" "$value"; then
                configured=$((configured + 1))
            else
                print_warn "RPS/RFS 写入或验证失败: $file"; failed=1
            fi
        done
    done

    # 全局 RFS 表
    if [ "$configured" -gt 0 ]; then
        if ! before=$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null) ||
           ! snapshot_value net.core.rps_sock_flow_entries "$before" ||
           ! sysctl -q -w net.core.rps_sock_flow_entries=32768 ||
           [ "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" != 32768 ]; then
            print_warn "全局 RFS 设置失败，快照已保留。"; failed=1
        fi
    fi

    if [ "$configured" -eq 0 ]; then
        print_warn "未找到可配置的网络接口。"
    else
        if [ "$failed" = 0 ]; then print_ok "RPS/RFS 写入并验证完成。"; else print_warn "RPS/RFS 仅部分生效。"; fi
        draw_line
        printf "  %-22s : ${GREEN}%s${NC}\n" "成功设置项" "$configured"
        printf "  %-22s : ${GREEN}%s 核心${NC}\n" "CPU 分发范围" "$cpu_count"
        printf "  %-22s : %s\n" "全局流表 (RFS)" "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null || echo '不可读')"
        draw_line
        print_info "RPS 是否有收益取决于现有硬件队列与 CPU 负载，可通过选项 6 恢复原值。"
        print_info "注意：RPS 设置不持久化，重启后需重新执行。"
    fi

    read -p "按回车返回..."
}

# --------------------------------------------------
# 3e. 系统 DNS
# --------------------------------------------------
dns_nameservers() {
    awk '$1=="nameserver" {print $2}' "$1" 2>/dev/null
}

dns_service_active() {
    command -v systemctl >/dev/null && systemctl is-active --quiet "$1"
}

dns_uses_resolved() {
    dns_service_active systemd-resolved || return 1
    case "$(readlink -f -- "$RESOLV_FILE" 2>/dev/null)" in
        "$DNS_STUB_FILE"|/usr/lib/systemd/resolv.conf|/lib/systemd/resolv.conf) return 0 ;;
        *) return 1 ;;
    esac
}

dns_uses_resolved_uplink() {
    dns_service_active systemd-resolved && [ -L "$RESOLV_FILE" ] &&
        [ "$(readlink -f -- "$RESOLV_FILE" 2>/dev/null)" = "$DNS_UPLINK_FILE" ]
}

dns_backend() {
    if dns_service_active NetworkManager; then
        if [ -L "$RESOLV_FILE" ] && ! dns_uses_resolved && ! dns_uses_resolved_uplink &&
           [ "$(readlink -f -- "$RESOLV_FILE" 2>/dev/null)" != /run/NetworkManager/resolv.conf ]; then
            echo unsupported
        else echo NetworkManager; fi
    elif dns_service_active systemd-resolved; then
        if dns_uses_resolved || dns_uses_resolved_uplink; then echo resolved; else echo unsupported; fi
    elif [ -L "$RESOLV_FILE" ] || [ ! -f "$RESOLV_FILE" ]; then
        echo unsupported
    elif dns_service_active systemd-networkd || command -v resolvconf >/dev/null ||
         ! command -v pgrep >/dev/null || pgrep -x 'dhclient|dhcpcd|udhcpc' >/dev/null ||
         grep -Eqi 'generated|managed|dhcp|cloud-init|resolvconf' "$RESOLV_FILE" ||
         grep -Eqs '^[[:space:]]*iface[[:space:]].*[[:space:]]dhcp' /etc/network/interfaces /etc/network/interfaces.d/*; then
        echo unsupported
    else
        # 只能排除常见管理程序；静态文件仍需用户确认没有启动脚本接管。
        echo static
    fi
}

show_dns() {
    local servers backend
    draw_line
    backend=$(dns_backend)
    case "$backend" in
        resolved)
            if dns_uses_resolved_uplink; then
                print_info "系统 DNS 管理方式: systemd-resolved（上游列表模式，可切换至本地解析入口）"
            else print_info "系统 DNS 管理方式: systemd-resolved（本地解析入口）"; fi ;;
        unsupported) print_info "系统 DNS 管理方式: 暂不支持自动修改" ;;
        static) print_info "系统 DNS 管理方式: 静态文件候选（需确认无其他程序接管）" ;;
        *) print_info "系统 DNS 管理方式: $backend" ;;
    esac
    [ ! -L "$RESOLV_FILE" ] || print_info "resolv.conf 指向: $(readlink -- "$RESOLV_FILE")"
    servers=$(dns_nameservers "$RESOLV_FILE")
    printf '  系统解析入口: %s\n' "$(printf '%s\n' "${servers:-无法读取}" | paste -sd ' ' -)"
    if command -v resolvectl >/dev/null && dns_service_active systemd-resolved; then
        print_info "上游 DNS（Global 为全局，Link 为网卡；不代表每次查询都会使用所有上游）:"
        LC_ALL=C resolvectl dns || print_warn "无法读取上游 DNS。"
        print_info "DNS 域路由（~. 表示默认查询路径，更具体的域优先）:"
        LC_ALL=C resolvectl domain || print_warn "无法读取 DNS 域路由。"
    elif dns_service_active NetworkManager && [ -r "$DNS_NM_UPSTREAM" ]; then
        print_info "NetworkManager 上游 DNS:"
        dns_nameservers "$DNS_NM_UPSTREAM"
    elif printf '%s\n' "$servers" | grep -Eq '^(127\.|::1$)'; then
        print_warn "检测到本地 DNS 转发器，真实上游无法仅从 resolv.conf 判断。"
    fi
    if [ -f "$STATE_DIR/dns-backend" ]; then
        print_info "有本脚本的 DNS 修改记录；记录本身不等于当前已生效。"
        if [ "$backend" = resolved ]; then
            print_info "网卡仍可能列出原 DNS；默认查询按 Global 的 ~. 路由，专用域按更具体规则处理。"
        fi
    fi
    print_info "仅管理系统 DNS，不修改 3x-ui/Xray 自定义 DNS、DoH 或客户端 DNS。"
}

dns_target() {
    case "$1" in
        NetworkManager) printf '%s\n' "$DNS_NM_CONF" ;;
        resolved) printf '%s\n' "$DNS_RESOLVED_CONF" ;;
        static) printf '%s\n' "$RESOLV_FILE" ;;
        *) return 1 ;;
    esac
}

dns_reload() {
    case "$1" in
        NetworkManager)
            dns_service_active NetworkManager &&
                nmcli --wait 15 general reload conf && nmcli --wait 15 general reload dns-full ;;
        resolved)
            # 加载失败可能使服务退出；恢复旧文件后仍需尝试启动解析器。
            timeout 20 systemctl restart systemd-resolved ;;
        static) return 0 ;;
        *) return 1 ;;
    esac
}

dns_runtime_valid() {
    local backend="$1" servers domains
    case "$backend" in
        resolved)
            dns_uses_resolved || return 1
            if [ -f "$STATE_DIR/files/dns-resolv.link" ]; then dns_stub_listener_valid || return 1; fi
            servers=$(LC_ALL=C resolvectl dns) || return 1
            domains=$(LC_ALL=C resolvectl domain) || return 1
            [ "$(printf '%s\n' "$servers" | awk '/^Global:/ {sub(/^Global:[[:space:]]*/, ""); $1=$1; print}')" = '1.1.1.1 1.0.0.1' ] || return 1
            printf '%s\n' "$domains" | awk '
                /^Global:/ {for(i=2;i<=NF;i++) if($i=="~.") found=1}
                /^Link / {for(i=1;i<=NF;i++) if($i=="~.") conflict=1}
                END {exit !(found && !conflict)}' ;;
        NetworkManager)
            # 检查实际生成的上游列表，不把连接配置中的 DHCP DNS 当作实际结果。
            if dns_uses_resolved; then
                servers=$(LC_ALL=C resolvectl dns) || return 1
                servers=$(printf '%s\n' "$servers" | awk '{sub(/^[^:]*:[[:space:]]*/, ""); for(i=1;i<=NF;i++) print $i}' | sort -u)
            else
                # 不能仅凭 NM 的生成文件判成功，系统入口可能是 unmanaged。
                servers=$(dns_nameservers "$RESOLV_FILE" | sort -u)
            fi
            [ "$servers" = $'1.0.0.1\n1.1.1.1' ] ;;
        static) [ "$(dns_nameservers "$RESOLV_FILE")" = $'1.1.1.1\n1.0.0.1' ] ;;
        *) return 1 ;;
    esac
}

# 原子替换已知符号链接；不写入目标文件，也不覆盖外部新接管的配置。
dns_replace_link() {
    local target="$1" expected="$2" tmp
    [ -L "$RESOLV_FILE" ] && [ "$(readlink -- "$RESOLV_FILE")" = "$expected" ] || return 1
    tmp=$(mktemp "${RESOLV_FILE}.XXXXXX") || return 1
    if ! ln -sfn -- "$target" "$tmp" || [ ! -L "$tmp" ] ||
       [ ! -L "$RESOLV_FILE" ] || [ "$(readlink -- "$RESOLV_FILE")" != "$expected" ] ||
       ! mv -Tf -- "$tmp" "$RESOLV_FILE"; then
        rm -f -- "$tmp"; return 1
    fi
}

dns_stub_listener_valid() {
    local pid protocol sockets
    pid=$(systemctl show -p MainPID --value systemd-resolved 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for protocol in u t; do
        sockets=$(ss -H -O -4 "-ln${protocol}p" 'sport = :53' 2>/dev/null) || return 1
        if ! printf '%s\n' "$sockets" | awk -v pid="$pid" '
            {for(i=1;i<=NF;i++) if($i ~ /^127\.0\.0\.53(%[^:]+)?:53$/ && index($0,"pid=" pid ",")) found=1}
            END {exit !found}'; then
            print_warn "无法确认 systemd-resolved 已监听 127.0.0.53:53（$protocol），不采用此入口。"
            return 1
        fi
    done
}

dns_activate_stub() {
    local original
    [ -f "$STATE_DIR/files/dns-resolv.link" ] || return 0
    original=$(cat "$STATE_DIR/files/dns-resolv.link") || return 1
    [ "$(dns_nameservers "$DNS_STUB_FILE")" = 127.0.0.53 ] || return 1
    dns_stub_listener_valid || return 1
    dns_replace_link "$DNS_STUB_FILE" "$original"
}

dns_restore_link() {
    local original current
    [ -f "$STATE_DIR/files/dns-resolv.link" ] || return 0
    original=$(cat "$STATE_DIR/files/dns-resolv.link") || return 1
    [ -n "$original" ] && [ -L "$RESOLV_FILE" ] || return 1
    current=$(readlink -- "$RESOLV_FILE") || return 1
    [ "$current" != "$original" ] || return 0
    [ "$current" = "$DNS_STUB_FILE" ] || return 1
    dns_replace_link "$original" "$DNS_STUB_FILE"
}

dns_lookup_works() {
    # 强制使用 nss-dns，避免 nss-resolve 绕过新入口而掩盖 stub 端口不可用。
    if [ -f "$STATE_DIR/files/dns-resolv.link" ]; then
        timeout 12 getent -s dns ahostsv4 example.com >/dev/null || return 1
    fi
    timeout 12 getent ahostsv4 example.com >/dev/null
}

restore_dns() {
    local backend target
    if [ ! -f "$STATE_DIR/dns-backend" ]; then
        if [ -f "$STATE_DIR/files/dns.kind" ] || [ -f "$STATE_DIR/files/dns-resolv.link" ]; then
            print_fail "DNS 快照缺少管理方式记录，请人工核对，未删除快照。"; return 1
        fi
        print_info "没有 DNS 回退记录。"; return 0
    fi
    backend=$(cat "$STATE_DIR/dns-backend")
    target=$(dns_target "$backend") || { print_fail "DNS 快照类型无效，未执行恢复。"; return 1; }
    # 恢复入口不能因外部管理方式变化而覆盖新的 resolv.conf。
    if [ "$backend" = static ] && { [ -L "$RESOLV_FILE" ] || [ "$(dns_backend)" != static ]; }; then
        print_fail "resolv.conf 已由其他程序接管，请人工核对，快照保留。"; return 1
    fi
    [ -f "$STATE_DIR/files/dns.kind" ] || { print_fail "DNS 文件快照缺失。"; return 1; }
    [ ! -L "$target" ] || { print_fail "DNS 配置路径已变成符号链接，快照保留。"; return 1; }
    if ! dns_restore_link; then
        print_fail "DNS 入口链接恢复失败或已由外部修改，配置和快照保留。"; return 1
    fi
    if ! restore_managed_file "$target" dns || ! dns_reload "$backend"; then
        print_fail "DNS 恢复或重新加载失败，快照保留，请重试。"; return 1
    fi
    rm -f -- "$STATE_DIR/dns-backend" "$STATE_DIR/files/dns.kind" "$STATE_DIR/files/dns.original" \
        "$STATE_DIR/files/dns-resolv.link" || return 1
    print_ok "已恢复修改前的 DNS 配置；动态 DNS 继续由原管理服务提供。"
}

set_cloudflare_dns() {
    local backend target domains tmp original_link="" stub_setting=""
    backend=$(dns_backend)
    target=$(dns_target "$backend") || {
        print_fail "未识别出可安全持久化的管理方式（可能是独立 DHCP、resolvconf、容器或未知链接）。"
        print_info "未修改 DNS。请先核对网络配置来源，不能直接覆盖 resolv.conf。"; return 1
    }
    command -v timeout >/dev/null && command -v getent >/dev/null || {
        print_fail "缺少 timeout/getent，无法完成有时限的解析验证，未修改。"; return 1
    }
    if [ -f "$STATE_DIR/dns-backend" ]; then
        if [ "$(cat "$STATE_DIR/dns-backend")" = "$backend" ] && dns_runtime_valid "$backend"; then
            print_info "已有本脚本的配置，当前上游检查通过；不覆盖原始快照。"; return 0
        fi
        print_fail "已有 DNS 修改记录且当前状态不一致，请先用 DNS 子菜单恢复后重试。"; return 1
    fi
    if [ -f "$STATE_DIR/files/dns.kind" ] || [ -f "$STATE_DIR/files/dns-resolv.link" ]; then
        print_fail "发现不完整的 DNS 快照，请先人工核对 $STATE_DIR/files/dns.*，未继续修改。"; return 1
    fi
    case "$backend" in
        NetworkManager)
            command -v nmcli >/dev/null || return 1
            if dns_service_active systemd-resolved; then command -v resolvectl >/dev/null || return 1; fi ;;
        resolved)
            command -v resolvectl >/dev/null || return 1
            domains=$(LC_ALL=C resolvectl domain) || return 1
            if printf '%s\n' "$domains" | grep -Eq '^Link .*:.*[[:space:]]~\.([[:space:]]|$)'; then
                print_fail "网卡/VPN 已配置默认 DNS 域路由 ~.，不覆盖，需先人工核对。"; return 1
            fi
            if dns_uses_resolved_uplink; then
                command -v ss >/dev/null || { print_fail "缺少 ss（iproute2），无法验证本地 DNS 监听端口，未修改。"; return 1; }
                original_link=$(readlink -- "$RESOLV_FILE") || return 1
                stub_setting='DNSStubListener=yes'
            fi ;;
    esac
    ensure_state && mkdir -p -- "$(dirname -- "$target")" && backup_managed_file "$target" dns || return 1
    printf '%s\n' "$backend" | atomic_write "$STATE_DIR/dns-backend" || return 1
    if [ -n "$original_link" ]; then
        printf '%s\n' "$original_link" | atomic_write "$STATE_DIR/files/dns-resolv.link" || return 1
    fi
    tmp=$(mktemp "$STATE_DIR/dns-config.XXXXXX") || { restore_dns; return 1; }
    # 备选地址属于 DNS 列表；FallbackDNS 仅在没有其他 DNS 配置时使用。
    case "$backend" in
        NetworkManager)
            printf '[global-dns-domain-*]\nservers=1.1.1.1,1.0.0.1\n' > "$tmp" ;;
        resolved)
            printf '[Resolve]\nDNS=\nDNS=1.1.1.1 1.0.0.1\nFallbackDNS=\nDomains=~.\n%s\n' "$stub_setting" > "$tmp" ;;
        static)
            # 保留 search/options 等非 nameserver 设置。
            awk '$1!="nameserver" {print} END {print "nameserver 1.1.1.1"; print "nameserver 1.0.0.1"}' "$RESOLV_FILE" > "$tmp" ;;
    esac
    if [ "$?" = 0 ] && atomic_write "$target" 644 < "$tmp" &&
       dns_reload "$backend" && dns_activate_stub && dns_runtime_valid "$backend" && dns_lookup_works; then
        rm -f -- "$tmp"
        print_ok "默认 DNS 配置已写入磁盘，上游检查和系统解析测试通过。"
        print_info "DNS 列表：1.1.1.1（首选）、1.0.0.1（备选）；未重启网卡、Xray 或 3x-ui。"
        print_info "实际使用哪个上游由解析器决定，不保证备选只在首选超时时使用。"
        print_info "专用域路由可能继续使用内网 DNS；应用已有连接/缓存不会立即改变。"
        print_info "重启后可用选项 9 再检查，外部管理工具仍可能覆盖配置。"
        return 0
    fi
    rm -f -- "$tmp"
    print_fail "写入、加载、上游检查或解析测试失败，正在恢复修改前配置。"
    restore_dns || print_fail "自动恢复未完成，请保留当前 SSH 会话并处理 DNS 回退记录。"
    return 1
}

dns_menu() {
    local choice confirm backend
    while true; do
        show_dns
        printf '\n  1. 设置 DNS：1.1.1.1 首选 / 1.0.0.1 备选（持久化）\n  2. 恢复修改前的 DNS 配置\n  0. 返回主菜单\n'
        read -r -p "请选择 [0-2]: " choice || return 0
        case "$choice" in
            1)
                backend=$(dns_backend)
                print_warn "1.1.1.1 / 1.0.0.1 不保证更快；仅 IPv6 的 VPS 无法直接访问这些 IPv4 地址。"
                print_info "按上述顺序配置 DNS；解析器可能在切换后继续使用备选，并非严格主备。"
                print_warn "可能影响内网域名/VPN 分流；NetworkManager 全局 DNS 会覆盖连接级 DNS。"
                if [ "$backend" = resolved ] && dns_uses_resolved_uplink; then
                    print_info "将备份原链接，并切换至本地入口 127.0.0.53，由它使用上述 DNS 列表。"
                    print_info "会重启 DNS 解析服务，不重启网卡；DNS 子菜单恢复时会还原原链接。"
                fi
                if [ "$backend" = static ]; then
                    print_warn "静态文件候选：请确认没有 DHCP、cloud-init 或启动脚本重写 resolv.conf。"
                fi
                read -r -p "确认切换系统 DNS？[y/N]: " confirm || return 0
                [[ "$confirm" =~ ^[Yy]$ ]] && set_cloudflare_dns
                read -r -p "按回车继续..." || return 0 ;;
            2) restore_dns; read -r -p "按回车继续..." || return 0 ;;
            0) return 0 ;;
            *) print_warn "请输入 0-2。" ;;
        esac
    done
}

# --------------------------------------------------
# 3f. 一键回退
# --------------------------------------------------
rollback_all() {
    if [ ! -f "$STATE_FILE" ] && [ ! -d "$STATE_DIR/files" ] &&
       [ ! -f "$SYSCTL_OPT" ] && [ ! -f "$STATE_DIR/mss-owned" ] && [ ! -f "$STATE_DIR/dns-backend" ]; then
        print_info "没有本脚本的回退记录，系统参数保持不变。"
        return 0
    fi
    ensure_state || { print_fail "无法读取或迁移快照。"; return 1; }
    local failed=0 id path
    if [ -f "$STATE_DIR/dns-backend" ] || [ -f "$STATE_DIR/files/dns.kind" ] ||
       [ -f "$STATE_DIR/files/dns-resolv.link" ]; then
        restore_dns || failed=1
    fi
    for id in bbr opt limits gai; do
        case "$id" in
            bbr) path="$SYSCTL_BBR" ;; opt) path="$SYSCTL_OPT" ;;
            limits) path="$LIMITS_OPT" ;; gai) path="$GAI_FILE" ;;
        esac
        if [ -f "$STATE_DIR/legacy-incomplete" ] && [ "$id" != gai ] && [ ! -f "$STATE_DIR/files/$id.kind" ]; then
            backup_managed_file "$path" "$id" || { failed=1; continue; }
        fi
        restore_managed_file "$path" "$id" || { print_warn "文件未能恢复: $path"; failed=1; }
    done
    restore_sysctl_values "$STATE_FILE" || failed=1
    restore_rps_values || failed=1
    remove_mss_clamp_rules || { print_warn "带脚本标记的 MSS 规则未能移除。"; failed=1; }

    if [ "$failed" != 0 ]; then
        print_fail "回退仅部分成功，未完成项目的快照保留，请处理失败项后重试。"
        return 1
    fi
    if [ -f "$STATE_DIR/legacy-incomplete" ]; then
        print_warn "已恢复可追溯的参数并移除旧调优配置，但旧版缺失的历史值无法自动恢复。"
        print_info "快照保留在 $STATE_DIR。重启可重新计算内核默认值，但不等于恢复历史手工设置。"
        print_info "旧版未标记的 MSS 规则、RPS 和 gai.conf.bak 请人工核对；未自动删除或套用。"
        return 2
    fi
    for id in bbr opt limits gai; do
        rm -f -- "$STATE_DIR/files/$id.kind" "$STATE_DIR/files/$id.original" || return 1
    done
    rm -f -- "$STATE_FILE" || return 1
    rmdir "$STATE_DIR/files" 2>/dev/null || true
    STATE_READY=0
    print_ok "本脚本记录的原值和配置已恢复，新增 MSS 规则已移除。"
    print_info "原有防火墙规则、网卡队列和未被本脚本修改的设置保持不变。"
}

config_matches_runtime() {
    local file="$1" line key value actual count=0
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == '# skipped:'* || "$line" == '# rejected:'* ]] && return 1
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        key="${line%%=*}"; key="${key//[[:space:]]/}"
        value=$(printf '%s\n' "${line#*=}" | normalize_value)
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_value) || return 1
        [ "$actual" = "$value" ] || return 1
        count=$((count + 1))
    done < "$file"
    [ "$count" -gt 0 ]
}

# ==================================================
# --- 4. 主菜单 ---
# ==================================================
# 串行化配置与快照写入；更新 exec 前释放锁。
if command -v flock >/dev/null; then
    mkdir -p /run/lock || exit 1
    exec 9>/run/lock/vps-netpilot.lock || exit 1
    flock -n 9 || { print_fail "另一个 VPS NetPilot 正在运行。"; exit 1; }
fi
while true; do
    # --- 实时状态检测 ---
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [ -f "$GAI_FILE" ] && grep -q "^precedence ::ffff:0:0/96  100" "$GAI_FILE" 2>/dev/null; then
        status_ipv4="${GREEN}[已激活]${NC}"
    else
        status_ipv4="${RED}[未开启]${NC}"
    fi

    actual_qdiscs=$(get_actual_qdiscs)
    case "$(get_bbr_state "$cur_cc")" in
        active) status_bbr="${GREEN}[BBR 已启用]${NC}" ;;
        unknown) status_bbr="${YELLOW}[无法确认]${NC}" ;;
        *) status_bbr="${RED}[BBR 未启用]${NC}" ;;
    esac

    if [ -f "$SYSCTL_OPT" ]; then
        tune_status="${GREEN}[已激活]${NC}"
        config_matches_runtime "$SYSCTL_OPT" || tune_status="${YELLOW}[部分生效]${NC}"
        if grep -qx '# mode=transit' "$SYSCTL_OPT" ||
           { ! grep -q '^# mode=' "$SYSCTL_OPT" && grep -q '^net.ipv4.ip_forward = 1' "$SYSCTL_OPT"; }; then
            mss_clamp_present || tune_status="${YELLOW}[部分生效]${NC}"
            status_common="$tune_status"
            status_transit="$tune_status"
        else
            status_common="$tune_status"
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
    echo -e "  2. 开启 BBR / 设置默认 FQ $status_bbr"
    echo -e "  3. 通用保守内核调优       $status_common  缓冲区/连接/conntrack"
    echo -e "  4. 中转增强调优           $status_transit  通用调优 + IP 转发/MSS Clamp"
    echo -e "  5. 网卡多核分发 (RPS)     $status_nic  消除单核 SoftIRQ 瓶颈"
    echo -e "  6. 一键回退脚本配置"
    echo -e "  7. 检查并强制同步更新脚本"
    echo -e "  8. 彻底卸载面板脚本"
    echo -e "  9. 系统 DNS 检测与设置"
    echo -e "  0. 退出脚本"
    draw_line
    cur_fd=$(ulimit -n)
    cur_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    echo -e "  默认 TCP 算法: ${cur_cc:-未知} | 默认队列配置: ${cur_qdisc:-未知}"
    printf '  实际出口队列:\n'
    printf '%s\n' "$actual_qdiscs" | sed 's/^/    /'
    echo -e "  当前脚本句柄: $cur_fd | IPv4 转发: ${cur_fwd:-未知}"
    draw_line

    read -r -p "请选择 [0-9]: " t_opt || exit 0
    case "$t_opt" in
        1) set_ipv4_priority ;;
        2) enable_bbr ;;
        3) smart_tune common ;;
        4) smart_tune transit ;;
        5) optimize_nic ;;
        6) rollback_all; read -r -p "按回车返回..." ;;
        7) check_update ;;
        8) uninstall_script ;;
        9) dns_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请输入 0-9！${NC}" && sleep 1 ;;
    esac
done
