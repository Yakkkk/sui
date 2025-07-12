#!/bin/bash

# Sui Fullnode 启动脚本
# 用于启动 Sui Fullnode 服务

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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 显示帮助信息
show_help() {
    echo "Sui Fullnode 启动脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -f, --force           强制启动 (即使服务已运行)"
    echo "  -w, --wait SECONDS    等待服务启动的时间 (默认: 30秒)"
    echo "  -c, --check           启动后检查服务状态"
    echo "  -h, --help            显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0                    # 启动服务"
    echo "  $0 -c                 # 启动并检查状态"
    echo "  $0 -f -w 60          # 强制启动并等待60秒"
}

# 检查服务状态
check_service_status() {
    if systemctl is-active --quiet sui-fullnode; then
        return 0  # 服务正在运行
    else
        return 1  # 服务未运行
    fi
}

# 检查配置文件
check_config() {
    log_step "检查配置文件..."
    
    local config_file="/opt/sui/config/fullnode.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi
    
    local genesis_file=$(grep "genesis-file-location" "$config_file" | cut -d'"' -f2)
    if [[ ! -f "$genesis_file" ]]; then
        log_error "创世文件不存在: $genesis_file"
        return 1
    fi
    
    local binary_file="/opt/sui/bin/sui-node"
    if [[ ! -f "$binary_file" ]]; then
        log_error "二进制文件不存在: $binary_file"
        return 1
    fi
    
    log_info "配置文件检查通过"
    return 0
}

# 检查端口占用
check_ports() {
    log_step "检查端口占用..."
    
    local ports=(8080 8084 9000 9184)
    local occupied_ports=()
    
    for port in "${ports[@]}"; do
        if netstat -ln 2>/dev/null | grep -q ":$port "; then
            # 检查是否被sui-fullnode占用
            local pid=$(lsof -ti :$port 2>/dev/null || echo "")
            if [[ ! -z "$pid" ]]; then
                local process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
                if [[ "$process" != "sui-node" ]]; then
                    occupied_ports+=("$port")
                fi
            fi
        fi
    done
    
    if [[ ${#occupied_ports[@]} -gt 0 ]]; then
        log_warn "以下端口被其他进程占用: ${occupied_ports[*]}"
        log_warn "这可能影响服务启动"
    else
        log_info "端口检查通过"
    fi
}

# 启动服务
start_service() {
    log_step "启动 Sui Fullnode 服务..."
    
    # 启动服务
    sudo systemctl start sui-fullnode
    
    if [[ $? -eq 0 ]]; then
        log_info "服务启动命令执行成功"
    else
        log_error "服务启动命令失败"
        return 1
    fi
}

# 等待服务启动
wait_for_service() {
    local wait_time=${1:-30}
    log_step "等待服务启动 (最多等待 ${wait_time}秒)..."
    
    local count=0
    while [[ $count -lt $wait_time ]]; do
        if systemctl is-active --quiet sui-fullnode; then
            log_info "服务已启动"
            return 0
        fi
        
        sleep 1
        ((count++))
        
        # 每5秒显示一次进度
        if [[ $((count % 5)) -eq 0 ]]; then
            log_info "等待中... (${count}/${wait_time}秒)"
        fi
    done
    
    log_error "服务启动超时"
    return 1
}

# 检查服务健康状态
check_health() {
    log_step "检查服务健康状态..."
    
    # 等待服务稳定
    sleep 5
    
    # 检查指标接口
    if curl -s http://localhost:9184/metrics | grep -q "sui_"; then
        log_info "✓ 指标接口正常"
    else
        log_warn "⚠ 指标接口异常"
    fi
    
    # 检查RPC接口
    local rpc_response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
        http://localhost:9000 2>/dev/null)
    
    if echo "$rpc_response" | grep -q "result"; then
        log_info "✓ RPC接口正常"
    else
        log_warn "⚠ RPC接口可能还在初始化中"
    fi
    
    # 显示基本信息
    local uptime=$(systemctl show sui-fullnode -p ActiveEnterTimestamp --value)
    log_info "服务启动时间: $uptime"
}

# 显示服务信息
show_service_info() {
    echo
    echo "=========================================="
    echo -e "${GREEN}Sui Fullnode 服务信息${NC}"
    echo "=========================================="
    echo
    echo "服务状态: $(systemctl is-active sui-fullnode)"
    echo "配置文件: /opt/sui/config/fullnode.yaml"
    echo "数据目录: /opt/sui/db/"
    echo "日志文件: journalctl -u sui-fullnode"
    echo
    echo "网络接口:"
    echo "  RPC接口: http://localhost:9000"
    echo "  指标接口: http://localhost:9184/metrics"
    echo
    echo "常用命令:"
    echo "  查看状态: sudo systemctl status sui-fullnode"
    echo "  查看日志: journalctl -u sui-fullnode -f"
    echo "  停止服务: sudo systemctl stop sui-fullnode"
    echo "  重启服务: sudo systemctl restart sui-fullnode"
    echo
}

# 主函数
main() {
    # 默认参数
    local force_start=false
    local wait_time=30
    local check_after_start=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force_start=true
                shift
                ;;
            -w|--wait)
                wait_time="$2"
                shift 2
                ;;
            -c|--check)
                check_after_start=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    echo "=========================================="
    echo "    Sui Fullnode 启动脚本"
    echo "=========================================="
    echo
    
    # 检查服务是否已运行
    if check_service_status; then
        if [[ "$force_start" == "true" ]]; then
            log_warn "服务已在运行，但使用了 --force 选项，将重启服务"
            sudo systemctl restart sui-fullnode
        else
            log_info "服务已在运行"
            show_service_info
            exit 0
        fi
    fi
    
    # 执行启动前检查
    check_config || exit 1
    check_ports
    
    # 启动服务
    start_service || exit 1
    
    # 等待服务启动
    wait_for_service $wait_time || exit 1
    
    # 检查健康状态
    if [[ "$check_after_start" == "true" ]]; then
        check_health
    fi
    
    # 显示服务信息
    show_service_info
    
    log_info "Sui Fullnode 启动完成"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi