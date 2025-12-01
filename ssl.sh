#!/bin/bash

# NAT VPS SSL证书申请和博客部署一键脚本 - 菜单版
# 适用于无80端口的VPS服务器

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统类型
detect_system() {
    if [[ -f /etc/debian_version ]]; then
        SYSTEM="debian"
    elif [[ -f /etc/redhat-release ]]; then
        SYSTEM="centos"
    else
        log_error "不支持的系统类型"
        exit 1
    fi
    log_info "检测到系统类型: $SYSTEM"
}

# 检查并安装必要工具
install_dependencies() {
    log_step "检查并安装必要工具"
    
    local missing_packages=()
    
    # 检查必要的命令是否存在
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        missing_packages+=("cron")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_packages+=("jq")
    fi
    
    # 如果没有缺失的包，跳过安装
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "所有依赖已安装，跳过安装步骤"
        return
    fi
    
    log_info "检测到缺失的依赖: ${missing_packages[*]}"
    
    if [[ $SYSTEM == "debian" ]]; then
        log_info "更新软件包列表..."
        DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1
        
        log_info "安装缺失的依赖..."
        DEBIAN_FRONTEND=noninteractive apt install "${missing_packages[@]}" -y >/dev/null 2>&1
        
        # 确保cron服务运行
        if [[ " ${missing_packages[*]} " =~ " cron " ]]; then
            systemctl enable cron >/dev/null 2>&1
            systemctl start cron >/dev/null 2>&1
        fi
        
    elif [[ $SYSTEM == "centos" ]]; then
        log_info "安装缺失的依赖..."
        # CentOS中cron包名是cronie
        local centos_packages=()
        for pkg in "${missing_packages[@]}"; do
            if [[ "$pkg" == "cron" ]]; then
                centos_packages+=("cronie")
            else
                centos_packages+=("$pkg")
            fi
        done
        
        yum install "${centos_packages[@]}" -y >/dev/null 2>&1
        
        # 确保crond服务运行
        if [[ " ${missing_packages[*]} " =~ " cron " ]]; then
            systemctl enable crond >/dev/null 2>&1
            systemctl start crond >/dev/null 2>&1
        fi
    fi
    
    log_info "依赖安装完成"
}

# 安装acme.sh
install_acme() {
    log_step "安装acme.sh SSL证书工具"
    
    # 检查是否已有保存的邮箱
    # 创建配置文件夹
    mkdir -p /root/ssl_config
    
    if [[ -f /root/ssl_config/global_config ]]; then
        source /root/ssl_config/global_config
        if [[ -n "$USER_EMAIL" ]]; then
            local email_prefix="${USER_EMAIL%%@*}"
            local email_domain="${USER_EMAIL##*@}"
            log_info "使用已保存的邮箱: ${email_prefix:0:3}***@${email_domain}"
        fi
    fi
    
    # 如果没有邮箱，则获取用户邮箱
    if [[ -z "$USER_EMAIL" ]]; then
        echo -n "请输入您的邮箱地址 (用于SSL证书通知): "
        read -r USER_EMAIL
        
        if [[ -z "$USER_EMAIL" ]]; then
            log_error "邮箱地址不能为空"
            return 1
        fi
        
        # 验证邮箱格式
        if [[ ! "$USER_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_error "邮箱格式不正确"
            return 1
        fi
        
        # 保存邮箱到全局配置文件
        echo "USER_EMAIL=\"$USER_EMAIL\"" > /root/ssl_config/global_config
        log_info "邮箱已保存，后续申请将自动使用此邮箱"
    fi
    
    # 导出为全局变量
    export USER_EMAIL="$USER_EMAIL"
    
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        log_info "检测到已安装的 acme.sh，跳过安装步骤"
    else
        log_info "正在下载并安装 acme.sh..."
        curl -s https://get.acme.sh | sh -s email="$USER_EMAIL" > /dev/null 2>&1
        
        # 设置默认CA为Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt > /dev/null 2>&1
        
        log_info "acme.sh 安装完成"
    fi
}

# 配置Cloudflare API Token
configure_cloudflare() {
    log_step "配置Cloudflare DNS API"
    
    echo -n "您的域名 (支持子域名，如: blog.example.com): "
    read -r DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    
    log_info ""
    log_info "[KEY] 由于NAT VPS限制，我们使用API Token方式进行授权"
    log_info ""
    log_info "[GUIDE] 获取Cloudflare API Token步骤:"
    echo "1. 打开浏览器访问: https://dash.cloudflare.com/profile/api-tokens"
    echo "2. 点击 'Create Token'"
    echo "3. 选择 'Edit zone DNS' 模板"
    echo "4. 在 'Zone Resources' 中选择 'Include All zones'"
    echo "5. 点击 'Continue to summary' → 'Create Token'"
    echo "6. 复制生成的Token"
    echo ""
    
    echo -n "请输入您的Cloudflare API Token: "
    read -r CF_Token
    
    if [[ -z "$CF_Token" ]]; then
        log_error "API Token不能为空"
        return 1
    fi
    
    # 导出环境变量供acme.sh使用
    export CF_Token="$CF_Token"
    
    # 保存配置到文件
    cat > /root/ssl_config/config_$DOMAIN << EOF
DOMAIN="$DOMAIN"
CF_Token="$CF_Token"
USER_EMAIL="$USER_EMAIL"
EOF
    
    log_info "[OK] Cloudflare API Token 配置完成"
    log_info "域名: $DOMAIN"
    log_info "Token: ${CF_Token:0:10}..."
}

# 提取主域名
extract_root_domain() {
    local domain="$1"
    echo "$domain" | awk -F. '{if(NF>2) print $(NF-1)"."$NF; else print $0}'
}

# 获取服务器IPv4地址
get_server_ipv4() {
    local ip=""
    local services=("https://ipv4.icanhazip.com" "https://api.ipify.org" "https://v4.ident.me")
    
    for service in "${services[@]}"; do
        ip=$(curl -s --max-time 10 "$service" 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# 获取服务器IPv6地址
get_server_ipv6() {
    local ip=""
    local services=("https://ipv6.icanhazip.com" "https://api6.ipify.org" "https://v6.ident.me")
    
    for service in "${services[@]}"; do
        ip=$(curl -s --max-time 10 "$service" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$')
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# 获取服务器IP地址（IPv4和IPv6）
get_server_ips() {
    local ipv4=""
    local ipv6=""
    
    # 获取IPv4
    ipv4=$(get_server_ipv4)
    if [[ -n "$ipv4" ]]; then
        log_info "检测到IPv4地址: $ipv4"
    fi
    
    # 获取IPv6
    ipv6=$(get_server_ipv6)
    if [[ -n "$ipv6" ]]; then
        log_info "检测到IPv6地址: $ipv6"
    fi
    
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        log_error "无法获取服务器IP地址"
        return 1
    fi
    
    echo "ipv4:$ipv4"
    echo "ipv6:$ipv6"
}

# Cloudflare API调用
cloudflare_api_real() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    local url="https://api.cloudflare.com/client/v4$endpoint"
    
    if [[ "$method" == "GET" ]]; then
        curl -s -X GET "$url" \
            -H "Authorization: Bearer $CF_Token" \
            -H "Content-Type: application/json"
    else
        curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_Token" \
            -H "Content-Type: application/json" \
            -d "$data"
    fi
}

# 获取Zone ID
get_zone_id_real() {
    local domain="$1"
    local response=$(cloudflare_api_real "GET" "/zones?name=$domain")
    echo "$response" | jq -r '.result[0].id // empty'
}

# 添加DNS记录
add_dns_record_real() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    local content="$4"
    
    local data="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":300}"
    local response=$(cloudflare_api_real "POST" "/zones/$zone_id/dns_records" "$data")
    echo "$response" | jq -r '.result.id // empty'
}

# 检查DNS记录是否存在
check_dns_record_exists() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    
    local response=$(cloudflare_api_real "GET" "/zones/$zone_id/dns_records?type=$type&name=$name")
    local count=$(echo "$response" | jq -r '.result | length')
    [[ "$count" -gt 0 ]]
}

# 获取DNS记录ID
get_dns_record_id() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    
    local response=$(cloudflare_api_real "GET" "/zones/$zone_id/dns_records?name=$name&type=$type")
    echo "$response" | jq -r '.result[0].id // empty'
}

# 删除DNS记录
delete_dns_record_real() {
    local zone_id="$1"
    local record_id="$2"
    
    local response=$(cloudflare_api_real "DELETE" "/zones/$zone_id/dns_records/$record_id")
    echo "$response" | jq -r '.success'
}

# 删除域名的DNS记录
remove_domain_dns_records() {
    local domain="$1"
    local cf_token="$2"
    
    if [[ -z "$cf_token" ]]; then
        log_warn "未找到Cloudflare API Token，跳过DNS记录删除"
        return 0
    fi
    
    # 设置API Token环境变量
    export CF_Token="$cf_token"
    
    log_info "正在删除Cloudflare DNS记录..."
    
    # 提取主域名
    local root_domain=$(extract_root_domain "$domain")
    log_info "主域名: $root_domain"
    
    # 获取Zone ID
    local zone_id=$(get_zone_id_real "$root_domain")
    
    if [[ -z "$zone_id" ]]; then
        log_warn "无法获取域名 $root_domain 的Zone ID，跳过DNS记录删除"
        return 0
    fi
    
    log_info "Zone ID: $zone_id"
    
    # 删除IPv4 A记录
    echo -ne "${YELLOW}[WAIT]${NC} 删除IPv4 A记录: $domain "
    local a_record_id=$(get_dns_record_id "$zone_id" "$domain" "A")
    if [[ -n "$a_record_id" ]]; then
        local success=$(delete_dns_record_real "$zone_id" "$a_record_id")
        if [[ "$success" == "true" ]]; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[FAIL]${NC}"
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC}"
        log_warn "未找到IPv4 A记录: $domain"
    fi
    
    # 删除IPv6 AAAA记录
    echo -ne "${YELLOW}[WAIT]${NC} 删除IPv6 AAAA记录: $domain "
    local aaaa_record_id=$(get_dns_record_id "$zone_id" "$domain" "AAAA")
    if [[ -n "$aaaa_record_id" ]]; then
        local success=$(delete_dns_record_real "$zone_id" "$aaaa_record_id")
        if [[ "$success" == "true" ]]; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[FAIL]${NC}"
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC}"
        log_warn "未找到IPv6 AAAA记录: $domain"
    fi
    
    log_info "DNS记录删除完成"
}

# 添加域名解析记录
add_domain_records() {
    log_step "添加域名DNS解析记录"
    
    # 获取服务器IP地址（IPv4和IPv6）
    log_info "检测服务器IP地址..."
    local ip_results=$(get_server_ips)
    local ipv4=""
    local ipv6=""
    
    while IFS= read -r result; do
        if [[ "$result" =~ ^ipv4: ]]; then
            ipv4="${result#ipv4:}"
        elif [[ "$result" =~ ^ipv6: ]]; then
            ipv6="${result#ipv6:}"
        fi
    done <<< "$ip_results"
    
    # 提取主域名
    local root_domain=$(extract_root_domain "$DOMAIN")
    log_info "主域名: $root_domain"
    
    # 获取Zone ID
    log_info "获取Cloudflare Zone ID..."
    local zone_id=$(get_zone_id_real "$root_domain")
    
    if [[ -z "$zone_id" ]]; then
        log_error "无法获取域名 $root_domain 的Zone ID"
        log_warn "请确认域名已添加到Cloudflare并且API Token权限正确"
        return 1
    fi
    
    log_info "Zone ID: $zone_id"
    
    # 添加IPv4 A记录
    if [[ -n "$ipv4" ]]; then
        echo -ne "${YELLOW}[WAIT]${NC} 添加IPv4 A记录: $DOMAIN → $ipv4 "
        
        if check_dns_record_exists "$zone_id" "$DOMAIN" "A"; then
            echo -e "${YELLOW}[SKIP]${NC}"
            log_warn "IPv4 A记录已存在: $DOMAIN"
        else
            local record_id=$(add_dns_record_real "$zone_id" "$DOMAIN" "A" "$ipv4")
            if [[ -n "$record_id" ]]; then
                echo -e "${GREEN}[OK]${NC}"
            else
                echo -e "${RED}[FAIL]${NC}"
            fi
        fi
    fi
    
    # 添加IPv6 AAAA记录
    if [[ -n "$ipv6" ]]; then
        echo -ne "${YELLOW}[WAIT]${NC} 添加IPv6 AAAA记录: $DOMAIN → $ipv6 "
        
        if check_dns_record_exists "$zone_id" "$DOMAIN" "AAAA"; then
            echo -e "${YELLOW}[SKIP]${NC}"
            log_warn "IPv6 AAAA记录已存在: $DOMAIN"
        else
            local record_id=$(add_dns_record_real "$zone_id" "$DOMAIN" "AAAA" "$ipv6")
            if [[ -n "$record_id" ]]; then
                echo -e "${GREEN}[OK]${NC}"
            else
                echo -e "${RED}[FAIL]${NC}"
            fi
        fi
    fi
    
    log_info "[DNS] DNS解析记录配置完成"
    log_info "[WAIT] DNS记录可能需要几分钟时间全球生效"
    
    echo
    log_info "[LIST] 已添加的DNS记录:"
    [[ -n "$ipv4" ]] && echo -e "  ${GREEN}IPv4 A记录:${NC} $DOMAIN → $ipv4"
    [[ -n "$ipv6" ]] && echo -e "  ${GREEN}IPv6 AAAA记录:${NC} $DOMAIN → $ipv6"
    echo
}

# 申请SSL证书
request_ssl() {
    log_step "申请SSL证书"
    
    source /root/ssl_config/config_$DOMAIN
    
    log_info "正在为域名 $DOMAIN 申请SSL证书..."
    log_info "使用Cloudflare DNS API自动验证"
    log_info "API Token: ${CF_Token:0:10}..."
    
    # 账户已在install_acme()中正确注册，无需重复操作
    log_info "使用已注册的账户: ${USER_EMAIL:0:10}..."
    
    local temp_log="/tmp/acme_temp_$DOMAIN.log"
    
    # 临时禁用set -e，以便捕获错误
    set +e
    
    # 使用acme.sh的Cloudflare DNS插件自动申请证书
    echo -ne "${YELLOW}[WAIT]${NC} 正在申请SSL证书并验证DNS记录 "
    
    # 显示简单的等待动画
    (
        local spin_chars="/-\|"
        local i=0
        while true; do
            printf "\b${spin_chars:i%4:1}"
            sleep 0.5
            ((i++))
        done
    ) &
    local spinner_pid=$!
    
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "www.$DOMAIN" --server letsencrypt > "$temp_log" 2>&1
    local exit_code=$?
    
    # 停止动画并显示结果
    kill $spinner_pid 2>/dev/null
    wait $spinner_pid 2>/dev/null
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}[OK]${NC}"
        log_info "SSL证书申请成功"
        log_info "DNS记录已自动添加和清理"
        rm -f "$temp_log"
    else
        echo -e "${RED}[FAIL]${NC}"
        log_error "SSL证书申请失败 (退出码: $exit_code)"
        echo
        log_error "错误详情:"
        echo -e "${RED}$(cat "$temp_log")${NC}"
        echo
        log_info "完整日志文件: ~/.acme.sh/acme.sh.log"
        log_info "临时日志文件: $temp_log"
        echo
        log_warn "常见问题排查:"
        echo -e "${YELLOW}1. 检查API Token权限是否正确 (需要Zone:DNS:Edit)${NC}"
        echo -e "${YELLOW}2. 确认域名已添加到Cloudflare${NC}"
        echo -e "${YELLOW}3. 验证API Token是否包含正确的域名权限${NC}"
        echo -e "${YELLOW}4. 检查网络连接是否正常${NC}"
        return 1
    fi
    
    # 重新启用set -e
    set -e
}

# 安装证书到指定路径
install_ssl() {
    log_step "安装SSL证书到指定路径"
    
    source /root/ssl_config/config_$DOMAIN
    
    local cert_dir="/root/.cert/$DOMAIN"
    local web_dir="/var/www/$DOMAIN"
    
    # 创建证书目录
    mkdir -p "$cert_dir"
    mkdir -p "$web_dir"
    
    # 安装证书（只安装必要的两个文件）
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$cert_dir/private.key" \
        --fullchain-file "$cert_dir/fullchain.crt"
    
    # 设置证书文件权限
    chmod 600 "$cert_dir/private.key"
    chmod 644 "$cert_dir/fullchain.crt"
    
    log_info "SSL证书安装完成"
    log_info "证书路径: $cert_dir"
    
    # 验证证书文件
    if [[ -f "$cert_dir/private.key" && -f "$cert_dir/fullchain.crt" ]]; then
        log_info "证书文件验证成功"
        log_info "已生成文件:"
        log_info "  - 私钥: $cert_dir/private.key"
        log_info "  - 完整证书链: $cert_dir/fullchain.crt"
    else
        log_error "证书文件验证失败"
        return 1
    fi
}

# 设置自动续期
setup_auto_renewal() {
    log_step "设置SSL证书自动续期"
    
    # 添加cron任务
    local cron_job="0 0 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null"
    
    # 检查cron任务是否已存在（更宽泛的匹配）
    if ! crontab -l 2>/dev/null | grep -q "acme.sh.*--cron"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log_info "SSL证书自动续期已设置完成"
    else
        log_info "SSL证书自动续期任务已存在"
    fi
}

# 申请SSL证书完整流程
apply_ssl_certificate() {
    clear
    show_logo
    
    log_info "开始SSL证书申请流程..."
    echo
    
    # 检查系统和依赖
    detect_system
    install_dependencies
    
    # 安装acme.sh
    if ! install_acme; then
        log_error "acme.sh安装失败"
        pause_and_return
        return
    fi
    
    # 配置Cloudflare
    if ! configure_cloudflare; then
        log_error "Cloudflare配置失败"
        pause_and_return
        return
    fi
    
    # 添加DNS记录
    if ! add_domain_records; then
        log_error "DNS记录添加失败"
        pause_and_return
        return
    fi
    
    # 申请SSL证书
    if ! request_ssl; then
        log_error "SSL证书申请失败"
        pause_and_return
        return
    fi
    
    # 安装证书
    if ! install_ssl; then
        log_error "SSL证书安装失败"
        pause_and_return
        return
    fi
    
    # 设置自动续期
    setup_auto_renewal
    
    # 显示完成信息
    show_ssl_completion
    
    pause_and_return
}

# 删除SSL证书
remove_ssl_certificate() {
    clear
    show_logo
    
    log_info "SSL证书删除功能"
    echo
    
    # 列出已安装的证书
    if [[ ! -d ~/.acme.sh ]]; then
        log_warn "未找到acme.sh安装目录"
        pause_and_return
        return
    fi
    
    # 获取已申请的证书列表
    local cert_list=($(~/.acme.sh/acme.sh --list | grep -E "^\s*[a-zA-Z0-9.-]+\s+" | awk '{print $1}' | grep -v "Main_Domain"))
    
    if [[ ${#cert_list[@]} -eq 0 ]]; then
        log_warn "未找到已申请的SSL证书"
        pause_and_return
        return
    fi
    
    echo -e "${CYAN}已申请的SSL证书列表:${NC}"
    echo
    for i in "${!cert_list[@]}"; do
        local domain="${cert_list[$i]}"
        local cert_dir="/root/.cert/$domain"
        local status=""
        
        if [[ -d "$cert_dir" ]]; then
            status="${GREEN}[已安装]${NC}"
        else
            status="${YELLOW}[仅申请]${NC}"
        fi
        
        echo -e "${BLUE}$((i+1)).${NC} $domain $status"
    done
    echo
    echo -e "${BLUE}0.${NC} 返回主菜单"
    echo
    
    echo -n "请选择要删除的证书 (输入序号): "
    read -r choice
    
    if [[ "$choice" == "0" ]]; then
        return
    fi
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#cert_list[@]} ]]; then
        log_error "无效的选择"
        pause_and_return
        return
    fi
    
    local selected_domain="${cert_list[$((choice-1))]}"
    
    echo
    log_warn "即将删除域名 $selected_domain 的SSL证书"
    echo -e "${RED}此操作将会:${NC}"
    echo "1. 从acme.sh中移除证书记录"
    echo "2. 删除本地证书文件"
    echo "3. 删除配置文件"
    echo "4. 可选择删除Cloudflare DNS记录"
    echo
    echo -n "确认删除? (y/N): "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        pause_and_return
        return
    fi
    
    log_step "删除SSL证书: $selected_domain"
    
    # 从acme.sh中移除证书
    echo -ne "${YELLOW}[WAIT]${NC} 从acme.sh中移除证书记录 "
    if ~/.acme.sh/acme.sh --remove -d "$selected_domain" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${YELLOW}[SKIP]${NC}"
        log_warn "acme.sh中未找到该证书记录"
    fi
    
    # 删除本地证书文件
    local cert_dir="/root/.cert/$selected_domain"
    if [[ -d "$cert_dir" ]]; then
        echo -ne "${YELLOW}[WAIT]${NC} 删除本地证书文件 "
        rm -rf "$cert_dir"
        echo -e "${GREEN}[OK]${NC}"
    else
        log_warn "本地证书文件不存在: $cert_dir"
    fi
    
    # 询问是否删除DNS记录
    echo
    echo -n "是否同时删除Cloudflare DNS记录? (y/N): "
    read -r remove_dns
    
    if [[ "$remove_dns" == "y" || "$remove_dns" == "Y" ]]; then
        # 读取配置文件获取API Token
        local config_file="/root/ssl_config/config_$selected_domain"
        if [[ -f "$config_file" ]]; then
            source "$config_file"
            remove_domain_dns_records "$selected_domain" "$CF_Token"
        else
            log_warn "未找到配置文件，无法删除DNS记录"
        fi
    else
        log_info "保留DNS记录"
    fi
    
    # 删除配置文件
    local config_file="/root/ssl_config/config_$selected_domain"
    if [[ -f "$config_file" ]]; then
        echo -ne "${YELLOW}[WAIT]${NC} 删除配置文件 "
        rm -f "$config_file"
        echo -e "${GREEN}[OK]${NC}"
    else
        log_warn "配置文件不存在: $config_file"
    fi
    
    echo
    log_success "SSL证书删除完成: $selected_domain"
    if [[ "$remove_dns" == "y" || "$remove_dns" == "Y" ]]; then
        log_info "DNS记录已同时删除"
    fi
    
    pause_and_return
}

# 一键卸载功能
uninstall_all() {
    clear
    show_logo
    
    log_warn "一键卸载功能"
    echo
    echo -e "${RED}⚠️  警告：此操作将完全卸载以下内容：${NC}"
    echo
    echo -e "卸载功能 DNS解析需要自己去手动删除"
    echo
    echo -e "${YELLOW}SSL证书相关:${NC}"
    echo "  • 删除所有SSL证书文件 (/root/cert/)"
    echo "  • 卸载acme.sh及其所有配置"
    echo "  • 删除所有SSL配置文件"
    echo "  • 清理cron自动续期任务"
    echo
    echo -e "${YELLOW}依赖包 (可选):${NC}"
    echo "  • curl jq cron/cronie"
    echo
    echo -e "${YELLOW}日志和缓存:${NC}"
    echo "  • 所有临时日志文件"
    echo "  • acme.sh日志文件"
    echo "  • 配置缓存文件"
    echo
    
    echo -n "确认执行一键卸载? (输入 'YES' 确认): "
    read -r confirm
    
    if [[ "$confirm" != "YES" ]]; then
        log_info "操作已取消"
        pause_and_return
        return
    fi
    
    log_step "开始一键卸载..."
    
    # 1. 检查DNS解析记录（简化处理，避免卡死）
    echo -ne "${YELLOW}[WAIT]${NC} 检查DNS解析记录 "
    if [[ -d /root/ssl_config ]] && [[ -n "$(ls /root/ssl_config/config_* 2>/dev/null)" ]]; then
        local config_count=$(ls /root/ssl_config/config_* 2>/dev/null | wc -l)
        echo -e "${YELLOW}[SKIP] 发现 $config_count 个域名配置，DNS记录需手动删除${NC}"
        echo -e "${YELLOW}       提示: 请在Cloudflare控制台手动删除相关A/AAAA记录${NC}"
    else
        echo -e "${YELLOW}[SKIP] 未找到配置文件${NC}"
    fi
    
    # 2. 删除所有SSL证书文件
    echo -ne "${YELLOW}[WAIT]${NC} 删除SSL证书文件 "
    if [[ -d /root/cert ]]; then
        rm -rf /root/cert/
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${YELLOW}[SKIP]${NC}"
    fi
    
    # 3. 卸载acme.sh
    echo -ne "${YELLOW}[WAIT]${NC} 卸载acme.sh "
    if [[ -d ~/.acme.sh ]]; then
        ~/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
        rm -rf ~/.acme.sh/
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${YELLOW}[SKIP]${NC}"
    fi
    
    # 4. 清理环境变量
    echo -ne "${YELLOW}[WAIT]${NC} 清理环境变量 "
    sed -i '/acme.sh/d' ~/.bashrc 2>/dev/null || true
    sed -i '/acme.sh/d' ~/.profile 2>/dev/null || true
    sed -i '/acme.sh/d' ~/.zshrc 2>/dev/null || true
    echo -e "${GREEN}[OK]${NC}"
    
    # 5. 删除配置文件夹
    echo -ne "${YELLOW}[WAIT]${NC} 删除配置文件夹 "
    rm -rf /root/ssl_config 2>/dev/null || true
    echo -e "${GREEN}[OK]${NC}"
    
    # 6. 清理cron任务
    echo -ne "${YELLOW}[WAIT]${NC} 清理cron任务 "
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        local cron_count=$(crontab -l 2>/dev/null | grep -c "acme.sh" 2>/dev/null || echo "0")
        crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null || true
        echo -e "${GREEN}[OK] 删除了 $cron_count 个acme.sh相关任务${NC}"
    else
        # 检查cron服务是否运行
        if ! systemctl is-active --quiet cron 2>/dev/null && ! systemctl is-active --quiet crond 2>/dev/null; then
            echo -e "${YELLOW}[SKIP] cron服务未运行，可能未安装cron任务${NC}"
        else
            echo -e "${YELLOW}[SKIP] 未找到acme.sh相关的cron任务${NC}"
        fi
    fi
    
    # 7. 清理临时文件和日志
    echo -ne "${YELLOW}[WAIT]${NC} 清理临时文件和日志 "
    rm -f /tmp/acme_temp_*.log 2>/dev/null || true
    rm -f /tmp/acme_*.log 2>/dev/null || true
    rm -f /tmp/cf_oauth_code 2>/dev/null || true
    rm -f /tmp/oauth_success.html 2>/dev/null || true
    echo -e "${GREEN}[OK]${NC}"
    
    # 8. 询问是否卸载依赖包
    echo
    echo -n "是否同时卸载依赖包 (curl, jq, cron)? (y/N): "
    read -r remove_deps
    
    if [[ "$remove_deps" == "y" || "$remove_deps" == "Y" ]]; then
        echo -ne "${YELLOW}[WAIT]${NC} 卸载依赖包 "
        
        if [[ $SYSTEM == "debian" ]]; then
            DEBIAN_FRONTEND=noninteractive apt remove --purge curl jq cron -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt autoremove -y >/dev/null 2>&1 || true
        elif [[ $SYSTEM == "centos" ]]; then
            yum remove curl jq cronie -y >/dev/null 2>&1 || true
        fi
        
        echo -e "${GREEN}[OK]${NC}"
    else
        log_info "保留依赖包"
    fi
    
    echo
    log_success "一键卸载完成！"
    echo
    echo -e "${GREEN}已清理的内容:${NC}"
    echo "  ✓ 所有SSL证书文件"
    echo "  ✓ acme.sh程序和配置"
    echo "  ✓ 环境变量设置"
    echo "  ✓ 配置文件"
    echo "  ✓ 临时文件和日志"
    if [[ "$remove_deps" == "y" || "$remove_deps" == "Y" ]]; then
        echo "  ✓ 依赖包 (curl, jq, cron)"
    fi
    echo
    log_info "系统已恢复到安装前的状态"
    
    pause_and_return
}

# 显示SSL证书完成信息
show_ssl_completion() {
    source /root/ssl_config/config_$DOMAIN
    
    echo
    log_success "[COMPLETE] SSL证书申请和配置完成！"
    echo
    echo -e "${GREEN}域名信息:${NC}"
    echo "  主域名: https://$DOMAIN"
    echo
    echo -e "${GREEN}证书文件位置:${NC}"
    echo "  证书目录: /root/cert/$DOMAIN/"
    echo "  私钥: /root/cert/$DOMAIN/private.key"
    echo "  完整证书链: /root/cert/$DOMAIN/fullchain.crt"
    echo
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 证书将在3个月后自动续期"
    echo "  2. 请确主保域名已正确解析到Cloudflare"
    echo
}

# 显示SerokVip标识
show_logo() {
    # 获取终端宽度，默认80
    local term_width=$(tput cols 2>/dev/null || echo 80)

    local logo_width=56
    # 计算居中所需的左边距
    local left_padding=$(( (term_width - logo_width) / 2 ))
    # 确保左边距不小于0
    [[ $left_padding -lt 0 ]] && left_padding=0
    
    # 生成空格字符串
    local spaces=$(printf "%*s" $left_padding "")
    

    printf '%s\033[0;31m   ____\033[1;31m                 \033[0;33m_    \033[1;33m__     \033[1;32m___\033[0m\n' "$spaces"
    printf '%s\033[0;31m  / ___|\033[1;31m  ___ _ __ ___  \033[0;33m| | __\033[1;33m\\ \\   \033[1;32m/ (_)_ __\033[0m\n' "$spaces"
    printf '%s\033[0;31m  \\___ \\\033[1;31m / _ \\ '\''__/ _ \\ \033[0;33m| |/ / \033[1;33m\\ \\ / /\033[1;32m| | '\''_ \\\033[0m\n' "$spaces"
    printf '%s\033[0;31m   ___) \033[1;31m|  __/ | | (_) |\033[0;33m|   <   \033[1;33m\\ V / \033[1;32m| | |_) |\033[0m\n' "$spaces"
    printf '%s\033[0;31m  |____/ \033[1;31m\\___|_|  \\___/ \033[0;33m|_|\\_\\   \033[1;33m\\_/  \033[1;32m|_| .__/\033[0m\n' "$spaces"
    printf '%s\033[0;32m                                        |_|\033[0m\n' "$spaces"
    echo
    
    # 脚本标题 - 精确对齐边框
    # 直接使用固定宽度，确保边框与内容完全匹配
    local title_padding=$(( (term_width - 62) / 2 ))
    [[ $title_padding -lt 0 ]] && title_padding=0
    local title_spaces=$(printf "%*s" $title_padding "")
    
    # 固定边框 - 与内容行完全匹配
    local top_border="+----------------------------------------------------------+"
    local bottom_border="+----------------------------------------------------------+"
    
    printf '%s\033[1;36m%s\033[0m\n' "$title_spaces" "$top_border"
    printf '%s\033[1;36m|\033[1;37m            NAT VPS SSL证书申请一键脚本                   \033[1;36m|\033[0m\n' "$title_spaces"
    printf '%s\033[1;36m|\033[1;37m            适配于无80端口的VPS服务器                     \033[1;36m|\033[0m\n' "$title_spaces"
    printf '%s\033[1;36m%s\033[0m\n' "$title_spaces" "$bottom_border"
    echo
}

# 显示主菜单
show_main_menu() {
    clear
    show_logo
    
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${GREEN}1.${NC} 申请SSL证书"
    echo -e "${RED}2.${NC} 删除SSL证书"
    echo -e "${PURPLE}3.${NC} 一键卸载"
    echo -e "${YELLOW}0.${NC} 退出程序"
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
}

# 暂停并返回
pause_and_return() {
    echo
    echo -n "按回车键返回主菜单..."
    read -r
}

# 主菜单循环
main_menu_loop() {
    while true; do
        show_main_menu
        echo -n "请选择操作 (0-3): "
        read -r choice
        
        case $choice in
            1)
                apply_ssl_certificate
                ;;
            2)
                remove_ssl_certificate
                ;;
            3)
                uninstall_all
                ;;
            0)
                echo
                log_info "感谢使用SSL证书管理脚本！"
                exit 0
                ;;
            *)
                echo
                log_error "无效的选择，请输入 0-3"
                sleep 2
                ;;
        esac
    done
}

# 主函数
main() {
    check_root
    main_menu_loop
}

# 运行主函数
main "$@"
