#!/bin/bash

# Sui Fullnode 监控脚本
# 用于监控 Fullnode 的运行状态并发送告警

set -e

# 配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/monitor.conf"
LOG_FILE="/var/log/sui-monitor.log"

# 默认配置
ALERT_EMAIL=""
ALERT_WEBHOOK=""
DISK_THRESHOLD=80
MEMORY_THRESHOLD=80
CPU_THRESHOLD=90
CHECKPOINT_LAG_THRESHOLD=100

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_info() {
    log_message "[INFO] $1"
}

log_warn() {
    log_message "[WARN] $1"
}

log_error() {
    log_message "[ERROR] $1"
}

# 加载配置文件
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "配置文件已加载: $CONFIG_FILE"
    else
        log_warn "配置文件不存在: $CONFIG_FILE"
        log_info "使用默认配置"
    fi
}

# 发送告警
send_alert() {
    local subject="$1"
    local message="$2"
    local severity="$3"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    
    # 构建完整消息
    local full_message="时间: $timestamp
主机: $hostname
级别: $severity
主题: $subject

详情:
$message

---
Sui Fullnode 监控系统"
    
    # 邮件告警
    if [[ ! -z "$ALERT_EMAIL" ]] && command -v mail &> /dev/null; then
        echo "$full_message" | mail -s "[$severity] Sui Fullnode Alert: $subject" "$ALERT_EMAIL"
        log_info "告警邮件已发送到: $ALERT_EMAIL"
    fi
    
    # Webhook告警
    if [[ ! -z "$ALERT_WEBHOOK" ]] && command -v curl &> /dev/null; then
        curl -X POST -H "Content-Type: application/json" \
            -d "{\"text\": \"$full_message\"}" \
            "$ALERT_WEBHOOK" &>/dev/null
        log_info "告警已发送到Webhook"
    fi
    
    # 记录到日志
    log_message "[$severity] $subject - $message"
}

# 检查服务状态
check_service_status() {
    log_info "检查服务状态..."
    
    if ! systemctl is-active --quiet sui-fullnode; then
        send_alert "服务停止" "Sui Fullnode 服务未运行" "CRITICAL"
        return 1
    fi
    
    # 检查服务是否正常响应
    if ! curl -s http://localhost:9184/metrics | grep -q "sui_"; then
        send_alert "服务异常" "Sui Fullnode 指标接口无响应" "CRITICAL"
        return 1
    fi
    
    log_info "服务状态正常"
    return 0
}

# 检查RPC接口
check_rpc_status() {
    log_info "检查RPC接口..."
    
    local response
    response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
        http://localhost:9000 2>/dev/null)
    
    if ! echo "$response" | grep -q "result"; then
        send_alert "RPC异常" "RPC接口无法正常响应" "WARNING"
        return 1
    fi
    
    log_info "RPC接口正常"
    return 0
}

# 检查磁盘空间
check_disk_space() {
    log_info "检查磁盘空间..."
    
    local disk_usage
    disk_usage=$(df /opt/sui/db | awk 'NR==2 {print $5}' | sed 's/%//')
    
    if [[ "$disk_usage" -gt "$DISK_THRESHOLD" ]]; then
        send_alert "磁盘空间不足" "磁盘使用率: ${disk_usage}% (阈值: ${DISK_THRESHOLD}%)" "WARNING"
        return 1
    fi
    
    log_info "磁盘空间正常 (使用率: ${disk_usage}%)"
    return 0
}

# 检查内存使用
check_memory_usage() {
    log_info "检查内存使用..."
    
    local pid
    pid=$(systemctl show sui-fullnode -p MainPID --value)
    
    if [[ "$pid" == "0" ]]; then
        log_warn "无法获取进程ID"
        return 1
    fi
    
    local memory_usage
    memory_usage=$(ps -p $pid -o %mem --no-headers | tr -d ' ' | cut -d. -f1)
    
    if [[ "$memory_usage" -gt "$MEMORY_THRESHOLD" ]]; then
        send_alert "内存使用过高" "内存使用率: ${memory_usage}% (阈值: ${MEMORY_THRESHOLD}%)" "WARNING"
        return 1
    fi
    
    log_info "内存使用正常 (使用率: ${memory_usage}%)"
    return 0
}

# 检查CPU使用
check_cpu_usage() {
    log_info "检查CPU使用..."
    
    local pid
    pid=$(systemctl show sui-fullnode -p MainPID --value)
    
    if [[ "$pid" == "0" ]]; then
        log_warn "无法获取进程ID"
        return 1
    fi
    
    # 获取CPU使用率 (平均值)
    local cpu_usage
    cpu_usage=$(ps -p $pid -o %cpu --no-headers | tr -d ' ' | cut -d. -f1)
    
    if [[ "$cpu_usage" -gt "$CPU_THRESHOLD" ]]; then
        send_alert "CPU使用过高" "CPU使用率: ${cpu_usage}% (阈值: ${CPU_THRESHOLD}%)" "WARNING"
        return 1
    fi
    
    log_info "CPU使用正常 (使用率: ${cpu_usage}%)"
    return 0
}

# 检查同步状态
check_sync_status() {
    log_info "检查同步状态..."
    
    # 获取本地检查点
    local local_response
    local_response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
        http://localhost:9000 2>/dev/null)
    
    if ! echo "$local_response" | grep -q "result"; then
        send_alert "同步状态异常" "无法获取本地检查点" "WARNING"
        return 1
    fi
    
    local local_checkpoint
    local_checkpoint=$(echo "$local_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    
    log_info "当前本地检查点: $local_checkpoint"
    
    # 这里可以添加与网络检查点的比较逻辑
    # 目前仅记录本地检查点
    
    return 0
}

# 检查错误日志
check_error_logs() {
    log_info "检查错误日志..."
    
    # 检查过去1小时的错误日志
    local error_count
    error_count=$(journalctl -u sui-fullnode --since "1 hour ago" -p err --no-pager | wc -l)
    
    if [[ "$error_count" -gt 0 ]]; then
        local recent_errors
        recent_errors=$(journalctl -u sui-fullnode --since "1 hour ago" -p err --no-pager | tail -5)
        
        send_alert "发现错误日志" "过去1小时内有 $error_count 条错误日志:
$recent_errors" "WARNING"
        return 1
    fi
    
    log_info "无错误日志"
    return 0
}

# 检查网络连接
check_network_connectivity() {
    log_info "检查网络连接..."
    
    # 检查是否能连接到检查点服务器
    if ! curl -s --connect-timeout 10 https://checkpoints.mainnet.sui.io >/dev/null; then
        send_alert "网络连接异常" "无法连接到Sui检查点服务器" "WARNING"
        return 1
    fi
    
    log_info "网络连接正常"
    return 0
}

# 生成状态报告
generate_status_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)
    
    # 获取基本信息
    local service_status=$(systemctl is-active sui-fullnode)
    local uptime=$(systemctl show sui-fullnode -p ActiveEnterTimestamp --value)
    
    # 获取资源使用情况
    local disk_usage=$(df /opt/sui/db | awk 'NR==2 {print $5}')
    local disk_free=$(df -h /opt/sui/db | awk 'NR==2 {print $4}')
    local db_size=$(du -sh /opt/sui/db 2>/dev/null | cut -f1)
    
    # 获取版本信息
    local version=""
    if [[ -f "/opt/sui/bin/sui-node" ]]; then
        version=$(/opt/sui/bin/sui-node --version 2>/dev/null || echo "Unknown")
    fi
    
    # 获取检查点信息
    local checkpoint=""
    local checkpoint_response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
        http://localhost:9000 2>/dev/null)
    if echo "$checkpoint_response" | grep -q "result"; then
        checkpoint=$(echo "$checkpoint_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    fi
    
    cat << EOF
========================================
Sui Fullnode 状态报告
========================================
时间: $timestamp
主机: $hostname

服务状态: $service_status
启动时间: $uptime
版本: $version

当前检查点: $checkpoint

资源使用:
- 磁盘使用率: $disk_usage
- 可用空间: $disk_free
- 数据库大小: $db_size

监控阈值:
- 磁盘使用: ${DISK_THRESHOLD}%
- 内存使用: ${MEMORY_THRESHOLD}%
- CPU使用: ${CPU_THRESHOLD}%

========================================
EOF
}

# 主监控函数
run_monitoring() {
    log_info "开始监控检查..."
    
    local checks_passed=0
    local checks_total=7
    
    # 执行各项检查
    check_service_status && ((checks_passed++))
    check_rpc_status && ((checks_passed++))
    check_disk_space && ((checks_passed++))
    check_memory_usage && ((checks_passed++))
    check_cpu_usage && ((checks_passed++))
    check_sync_status && ((checks_passed++))
    check_error_logs && ((checks_passed++))
    check_network_connectivity && ((checks_passed++))
    
    log_info "监控检查完成: $checks_passed/$checks_total 项通过"
    
    # 如果检查通过率低于80%，发送告警
    local pass_rate=$((checks_passed * 100 / checks_total))
    if [[ $pass_rate -lt 80 ]]; then
        send_alert "健康检查异常" "健康检查通过率: ${pass_rate}% (${checks_passed}/${checks_total})" "WARNING"
    fi
}

# 显示帮助信息
show_help() {
    echo "Sui Fullnode 监控脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -c, --config FILE       指定配置文件"
    echo "  -r, --report           生成状态报告"
    echo "  -d, --daemon           以守护进程模式运行"
    echo "  -i, --interval SECONDS  监控间隔 (守护进程模式，默认300秒)"
    echo "  -h, --help             显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0                     # 运行一次监控检查"
    echo "  $0 -r                  # 生成状态报告"
    echo "  $0 -d -i 60           # 以60秒间隔运行守护进程"
}

# 守护进程模式
run_daemon() {
    local interval=${1:-300}
    
    log_info "启动守护进程模式，监控间隔: ${interval}秒"
    
    while true; do
        run_monitoring
        sleep $interval
    done
}

# 主函数
main() {
    # 默认参数
    local mode="single"
    local interval=300
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -r|--report)
                mode="report"
                shift
                ;;
            -d|--daemon)
                mode="daemon"
                shift
                ;;
            -i|--interval)
                interval="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 加载配置
    load_config
    
    # 创建日志目录
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE"
    sudo chown $(whoami):$(whoami) "$LOG_FILE"
    
    # 根据模式执行
    case $mode in
        "single")
            run_monitoring
            ;;
        "report")
            generate_status_report
            ;;
        "daemon")
            run_daemon $interval
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi