#!/bin/bash

# macOS-Route-Splitter - macOS 网络路由分流器
# 智能分流中国大陆IP和国际IP到不同网卡
# 作者: Claude
# 项目: https://github.com/JAM2199562/macos-route-splitter

set -e

# 配置变量
DEMO_INTERFACE="en19"  # DEMO Mobile Boardband 网卡
WIFI_INTERFACE="en0"   # WiFi 网卡
CHINA_IP_LIST="/tmp/china_ip_list.txt"
DNS_SERVER=""  # DNS服务器将由用户输入
DNS_BACKUP_FILE="/tmp/dns_backup_$(date +%Y%m%d_%H%M%S).txt"
USE_PF_ROUTING=false  # 是否使用pf进行路由（实验性功能）

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 验证IP地址格式
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a ip_parts=($ip)
        for part in "${ip_parts[@]}"; do
            if ((part > 255)); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 测试DNS服务器连通性
test_dns_server() {
    local dns_server=$1
    log_info "测试DNS服务器 $dns_server 的连通性..."
    
    if ping -c 1 -W 3000 "$dns_server" >/dev/null 2>&1; then
        log_info "DNS服务器 $dns_server 连通正常"
        return 0
    else
        log_warn "DNS服务器 $dns_server 连通失败，但仍可继续设置"
        return 1
    fi
}

# 获取DNS服务器地址
get_dns_server() {
    while true; do
        echo ""
        echo -e "${GREEN}请输入DNS服务器地址:${NC}"
        echo "常用DNS服务器:"
        echo "  8.8.8.8       (Google DNS)"
        echo "  1.1.1.1       (Cloudflare DNS)"
        echo "  223.5.5.5     (阿里DNS)"
        echo "  114.114.114.114 (114DNS)"
        echo "  10.8.4.21     (原默认DNS)"
        echo ""
        read -p "DNS服务器地址: " dns_input
        
        if [[ -z "$dns_input" ]]; then
            log_error "DNS服务器地址不能为空，请重新输入"
            continue
        fi
        
        if validate_ip "$dns_input"; then
            DNS_SERVER="$dns_input"
            log_info "已设置DNS服务器: $DNS_SERVER"
            
            # 可选测试连通性
            echo ""
            read -p "是否测试DNS服务器连通性? [y/N]: " test_connectivity
            if [[ "$test_connectivity" =~ ^[Yy]$ ]]; then
                test_dns_server "$DNS_SERVER"
            fi
            
            break
        else
            log_error "无效的IP地址格式，请重新输入"
        fi
    done
}

# 检查DEMO网卡是否存在
check_demo_interface() {
    log_info "检查DEMO Mobile Boardband网卡是否存在..."
    
    if networksetup -listallhardwareports | grep -q "DEMO Mobile Boardband"; then
        log_info "找到DEMO Mobile Boardband网卡: $DEMO_INTERFACE"
        
        # 检查网卡是否已激活
        if ifconfig $DEMO_INTERFACE | grep -q "inet "; then
            DEMO_IP=$(ifconfig $DEMO_INTERFACE | grep 'inet ' | awk '{print $2}')
            DEMO_GATEWAY=$(route -n get default dev $DEMO_INTERFACE 2>/dev/null | grep gateway | awk '{print $2}' || echo "")
            log_info "DEMO网卡IP: $DEMO_IP"
            if [[ -n "$DEMO_GATEWAY" ]]; then
                log_info "DEMO网卡网关: $DEMO_GATEWAY"
            else
                log_warn "未检测到DEMO网卡网关，将尝试自动获取"
            fi
            return 0
        else
            log_error "DEMO网卡未激活或未获取到IP地址"
            return 1
        fi
    else
        log_error "未找到DEMO Mobile Boardband网卡"
        return 1
    fi
}

# 下载中国IP地址段
download_china_ip_list() {
    log_info "下载中国IP地址段列表..."
    
    # 如果文件存在且是今天创建的，则跳过下载
    if [[ -f "$CHINA_IP_LIST" ]] && [[ $(date -r "$CHINA_IP_LIST" +%Y%m%d) == $(date +%Y%m%d) ]]; then
        log_info "使用缓存的中国IP地址段列表"
        return 0
    fi
    
    # 创建临时文件
    local temp_file="/tmp/china_ip_temp.txt"
    
    # 优先从国内镜像源下载
    local sources=(
        "https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
        "https://ispip.clang.cn/all_cn.txt"
        "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"
    )
    
    for source in "${sources[@]}"; do
        log_info "尝试从 $source 下载..."
        
        if [[ "$source" == *"apnic"* ]]; then
            # APNIC数据需要特殊处理
            if curl -s --connect-timeout 10 "$source" | \
               grep "apnic|CN|ipv4" | \
               awk -F'|' '{print $4"/"int(32-log($5)/log(2))}' > "$temp_file"; then
                
                if [[ -s "$temp_file" ]]; then
                    mv "$temp_file" "$CHINA_IP_LIST"
                    local count=$(wc -l < "$CHINA_IP_LIST")
                    log_info "成功从APNIC下载 $count 个中国IP地址段"
                    return 0
                fi
            fi
        else
            # 直接下载CIDR格式的IP列表
            if curl -s --connect-timeout 10 "$source" > "$temp_file"; then
                # 验证文件格式
                if grep -q "^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+" "$temp_file"; then
                    mv "$temp_file" "$CHINA_IP_LIST"
                    local count=$(wc -l < "$CHINA_IP_LIST")
                    log_info "成功下载 $count 个中国IP地址段"
                    return 0
                fi
            fi
        fi
        
        rm -f "$temp_file"
        log_warn "从 $source 下载失败，尝试下一个源"
    done
    
    log_error "所有IP地址段下载源都失败"
    return 1
}

# 备用：使用本地预设的主要中国IP段
create_backup_china_ip_list() {
    log_warn "使用备用的中国IP地址段列表"
    
    cat > "$CHINA_IP_LIST" << 'EOF'
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
1.0.32.0/19
1.1.0.0/24
1.1.8.0/24
1.1.63.0/24
1.2.0.0/23
1.2.4.0/22
1.2.8.0/21
1.4.1.0/24
1.4.2.0/23
1.4.5.0/24
1.8.0.0/16
1.12.0.0/14
1.16.0.0/12
1.45.0.0/16
1.48.0.0/15
1.50.0.0/16
1.51.0.0/16
1.56.0.0/13
1.68.0.0/14
1.80.0.0/13
1.92.0.0/14
1.116.0.0/14
1.180.0.0/14
1.184.0.0/13
1.192.0.0/13
1.202.0.0/15
1.204.0.0/14
14.0.0.0/10
27.0.0.0/9
36.0.0.0/10
39.64.0.0/11
42.0.0.0/8
49.0.0.0/11
58.0.0.0/9
59.32.0.0/11
60.0.0.0/8
61.0.0.0/10
101.0.0.0/9
103.0.0.0/8
110.0.0.0/7
112.0.0.0/9
113.0.0.0/8
114.0.0.0/8
115.0.0.0/8
116.0.0.0/8
117.0.0.0/8
118.0.0.0/7
120.0.0.0/6
124.0.0.0/8
125.0.0.0/8
EOF
    
    log_info "创建了备用中国IP地址段列表"
}

# 备份当前路由表
backup_routes() {
    log_info "备份当前路由表..."
    local backup_file="/tmp/route_backup_$(date +%Y%m%d_%H%M%S).txt"
    
    route -n get default > "$backup_file" 2>/dev/null || true
    netstat -rn >> "$backup_file" 2>/dev/null || true
    
    log_info "路由表已备份到: $backup_file"
    echo "$backup_file"
}

# 备份当前DNS设置
backup_dns() {
    log_info "备份当前DNS设置..."
    
    # 获取Wi-Fi的DNS设置
    networksetup -getdnsservers "Wi-Fi" > "$DNS_BACKUP_FILE" 2>/dev/null || echo "Empty" > "$DNS_BACKUP_FILE"
    
    # 同时记录其他网卡的DNS设置
    echo "=== 所有网卡DNS设置 ===" >> "$DNS_BACKUP_FILE"
    networksetup -listallnetworkservices | while read service; do
        if [[ "$service" != "An asterisk (*) denotes that a network service is disabled." ]]; then
            echo "[$service]" >> "$DNS_BACKUP_FILE"
            networksetup -getdnsservers "$service" >> "$DNS_BACKUP_FILE" 2>/dev/null || echo "Error getting DNS" >> "$DNS_BACKUP_FILE"
            echo "" >> "$DNS_BACKUP_FILE"
        fi
    done
    
    log_info "DNS设置已备份到: $DNS_BACKUP_FILE"
}

# 设置DNS服务器
setup_dns() {
    log_info "设置DNS服务器为 $DNS_SERVER..."
    
    # 为Wi-Fi设置DNS服务器
    if networksetup -setdnsservers "Wi-Fi" "$DNS_SERVER"; then
        log_info "成功为Wi-Fi设置DNS服务器: $DNS_SERVER"
        
        # 添加DNS服务器的路由，确保DNS查询通过WiFi网卡
        local wifi_gateway=$(get_gateway "$WIFI_INTERFACE")
        if [[ -n "$wifi_gateway" ]]; then
            route add -host "$DNS_SERVER" "$wifi_gateway" 2>/dev/null || true
            log_info "添加DNS服务器路由: $DNS_SERVER -> $wifi_gateway (via $WIFI_INTERFACE)"
        fi
        
        # 刷新DNS缓存
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        log_info "已刷新DNS缓存"
        
        return 0
    else
        log_error "设置DNS服务器失败"
        return 1
    fi
}

# 恢复DNS设置
restore_dns() {
    log_info "恢复DNS设置..."
    
    if [[ -f "$DNS_BACKUP_FILE" ]]; then
        local original_dns=$(head -1 "$DNS_BACKUP_FILE")
        
        if [[ "$original_dns" == "Empty" ]] || [[ -z "$original_dns" ]]; then
            # 如果原来没有设置DNS，则清空DNS设置
            networksetup -setdnsservers "Wi-Fi" "Empty" 2>/dev/null || true
            log_info "已清空Wi-Fi DNS设置"
        else
            # 恢复原来的DNS设置
            networksetup -setdnsservers "Wi-Fi" "$original_dns" 2>/dev/null || true
            log_info "已恢复Wi-Fi DNS设置: $original_dns"
        fi
        
        # 删除DNS服务器的特定路由
        route delete -host "$DNS_SERVER" 2>/dev/null || true
        
        # 刷新DNS缓存
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        log_info "已刷新DNS缓存"
    else
        log_warn "未找到DNS备份文件，跳过DNS恢复"
    fi
}

# 获取网关信息
get_gateway() {
    local interface=$1
    local gateway
    
    if [[ "$interface" == "$WIFI_INTERFACE" ]]; then
        # 获取当前默认路由的网关
        gateway=$(route -n get default | grep gateway | awk '{print $2}' 2>/dev/null || echo "")
    else
        # 对于其他接口，尝试多种方法获取网关
        # 方法1: 检查是否有该接口的路由
        gateway=$(netstat -rn | grep "^default" | grep "$interface" | awk '{print $2}' | head -1)
        
        # 方法2: 如果没有找到，尝试从接口IP推断网关
        if [[ -z "$gateway" ]]; then
            local interface_ip=$(ifconfig "$interface" | grep 'inet ' | awk '{print $2}' | head -1)
            if [[ -n "$interface_ip" ]]; then
                # 根据接口IP推断网关（通常是.1）
                gateway=$(echo "$interface_ip" | awk -F. '{print $1"."$2"."$3".1}')
                log_info "根据接口IP $interface_ip 推断网关: $gateway"
            fi
        fi
    fi
    
    echo "$gateway"
}

# 设置路由表
setup_routes() {
    if [[ "$USE_PF_ROUTING" == "true" ]]; then
        setup_routes_efficient
    else
        setup_routes_traditional
    fi
}

# 检测网卡IP段避免路由冲突
get_interface_network() {
    local interface=$1
    local ip=$(ifconfig "$interface" | grep 'inet ' | awk '{print $2}' | head -1)
    
    if [[ -n "$ip" ]]; then
        # 获取网络掩码
        local netmask=$(ifconfig "$interface" | grep 'inet ' | awk '{print $4}' | head -1)
        
        # 将IP地址和掩码转换为网络地址
        if [[ -n "$netmask" ]]; then
            # 简单的网络段检测，假设常见的子网掩码
            if [[ "$netmask" == "0xffffff00" ]]; then
                echo "${ip%.*}.0/24"
            elif [[ "$netmask" == "0xffff0000" ]]; then
                echo "${ip%.*.*}.0.0/16"
            elif [[ "$netmask" == "0xff000000" ]]; then
                echo "${ip%%.*}.0.0.0/8"
            else
                # 默认假设/24
                echo "${ip%.*}.0/24"
            fi
        else
            # 如果无法获取掩码，默认假设/24
            echo "${ip%.*}.0/24"
        fi
    fi
}

# 传统路由设置方法
setup_routes_traditional() {
    log_info "开始设置路由表..."
    
    # 获取网关信息
    local wifi_gateway=$(get_gateway "$WIFI_INTERFACE")
    local demo_gateway=$(get_gateway "$DEMO_INTERFACE")
    
    if [[ -z "$demo_gateway" ]]; then
        log_error "无法获取DEMO网卡网关地址"
        return 1
    fi
    
    if [[ -z "$wifi_gateway" ]]; then
        log_error "无法获取WiFi网关地址"
        return 1
    fi
    
    log_info "WiFi网关: $wifi_gateway"
    log_info "DEMO网关: $demo_gateway"
    
    # 获取各网卡的网络段
    local wifi_network=$(get_interface_network "$WIFI_INTERFACE")
    local demo_network=$(get_interface_network "$DEMO_INTERFACE")
    
    log_info "WiFi网络段: $wifi_network"
    log_info "DEMO网络段: $demo_network"
    
    # 设置DEMO网卡为默认路由（优先级更高）
    log_info "设置DEMO网卡为默认路由..."
    route add -net 0.0.0.0/1 "$demo_gateway" >/dev/null 2>&1 || true
    route add -net 128.0.0.0/1 "$demo_gateway" >/dev/null 2>&1 || true
    
    # 添加本地网络路由，但要避免与网卡自身网段冲突
    log_info "添加本地网络路由..."
    
    # 只有当DEMO网卡不在这些网段时才添加路由
    if [[ "$demo_network" != "192.168."* ]]; then
        route add -net 192.168.0.0/16 "$wifi_gateway" >/dev/null 2>&1 || true
        log_info "添加192.168.0.0/16路由到WiFi"
    else
        log_warn "跳过192.168.0.0/16路由(与DEMO网卡网段冲突)"
    fi
    
    if [[ "$demo_network" != "172.16."* ]] && [[ "$demo_network" != "172.17."* ]] && [[ "$demo_network" != "172.1"* ]]; then
        route add -net 172.16.0.0/12 "$wifi_gateway" >/dev/null 2>&1 || true
        log_info "添加172.16.0.0/12路由到WiFi"
    else
        log_warn "跳过172.16.0.0/12路由(与DEMO网卡网段冲突)"
    fi
    
    # 10.0.0.0/8 通常包含WiFi网络，所以总是走WiFi
    route add -net 10.0.0.0/8 "$wifi_gateway" >/dev/null 2>&1 || true
    log_info "添加10.0.0.0/8路由到WiFi"
    
    # 为中国IP地址段添加WiFi路由
    log_info "为中国IP地址段设置WiFi路由..."
    local count=0
    local total=$(wc -l < "$CHINA_IP_LIST" 2>/dev/null || echo "0")
    
    # 使用静默处理，只显示进度
    log_info "正在添加 $total 条中国IP路由规则..."
    
    while IFS= read -r ip_range; do
        if [[ -n "$ip_range" ]] && [[ "$ip_range" != \#* ]]; then
            if route add -net "$ip_range" "$wifi_gateway" >/dev/null 2>&1; then
                ((count++))
            fi
            
            # 每100条显示一次进度，避免日志刷屏
            if ((count % 100 == 0)); then
                log_info "已添加 $count/$total 条路由规则..."
            fi
        fi
    done < "$CHINA_IP_LIST"
    
    log_info "成功添加 $count 条中国IP路由"
    log_info "路由设置完成"
}
setup_routes_efficient() {
    log_info "使用高效批量路由设置方法..."
    
    # 获取网关信息
    local wifi_gateway=$(get_gateway "$WIFI_INTERFACE")
    local demo_gateway=$(get_gateway "$DEMO_INTERFACE")
    
    if [[ -z "$demo_gateway" ]]; then
        log_error "无法获取DEMO网卡网关地址"
        return 1
    fi
    
    if [[ -z "$wifi_gateway" ]]; then
        log_error "无法获取WiFi网关地址"
        return 1
    fi
    
    log_info "WiFi网关: $wifi_gateway"
    log_info "DEMO网关: $demo_gateway"
    
    # 获取各网卡的网络段
    local wifi_network=$(get_interface_network "$WIFI_INTERFACE")
    local demo_network=$(get_interface_network "$DEMO_INTERFACE")
    
    log_info "WiFi网络段: $wifi_network"
    log_info "DEMO网络段: $demo_network"
    
    # 创建临时路由脚本
    local route_script="/tmp/route_setup_batch.sh"
    cat > "$route_script" << EOF
#!/bin/bash
# 批量路由设置脚本
set +e

# 设置默认路由
route add -net 0.0.0.0/1 "$demo_gateway" >/dev/null 2>&1
route add -net 128.0.0.0/1 "$demo_gateway" >/dev/null 2>&1

# 添加本地网络路由（避免冲突）
EOF

    # 根据DEMO网卡网段决定是否添加私有网络路由
    if [[ "$demo_network" != "192.168."* ]]; then
        echo "route add -net 192.168.0.0/16 \"$wifi_gateway\" >/dev/null 2>&1" >> "$route_script"
    fi
    
    if [[ "$demo_network" != "172.16."* ]] && [[ "$demo_network" != "172.17."* ]] && [[ "$demo_network" != "172.1"* ]]; then
        echo "route add -net 172.16.0.0/12 \"$wifi_gateway\" >/dev/null 2>&1" >> "$route_script"
    fi
    
    echo "route add -net 10.0.0.0/8 \"$wifi_gateway\" >/dev/null 2>&1" >> "$route_script"
    
    cat >> "$route_script" << EOF

# 批量添加中国IP路由
count=0
while IFS= read -r ip_range; do
    if [[ -n "\$ip_range" ]] && [[ "\$ip_range" != \\#* ]]; then
        route add -net "\$ip_range" "$wifi_gateway" >/dev/null 2>&1 && ((count++))
    fi
done < "$CHINA_IP_LIST"

echo "\$count"
EOF
    
    chmod +x "$route_script"
    
    log_info "设置DEMO网卡为默认路由..."
    log_info "添加本地网络路由..."
    if [[ "$demo_network" == "192.168."* ]]; then
        log_warn "跳过192.168.0.0/16路由(与DEMO网卡网段冲突)"
    fi
    log_info "批量添加中国IP路由..."
    
    # 执行批量路由设置
    local result=$("$route_script")
    
    log_info "成功添加 $result 条中国IP路由"
    log_info "路由设置完成"
    
    # 清理临时脚本
    rm -f "$route_script"
}

# 清理路由设置
cleanup_routes() {
    log_info "清理路由设置..."
    
    # 删除自定义路由
    route delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
    route delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
    
    # 清理本地网络路由
    route delete -net 192.168.0.0/16 >/dev/null 2>&1 || true
    route delete -net 172.16.0.0/12 >/dev/null 2>&1 || true
    route delete -net 10.0.0.0/8 >/dev/null 2>&1 || true
    
    # 清理中国IP路由（静默处理）
    if [[ -f "$CHINA_IP_LIST" ]]; then
        local total=$(wc -l < "$CHINA_IP_LIST" 2>/dev/null || echo "0")
        log_info "正在清理 $total 条中国IP路由规则..."
        
        local count=0
        while IFS= read -r ip_range; do
            if [[ -n "$ip_range" ]] && [[ "$ip_range" != \#* ]]; then
                route delete -net "$ip_range" >/dev/null 2>&1 || true
                ((count++))
                
                # 每100条显示一次进度
                if ((count % 100 == 0)); then
                    log_info "已清理 $count/$total 条路由规则..."
                fi
            fi
        done < "$CHINA_IP_LIST"
        
        log_info "清理了 $count 条中国IP路由"
    fi
    
    # 恢复DNS设置
    restore_dns
    
    log_info "路由清理完成"
}

# 检查路由状态
check_routes() {
    log_info "检查路由状态..."
    
    echo "=== 当前默认路由 ==="
    route -n get default 2>/dev/null || echo "无法获取默认路由"
    
    echo ""
    echo "=== DNS设置 ==="
    echo "Wi-Fi DNS服务器:"
    networksetup -getdnsservers "Wi-Fi" 2>/dev/null || echo "无法获取DNS设置"
    
    echo ""
    echo "DNS服务器路由:"
    route -n get "$DNS_SERVER" 2>/dev/null || echo "未找到DNS服务器路由"
    
    echo ""
    echo "=== 当前路由表（前20条）==="
    netstat -rn | head -20
    
    echo ""
    echo "=== 测试连接 ==="
    log_info "测试DNS解析 (使用 $DNS_SERVER)..."
    if nslookup baidu.com "$DNS_SERVER" >/dev/null 2>&1; then
        echo "✓ DNS解析正常"
    else
        echo "✗ DNS解析失败"
    fi
    
    log_info "测试国内网站 (baidu.com)..."
    if ping -c 1 -W 3000 baidu.com >/dev/null 2>&1; then
        echo "✓ 国内网站连接正常"
    else
        echo "✗ 国内网站连接失败"
    fi
    
    log_info "测试国外网站 (google.com)..."
    if ping -c 1 -W 3000 google.com >/dev/null 2>&1; then
        echo "✓ 国外网站连接正常"
    else
        echo "✗ 国外网站连接失败"
    fi
}

# 显示使用说明
show_usage() {
    cat << 'EOF'
macOS-Route-Splitter - macOS 网络路由分流器，智能分流网络流量

用法:
    sudo ./route_setup.sh [选项]

选项:
    setup       设置路由分流 (默认)
    cleanup     清理路由设置，恢复默认
    check       检查当前路由状态
    status      显示网卡和路由信息
    -h, --help  显示此帮助信息

示例:
    sudo ./route_setup.sh setup    # 设置路由分流
    sudo ./route_setup.sh cleanup  # 清理路由设置
    sudo ./route_setup.sh check    # 检查路由状态

功能特性:
    - 自动检测DEMO Mobile Boardband网卡
    - 从国内镜像源下载最新中国IP地址段
    - 中国IP通过WiFi网卡访问，其他IP通过DEMO网卡
    - DNS服务器设置为10.8.4.21，并强制通过WiFi网卡访问
    - 自动备份和恢复路由表及DNS设置
    - 支持连接测试和状态检查

注意:
    - 此脚本需要root权限运行
    - 确保DEMO Mobile Boardband网卡已连接并获取IP
    - 建议运行前备份重要网络配置
    - DNS设置会自动备份，cleanup时会恢复原设置
EOF
}

# 显示网卡状态
show_status() {
    log_info "显示网卡和路由信息..."
    
    echo "=== 网卡状态 ==="
    echo "WiFi网卡 ($WIFI_INTERFACE):"
    if ifconfig "$WIFI_INTERFACE" | grep -q "inet "; then
        local wifi_ip=$(ifconfig "$WIFI_INTERFACE" | grep 'inet ' | awk '{print $2}')
        echo "  ✓ 已连接，IP: $wifi_ip"
    else
        echo "  ✗ 未连接"
    fi
    
    echo ""
    echo "DEMO网卡 ($DEMO_INTERFACE):"
    if networksetup -listallhardwareports | grep -q "DEMO Mobile Boardband"; then
        if ifconfig "$DEMO_INTERFACE" 2>/dev/null | grep -q "inet "; then
            local demo_ip=$(ifconfig "$DEMO_INTERFACE" | grep 'inet ' | awk '{print $2}')
            echo "  ✓ 已连接，IP: $demo_ip"
        else
            echo "  ✗ 未连接或无IP"
        fi
    else
        echo "  ✗ 未找到设备"
    fi
    
    echo ""
    check_routes
}

# 主函数
main() {
    local action="${1:-setup}"
    
    case "$action" in
        "setup")
            log_info "开始执行路由分流设置..."
            
            # 检查root权限
            check_root
            
            # 检查DEMO网卡
            if ! check_demo_interface; then
                log_error "DEMO网卡检查失败，退出脚本"
                exit 1
            fi
            
            # 备份当前路由和DNS设置
            backup_routes
            backup_dns
            
            # 获取或下载中国IP地址段
            if ! download_china_ip_list; then
                log_warn "下载IP地址段失败，使用备用列表"
                create_backup_china_ip_list
            fi
            
            # 获取DNS服务器地址
            get_dns_server
            
            # 设置DNS服务器
            if ! setup_dns; then
                log_error "DNS设置失败，但继续设置路由"
            fi
            
            # 设置路由
            if setup_routes; then
                log_info "路由分流设置完成"
                echo ""
                check_routes
            else
                log_error "路由设置失败"
                exit 1
            fi
            ;;
            
        "cleanup")
            log_info "开始清理路由设置..."
            check_root
            cleanup_routes
            log_info "路由清理完成"
            ;;
            
        "check")
            check_routes
            ;;
            
        "status")
            show_status
            ;;
            
        "-h"|"--help"|"help")
            show_usage
            ;;
            
        *)
            log_error "未知操作: $action"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"