#!/bin/bash

# Sui Fullnode 停止脚本
# 用于安全停止 Sui Fullnode 服务

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
    echo "Sui Fullnode 停止脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -f, --force           强制停止 (使用 SIGKILL)"
    echo "  -w, --wait SECONDS    等待优雅停止的时间 (默认: 30秒)"
    echo "  -b, --backup          停止前创建数据备份"
    echo "  -h, --help            显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0                    # 优雅停止服务"
    echo "  $0 -f                 # 强制停止服务"
    echo "  $0 -b                 # 停止前备份数据"
    echo "  $0 -w 60             # 等待60秒后强制停止"
}

# 检查服务状态
check_service_status() {
    if systemctl is-active --quiet sui-fullnode; then
        return 0  # 服务正在运行
    else
        return 1  # 服务未运行
    fi
}

# 获取服务进程信息
get_process_info() {
    local pid=$(systemctl show sui-fullnode -p MainPID --value)
    if [[ "$pid" != "0" ]] && [[ ! -z "$pid" ]]; then
        echo "$pid"
        return 0
    else
        return 1
    fi
}

# 显示服务状态
show_current_status() {
    log_step "当前服务状态..."
    
    if check_service_status; then
        log_info "服务状态: 运行中"
        
        local pid=$(get_process_info)
        if [[ ! -z "$pid" ]]; then
            log_info "进程ID: $pid"
            
            # 显示资源使用情况
            local mem_usage=$(ps -p $pid -o %mem --no-headers | tr -d ' ')
            local cpu_usage=$(ps -p $pid -o %cpu --no-headers | tr -d ' ')
            log_info "内存使用: ${mem_usage}%"
            log_info "CPU使用: ${cpu_usage}%"
            
            # 显示运行时间
            local start_time=$(ps -p $pid -o lstart --no-headers)
            log_info "启动时间: $start_time"
        fi
    else
        log_info "服务状态: 未运行"
    fi
}

# 创建数据备份
create_backup() {
    log_step "创建数据备份..."
    
    local backup_dir="/opt/sui/backup/$(date +%Y%m%d_%H%M%S)"
    
    # 创建备份目录
    sudo mkdir -p "$backup_dir"
    
    # 备份配置文件
    if [[ -f "/opt/sui/config/fullnode.yaml" ]]; then
        sudo cp /opt/sui/config/fullnode.yaml "$backup_dir/"
        log_info "配置文件已备份"
    fi
    
    # 备份关键数据 (不备份完整数据库，太大)
    if [[ -d "/opt/sui/db" ]]; then
        # 只备份小的关键文件
        sudo find /opt/sui/db -name "*.log" -o -name "*.json" -o -name "CURRENT" | head -20 | \
        sudo xargs -I {} cp {} "$backup_dir/" 2>/dev/null || true
        log_info "关键数据文件已备份"
    fi
    
    log_info "备份完成: $backup_dir"
}

# 优雅停止服务
graceful_stop() {
    local wait_time=${1:-30}
    log_step "优雅停止服务 (等待最多 ${wait_time}秒)..."
    
    # 发送停止信号
    sudo systemctl stop sui-fullnode
    
    # 等待服务停止
    local count=0
    while [[ $count -lt $wait_time ]]; do
        if ! check_service_status; then
            log_info "服务已停止"
            return 0
        fi
        
        sleep 1
        ((count++))
        
        # 每5秒显示一次进度
        if [[ $((count % 5)) -eq 0 ]]; then
            log_info "等待停止... (${count}/${wait_time}秒)"
        fi
    done
    
    log_warn "优雅停止超时"
    return 1
}

# 强制停止服务
force_stop() {
    log_step "强制停止服务..."
    
    local pid=$(get_process_info)
    if [[ ! -z "$pid" ]]; then
        log_warn "发送 SIGKILL 信号到进程 $pid"
        sudo kill -9 $pid 2>/dev/null || true
        
        # 等待进程结束
        sleep 2
        
        if ! check_service_status; then
            log_info "服务已强制停止"
        else
            log_error "强制停止失败"
            return 1
        fi
    else
        log_info "未找到运行中的进程"
    fi
    
    # 确保systemd状态正确
    sudo systemctl stop sui-fullnode 2>/dev/null || true
}

# 清理残留资源
cleanup_resources() {
    log_step "清理残留资源..."
    
    # 检查端口占用
    local ports=(8080 8084 9000 9184)
    for port in "${ports[@]}"; do
        local pid=$(lsof -ti :$port 2>/dev/null || echo "")
        if [[ ! -z "$pid" ]]; then
            local process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
            if [[ "$process" == "sui-node" ]]; then
                log_warn "清理端口 $port 上的残留进程 $pid"
                sudo kill -9 $pid 2>/dev/null || true
            fi
        fi
    done
    
    # 清理临时文件
    sudo rm -f /tmp/sui-* 2>/dev/null || true
    
    log_info "资源清理完成"
}

# 显示停止后状态
show_final_status() {
    echo
    echo "=========================================="
    echo -e "${GREEN}Sui Fullnode 停止完成${NC}"
    echo "=========================================="
    echo
    echo "服务状态: $(systemctl is-active sui-fullnode)"
    echo "停止时间: $(date)"
    echo
    echo "常用命令:"
    echo "  启动服务: sudo systemctl start sui-fullnode"
    echo "  查看状态: sudo systemctl status sui-fullnode"
    echo "  查看日志: journalctl -u sui-fullnode -n 50"
    echo
    
    # 显示数据目录大小
    if [[ -d "/opt/sui/db" ]]; then
        local db_size=$(du -sh /opt/sui/db 2>/dev/null | cut -f1)
        echo "数据目录大小: $db_size"
    fi
}

# 确认停止操作
confirm_stop() {
    local force_mode=$1
    
    if [[ "$force_mode" == "true" ]]; then
        log_warn "即将强制停止 Sui Fullnode 服务"
        read -p "确认强制停止? (y/N): " confirm
    else
        log_info "即将停止 Sui Fullnode 服务"
        read -p "确认停止? (y/N): " confirm
    fi
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
}

# 主函数
main() {
    # 默认参数
    local force_stop_mode=false
    local wait_time=30
    local create_backup_flag=false
    local interactive=true
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force_stop_mode=true
                shift
                ;;
            -w|--wait)
                wait_time="$2"
                shift 2
                ;;
            -b|--backup)
                create_backup_flag=true
                shift
                ;;
            -y|--yes)
                interactive=false
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
    echo "    Sui Fullnode 停止脚本"
    echo "=========================================="
    echo
    
    # 检查服务是否运行
    if ! check_service_status; then
        log_info "服务未在运行"
        exit 0
    fi
    
    # 显示当前状态
    show_current_status
    echo
    
    # 交互式确认
    if [[ "$interactive" == "true" ]]; then
        confirm_stop $force_stop_mode
    fi
    
    # 创建备份
    if [[ "$create_backup_flag" == "true" ]]; then
        create_backup
        echo
    fi
    
    # 停止服务
    if [[ "$force_stop_mode" == "true" ]]; then
        force_stop || exit 1
    else
        if ! graceful_stop $wait_time; then
            log_warn "优雅停止失败，将强制停止"
            force_stop || exit 1
        fi
    fi
    
    # 清理资源
    cleanup_resources
    
    # 显示最终状态
    show_final_status
    
    log_info "Sui Fullnode 已安全停止"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi