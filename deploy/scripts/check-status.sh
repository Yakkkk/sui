#!/bin/bash

# Sui Fullnode 状态检查脚本
# 用于检查 Fullnode 的运行状态和同步情况

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_title() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# 检查服务状态
check_service_status() {
    log_title "检查服务状态"
    
    if systemctl is-active --quiet sui-fullnode; then
        log_info "服务状态: $(systemctl is-active sui-fullnode)"
        log_info "服务启用: $(systemctl is-enabled sui-fullnode)"
        
        # 获取服务运行时间
        UPTIME=$(systemctl show sui-fullnode -p ActiveEnterTimestamp --value)
        log_info "启动时间: $UPTIME"
        
        # 获取进程信息
        PID=$(systemctl show sui-fullnode -p MainPID --value)
        if [[ "$PID" != "0" ]]; then
            log_info "进程ID: $PID"
            
            # 内存使用情况
            MEM_USAGE=$(ps -p $PID -o %mem --no-headers | tr -d ' ')
            log_info "内存使用: ${MEM_USAGE}%"
            
            # CPU使用情况
            CPU_USAGE=$(ps -p $PID -o %cpu --no-headers | tr -d ' ')
            log_info "CPU使用: ${CPU_USAGE}%"
        fi
    else
        log_error "服务未运行"
        return 1
    fi
}

# 检查RPC接口
check_rpc_interface() {
    log_title "检查RPC接口"
    
    # 检查RPC端口是否监听
    if netstat -ln | grep -q ":9000"; then
        log_info "RPC端口9000正在监听"
    else
        log_warn "RPC端口9000未监听"
        return 1
    fi
    
    # 测试RPC接口
    if command -v curl &> /dev/null; then
        log_info "测试RPC接口..."
        
        # 获取最新检查点
        RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
            -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
            http://localhost:9000 2>/dev/null)
        
        if echo "$RESPONSE" | grep -q "result"; then
            CHECKPOINT=$(echo "$RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
            log_info "当前检查点: $CHECKPOINT"
            log_info "RPC接口工作正常"
        else
            log_warn "RPC接口响应异常"
            echo "响应: $RESPONSE"
        fi
    else
        log_warn "curl未安装，无法测试RPC接口"
    fi
}

# 检查指标接口
check_metrics_interface() {
    log_title "检查指标接口"
    
    # 检查指标端口是否监听
    if netstat -ln | grep -q ":9184"; then
        log_info "指标端口9184正在监听"
    else
        log_warn "指标端口9184未监听"
        return 1
    fi
    
    # 测试指标接口
    if command -v curl &> /dev/null; then
        log_info "测试指标接口..."
        
        METRICS_COUNT=$(curl -s http://localhost:9184/metrics | grep -c "^sui_" || echo "0")
        if [[ "$METRICS_COUNT" -gt 0 ]]; then
            log_info "指标数量: $METRICS_COUNT"
            log_info "指标接口工作正常"
            
            # 获取一些关键指标
            CURRENT_EPOCH=$(curl -s http://localhost:9184/metrics | grep "sui_current_epoch{" | tail -1 | grep -o '[0-9]*' | tail -1)
            TOTAL_TRANSACTIONS=$(curl -s http://localhost:9184/metrics | grep "sui_total_transactions{" | tail -1 | grep -o '[0-9]*' | tail -1)
            
            if [[ ! -z "$CURRENT_EPOCH" ]]; then
                log_info "当前Epoch: $CURRENT_EPOCH"
            fi
            if [[ ! -z "$TOTAL_TRANSACTIONS" ]]; then
                log_info "总交易数: $TOTAL_TRANSACTIONS"
            fi
        else
            log_warn "指标接口无数据"
        fi
    else
        log_warn "curl未安装，无法测试指标接口"
    fi
}

# 检查网络连接
check_network_status() {
    log_title "检查网络状态"
    
    # 检查P2P端口
    if netstat -ln | grep -q ":8084"; then
        log_info "P2P端口8084正在监听"
    else
        log_warn "P2P端口8084未监听"
    fi
    
    # 检查协议端口
    if netstat -ln | grep -q ":8080"; then
        log_info "协议端口8080正在监听"
    else
        log_warn "协议端口8080未监听"
    fi
}

# 检查磁盘使用情况
check_disk_usage() {
    log_title "检查磁盘使用情况"
    
    if [[ -d "/opt/sui/db" ]]; then
        DB_SIZE=$(du -sh /opt/sui/db 2>/dev/null | cut -f1)
        log_info "数据库大小: $DB_SIZE"
        
        # 检查磁盘空间
        DISK_USAGE=$(df /opt/sui/db | awk 'NR==2 {print $5}' | sed 's/%//')
        DISK_AVAILABLE=$(df -h /opt/sui/db | awk 'NR==2 {print $4}')
        
        log_info "磁盘使用率: ${DISK_USAGE}%"
        log_info "可用空间: $DISK_AVAILABLE"
        
        if [[ "$DISK_USAGE" -gt 80 ]]; then
            log_warn "磁盘使用率过高: ${DISK_USAGE}%"
        fi
    else
        log_warn "数据库目录 /opt/sui/db 不存在"
    fi
}

# 检查时钟同步
check_time_sync() {
    log_title "检查时钟同步"
    
    # 检查 chrony 服务状态 (根据不同发行版检查不同的服务名)
    if systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony; then
        if systemctl is-active --quiet chronyd; then
            log_info "✓ chronyd 服务正在运行"
        else
            log_info "✓ chrony 服务正在运行"
        fi
        
        # 显示 chrony 源状态
        if command -v chrony &> /dev/null; then
            log_info "Chrony 同步源状态:"
            chrony sources 2>/dev/null | while read line; do
                if [[ "$line" =~ (\^|\*) ]]; then  # 显示活跃的源
                    log_info "  $line"
                fi
            done
        fi
    else
        log_warn "⚠ chronyd 服务未运行"
        
        # 检查其他时间同步服务
        if systemctl is-active --quiet systemd-timesyncd; then
            log_info "systemd-timesyncd 服务正在运行"
        elif systemctl is-active --quiet ntp; then
            log_info "传统 ntp 服务正在运行"
        elif systemctl is-active --quiet ntpd; then
            log_info "ntpd 服务正在运行"
        else
            log_warn "未检测到时间同步服务"
        fi
    fi
    
    # 检查时间同步状态
    if command -v timedatectl &> /dev/null; then
        NTP_STATUS=$(timedatectl show --value -p NTPSynchronized 2>/dev/null || echo "unknown")
        if [[ "$NTP_STATUS" == "yes" ]]; then
            log_info "✓ 时间同步正常"
        else
            log_warn "⚠ 时间同步异常"
        fi
        
        TIMEZONE=$(timedatectl show --value -p Timezone 2>/dev/null || echo "Unknown")
        log_info "当前时区: $TIMEZONE"
        log_info "系统时间: $(date)"
        
        # 显示时间同步详情
        if (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony) && command -v chrony &> /dev/null; then
            CHRONY_STATUS=$(chrony tracking 2>/dev/null | grep "Leap status" | awk '{print $3}' || echo "Unknown")
            log_info "Chrony 状态: $CHRONY_STATUS"
        fi
    fi
}

# 检查配置文件
check_config() {
    log_title "检查配置文件"
    
    CONFIG_FILE="/opt/sui/config/fullnode.yaml"
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "配置文件存在: $CONFIG_FILE"
        
        # 检查创世文件
        GENESIS_FILE=$(grep "genesis-file-location" "$CONFIG_FILE" | cut -d'"' -f2)
        if [[ -f "$GENESIS_FILE" ]]; then
            log_info "创世文件存在: $GENESIS_FILE"
            GENESIS_SIZE=$(ls -lh "$GENESIS_FILE" | awk '{print $5}')
            log_info "创世文件大小: $GENESIS_SIZE"
        else
            log_error "创世文件不存在: $GENESIS_FILE"
        fi
        
        # 检查数据库路径
        DB_PATH=$(grep "db-path" "$CONFIG_FILE" | head -1 | cut -d'"' -f2)
        if [[ -d "$DB_PATH" ]]; then
            log_info "数据库路径存在: $DB_PATH"
        else
            log_warn "数据库路径不存在: $DB_PATH"
        fi
    else
        log_error "配置文件不存在: $CONFIG_FILE"
    fi
}

# 检查最近的日志
check_recent_logs() {
    log_title "检查最近的日志"
    
    log_info "最近10条日志:"
    journalctl -u sui-fullnode -n 10 --no-pager | while read line; do
        echo "  $line"
    done
    
    # 检查是否有错误
    ERROR_COUNT=$(journalctl -u sui-fullnode --since "1 hour ago" -p err --no-pager | wc -l)
    if [[ "$ERROR_COUNT" -gt 0 ]]; then
        log_warn "过去1小时内有 $ERROR_COUNT 条错误日志"
    else
        log_info "过去1小时内无错误日志"
    fi
}

# 检查同步状态
check_sync_status() {
    log_title "检查同步状态"
    
    if command -v curl &> /dev/null; then
        # 获取本地检查点
        LOCAL_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
            -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
            http://localhost:9000 2>/dev/null)
        
        if echo "$LOCAL_RESPONSE" | grep -q "result"; then
            LOCAL_CHECKPOINT=$(echo "$LOCAL_RESPONSE" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
            log_info "本地检查点: $LOCAL_CHECKPOINT"
            
            # 尝试获取网络检查点（如果可以访问外部API）
            # 注意：这可能需要根据实际的公共API进行调整
            log_info "同步状态: 正在运行"
        else
            log_warn "无法获取本地检查点，可能还在同步中"
        fi
    else
        log_warn "curl未安装，无法检查同步状态"
    fi
}

# 生成状态报告
generate_report() {
    log_title "状态报告摘要"
    
    echo "检查时间: $(date)"
    echo "主机名: $(hostname)"
    echo "操作系统: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")"
    echo "内核版本: $(uname -r)"
    echo "负载平均: $(uptime | cut -d',' -f3-)"
    
    # 检查二进制文件版本
    if [[ -f "/opt/sui/bin/sui-node" ]]; then
        VERSION=$(/opt/sui/bin/sui-node --version 2>/dev/null || echo "Unknown")
        echo "Sui版本: $VERSION"
    fi
}

# 主函数
main() {
    echo "=========================================="
    echo "    Sui Fullnode 状态检查"
    echo "=========================================="
    echo
    
    generate_report
    echo
    
    check_service_status
    echo
    
    check_rpc_interface
    echo
    
    check_metrics_interface
    echo
    
    check_network_status
    echo
    
    check_disk_usage
    echo
    
    check_time_sync
    echo
    
    check_config
    echo
    
    check_sync_status
    echo
    
    check_recent_logs
    echo
    
    log_title "检查完成"
    echo "如需查看详细日志，请运行: journalctl -u sui-fullnode -f"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi