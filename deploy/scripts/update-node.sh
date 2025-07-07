#!/bin/bash

# Sui Fullnode 更新脚本
# 用于更新 Sui Fullnode 到最新版本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
SUI_DIR="/tmp/sui-update"
BACKUP_DIR="/opt/sui/backup/$(date +%Y%m%d_%H%M%S)"

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
    echo "Sui Fullnode 更新脚本"
    echo
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -v, --version VERSION    指定要更新的版本 (默认: main)"
    echo "  -b, --backup            创建数据备份"
    echo "  -n, --no-restart        更新后不重启服务"
    echo "  -h, --help              显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0                      # 更新到最新版本"
    echo "  $0 -v v1.15.0          # 更新到指定版本"
    echo "  $0 -b                   # 更新并备份数据"
}

# 解析命令行参数
parse_args() {
    SUI_VERSION="main"
    CREATE_BACKUP=false
    RESTART_SERVICE=true
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                SUI_VERSION="$2"
                shift 2
                ;;
            -b|--backup)
                CREATE_BACKUP=true
                shift
                ;;
            -n|--no-restart)
                RESTART_SERVICE=false
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
}

# 检查前置条件
check_prerequisites() {
    log_step "检查前置条件..."
    
    # 检查是否为root用户
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要使用root用户运行此脚本"
        exit 1
    fi
    
    # 检查服务是否存在
    if ! systemctl list-unit-files | grep -q sui-fullnode; then
        log_error "sui-fullnode服务不存在"
        exit 1
    fi
    
    # 检查必要的命令
    for cmd in git cargo curl systemctl; do
        if ! command -v $cmd &> /dev/null; then
            log_error "缺少必要命令: $cmd"
            exit 1
        fi
    done
    
    # 检查当前版本
    if [[ -f "/opt/sui/bin/sui-node" ]]; then
        CURRENT_VERSION=$(/opt/sui/bin/sui-node --version 2>/dev/null || echo "Unknown")
        log_info "当前版本: $CURRENT_VERSION"
    else
        log_warn "当前二进制文件不存在"
    fi
    
    log_info "前置条件检查完成"
}

# 创建备份
create_backup() {
    if [[ "$CREATE_BACKUP" == "true" ]]; then
        log_step "创建数据备份..."
        
        # 停止服务
        log_info "停止服务以创建一致性备份..."
        sudo systemctl stop sui-fullnode
        
        # 创建备份目录
        sudo mkdir -p "$BACKUP_DIR"
        
        # 备份数据库
        if [[ -d "/opt/sui/db" ]]; then
            log_info "备份数据库到 $BACKUP_DIR"
            sudo cp -r /opt/sui/db "$BACKUP_DIR/"
        fi
        
        # 备份配置文件
        if [[ -f "/opt/sui/config/fullnode.yaml" ]]; then
            sudo cp /opt/sui/config/fullnode.yaml "$BACKUP_DIR/"
        fi
        
        # 备份当前二进制文件
        if [[ -f "/opt/sui/bin/sui-node" ]]; then
            sudo cp /opt/sui/bin/sui-node "$BACKUP_DIR/sui-node.old"
        fi
        
        log_info "备份完成: $BACKUP_DIR"
        
        # 重新启动服务
        sudo systemctl start sui-fullnode
    fi
}

# 获取最新代码
download_code() {
    log_step "下载最新代码..."
    
    # 清理旧的临时目录
    rm -rf "$SUI_DIR"
    mkdir -p "$SUI_DIR"
    cd "$SUI_DIR"
    
    # 克隆代码
    log_info "克隆Sui代码库..."
    git clone https://github.com/MystenLabs/sui.git
    cd sui
    
    # 切换到指定版本
    if [[ "$SUI_VERSION" != "main" ]]; then
        log_info "切换到版本: $SUI_VERSION"
        git checkout "$SUI_VERSION"
    else
        log_info "使用主分支最新代码"
    fi
    
    # 显示当前版本信息
    COMMIT_HASH=$(git rev-parse HEAD)
    COMMIT_DATE=$(git show -s --format=%ci HEAD)
    log_info "提交哈希: $COMMIT_HASH"
    log_info "提交时间: $COMMIT_DATE"
}

# 编译新版本
compile_node() {
    log_step "编译新版本..."
    
    cd "$SUI_DIR/sui"
    
    # 设置环境变量
    export LIBCLANG_PATH=/usr/lib/x86_64-linux-gnu
    export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/include"
    
    # 清理之前的构建
    cargo clean
    
    # 编译
    log_info "开始编译 (这可能需要较长时间)..."
    cargo build --release --bin sui-node
    
    if [[ $? -eq 0 ]]; then
        log_info "编译成功"
    else
        log_error "编译失败"
        exit 1
    fi
    
    # 验证新二进制文件
    NEW_VERSION=$(./target/release/sui-node --version 2>/dev/null || echo "Unknown")
    log_info "新版本: $NEW_VERSION"
}

# 停止服务
stop_service() {
    log_step "停止Sui Fullnode服务..."
    
    if systemctl is-active --quiet sui-fullnode; then
        sudo systemctl stop sui-fullnode
        log_info "服务已停止"
        
        # 等待服务完全停止
        sleep 5
        
        # 确认服务已停止
        if systemctl is-active --quiet sui-fullnode; then
            log_error "服务停止失败"
            exit 1
        fi
    else
        log_info "服务未运行"
    fi
}

# 安装新版本
install_new_version() {
    log_step "安装新版本..."
    
    # 备份当前二进制文件
    if [[ -f "/opt/sui/bin/sui-node" ]]; then
        sudo cp /opt/sui/bin/sui-node /opt/sui/bin/sui-node.bak
        log_info "当前版本已备份为 sui-node.bak"
    fi
    
    # 复制新二进制文件
    sudo cp "$SUI_DIR/sui/target/release/sui-node" /opt/sui/bin/
    sudo chmod +x /opt/sui/bin/sui-node
    
    # 验证安装
    if /opt/sui/bin/sui-node --version &> /dev/null; then
        NEW_INSTALLED_VERSION=$(/opt/sui/bin/sui-node --version)
        log_info "新版本安装成功: $NEW_INSTALLED_VERSION"
    else
        log_error "新版本安装失败"
        
        # 恢复备份
        if [[ -f "/opt/sui/bin/sui-node.bak" ]]; then
            log_info "恢复之前版本..."
            sudo cp /opt/sui/bin/sui-node.bak /opt/sui/bin/sui-node
        fi
        exit 1
    fi
}

# 启动服务
start_service() {
    if [[ "$RESTART_SERVICE" == "true" ]]; then
        log_step "启动Sui Fullnode服务..."
        
        sudo systemctl start sui-fullnode
        
        # 等待服务启动
        sleep 10
        
        # 检查服务状态
        if systemctl is-active --quiet sui-fullnode; then
            log_info "服务启动成功"
            
            # 检查服务是否正常工作
            sleep 20
            if curl -s http://localhost:9184/metrics | grep -q "sui_"; then
                log_info "服务运行正常"
            else
                log_warn "服务可能还在初始化中"
            fi
        else
            log_error "服务启动失败"
            
            # 显示服务状态
            sudo systemctl status sui-fullnode --no-pager
            
            # 恢复备份
            if [[ -f "/opt/sui/bin/sui-node.bak" ]]; then
                log_info "恢复之前版本..."
                sudo cp /opt/sui/bin/sui-node.bak /opt/sui/bin/sui-node
                sudo systemctl start sui-fullnode
            fi
            exit 1
        fi
    else
        log_info "跳过服务重启 (使用了 --no-restart 选项)"
    fi
}

# 清理临时文件
cleanup() {
    log_step "清理临时文件..."
    
    rm -rf "$SUI_DIR"
    
    # 删除备份的二进制文件 (保留一段时间后再删除)
    # sudo rm -f /opt/sui/bin/sui-node.bak
    
    log_info "清理完成"
}

# 显示更新结果
show_result() {
    log_step "更新完成"
    
    echo
    echo "=========================================="
    echo -e "${GREEN}Sui Fullnode 更新完成！${NC}"
    echo "=========================================="
    echo
    
    if [[ -f "/opt/sui/bin/sui-node" ]]; then
        FINAL_VERSION=$(/opt/sui/bin/sui-node --version)
        echo "当前版本: $FINAL_VERSION"
    fi
    
    if [[ "$CREATE_BACKUP" == "true" ]]; then
        echo "备份位置: $BACKUP_DIR"
    fi
    
    echo "服务状态: $(systemctl is-active sui-fullnode)"
    echo
    echo "常用命令:"
    echo "  查看状态: sudo systemctl status sui-fullnode"
    echo "  查看日志: journalctl -u sui-fullnode -f"
    echo "  检查运行: curl http://localhost:9184/metrics"
    echo
    
    if [[ "$RESTART_SERVICE" == "false" ]]; then
        echo "注意: 服务未重启，请手动重启以使用新版本:"
        echo "  sudo systemctl restart sui-fullnode"
    fi
}

# 错误处理
handle_error() {
    log_error "更新过程中发生错误"
    
    # 尝试恢复服务
    if [[ -f "/opt/sui/bin/sui-node.bak" ]]; then
        log_info "尝试恢复之前版本..."
        sudo cp /opt/sui/bin/sui-node.bak /opt/sui/bin/sui-node
        sudo systemctl start sui-fullnode
    fi
    
    # 清理临时文件
    rm -rf "$SUI_DIR"
    
    exit 1
}

# 主函数
main() {
    echo "=========================================="
    echo "    Sui Fullnode 更新脚本"
    echo "=========================================="
    echo
    
    # 设置错误处理
    trap handle_error ERR
    
    parse_args "$@"
    check_prerequisites
    create_backup
    download_code
    compile_node
    stop_service
    install_new_version
    start_service
    cleanup
    show_result
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi