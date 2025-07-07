#!/bin/bash

# Sui Fullnode 自动化部署脚本
# 版本: 1.0
# 作者: 部署助手

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

# 检查操作系统
check_os() {
    log_step "检查操作系统..."
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt &> /dev/null; then
            OS="ubuntu"
        elif command -v yum &> /dev/null; then
            OS="centos"
        else
            log_error "不支持的Linux发行版"
            exit 1
        fi
    else
        log_error "仅支持Linux系统"
        exit 1
    fi
    log_info "检测到操作系统: $OS"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要使用root用户运行此脚本"
        exit 1
    fi
}

# 安装系统依赖
install_dependencies() {
    log_step "安装系统依赖..."
    
    if [[ "$OS" == "ubuntu" ]]; then
        sudo apt update
        sudo apt install -y \
            build-essential \
            libssl-dev \
            pkg-config \
            cmake \
            git \
            curl \
            clang \
            libclang-dev \
            llvm-dev \
            libprotobuf-dev \
            protobuf-compiler \
            wget \
            jq \
            chrony
    elif [[ "$OS" == "centos" ]]; then
        sudo yum install -y \
            gcc \
            gcc-c++ \
            openssl-devel \
            pkgconfig \
            cmake \
            git \
            curl \
            clang \
            clang-devel \
            llvm-devel \
            protobuf-devel \
            protobuf-compiler \
            wget \
            jq \
            chrony
    fi
    
    log_info "系统依赖安装完成"
}

# 配置时钟同步
configure_time_sync() {
    log_step "配置时钟同步..."
    
    # 停止并禁用可能冲突的服务
    sudo systemctl stop ntp 2>/dev/null || true
    sudo systemctl disable ntp 2>/dev/null || true
    sudo systemctl stop ntpd 2>/dev/null || true
    sudo systemctl disable ntpd 2>/dev/null || true
    sudo systemctl stop systemd-timesyncd 2>/dev/null || true
    sudo systemctl disable systemd-timesyncd 2>/dev/null || true
    sudo systemctl stop chronyd 2>/dev/null || true
    sudo systemctl disable chronyd 2>/dev/null || true
    sudo systemctl stop chrony 2>/dev/null || true
    sudo systemctl disable chrony 2>/dev/null || true
    
    # 配置 chrony
    sudo tee /etc/chrony/chrony.conf > /dev/null << 'EOF'
# 使用公共 NTP 服务器池
pool 0.pool.ntp.org iburst
pool 1.pool.ntp.org iburst
pool 2.pool.ntp.org iburst
pool 3.pool.ntp.org iburst

# 记录系统时钟获得/丢失时间的速率
driftfile /var/lib/chrony/drift

# 允许系统时钟可以在前三次更新中步进
makestep 1.0 3

# 启用内核同步RTC
rtcsync

# 指定日志文件的目录
logdir /var/log/chrony

# 限制访问
allow 127.0.0.1
deny all
EOF
    
    # 启用并启动 chrony 服务 (根据不同发行版使用不同的服务名)
    if [[ "$OS" == "ubuntu" ]]; then
        sudo systemctl enable chrony
        sudo systemctl start chrony
    elif [[ "$OS" == "centos" ]]; then
        sudo systemctl enable chronyd
        sudo systemctl start chronyd
    fi
    
    # 启用时间同步
    sudo timedatectl set-ntp true
    
    # 等待同步
    sleep 5
    
    # 验证时间同步状态
    if timedatectl show --value -p NTPSynchronized | grep -q "yes"; then
        log_info "✓ 时间同步已启用"
    else
        log_warn "⚠ 时间同步启动中..."
    fi
    
    # 显示 chrony 状态
    if [[ "$OS" == "ubuntu" ]] && systemctl is-active --quiet chrony; then
        log_info "✓ chrony 服务正在运行"
    elif [[ "$OS" == "centos" ]] && systemctl is-active --quiet chronyd; then
        log_info "✓ chronyd 服务正在运行"
    fi
    
    log_info "时钟同步服务: chrony"
    log_info "当前时间: $(date)"
}

# 安装Rust
install_rust() {
    log_step "安装Rust环境..."
    
    if command -v rustc &> /dev/null; then
        log_info "Rust已安装，版本: $(rustc --version)"
    else
        log_info "正在安装Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source ~/.bashrc
        source ~/.cargo/env
        log_info "Rust安装完成"
    fi
    
    # 验证Rust安装
    if ! command -v rustc &> /dev/null; then
        log_error "Rust安装失败"
        exit 1
    fi
}

# 获取最新版本
get_latest_version() {
    log_step "获取Sui最新版本..."
    
    # 可以选择特定版本或使用main分支
    SUI_VERSION=${SUI_VERSION:-"main"}
    log_info "将使用版本: $SUI_VERSION"
}

# 下载并编译Sui
build_sui() {
    log_step "下载和编译Sui..."
    
    # 创建工作目录
    WORK_DIR="/tmp/sui-build"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # 克隆代码
    log_info "克隆Sui代码库..."
    git clone https://github.com/MystenLabs/sui.git
    cd sui
    
    # 切换到指定版本
    if [[ "$SUI_VERSION" != "main" ]]; then
        git checkout "$SUI_VERSION"
    fi
    
    # 设置环境变量
    export LIBCLANG_PATH=/usr/lib/x86_64-linux-gnu
    export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/include"
    
    # 编译
    log_info "开始编译Sui Node (这可能需要较长时间)..."
    cargo build --release --bin sui-node
    
    if [[ $? -eq 0 ]]; then
        log_info "编译成功"
    else
        log_error "编译失败"
        exit 1
    fi
}

# 创建目录结构
create_directories() {
    log_step "创建目录结构..."
    
    sudo mkdir -p /opt/sui/{config,db,logs,bin}
    sudo chown -R $(whoami):$(whoami) /opt/sui
    
    log_info "目录结构创建完成"
}

# 安装二进制文件
install_binary() {
    log_step "安装二进制文件..."
    
    cp "$WORK_DIR/sui/target/release/sui-node" /opt/sui/bin/
    chmod +x /opt/sui/bin/sui-node
    
    # 验证二进制文件
    if /opt/sui/bin/sui-node --version &> /dev/null; then
        log_info "二进制文件安装成功"
    else
        log_error "二进制文件安装失败"
        exit 1
    fi
}

# 创建配置文件
create_config() {
    log_step "创建配置文件..."
    
    # 选择网络
    read -p "选择网络 (mainnet/testnet) [mainnet]: " NETWORK
    NETWORK=${NETWORK:-mainnet}
    
    if [[ "$NETWORK" == "mainnet" ]]; then
        CHECKPOINT_URL="https://checkpoints.mainnet.sui.io"
        GENESIS_URL="https://github.com/MystenLabs/sui-genesis/raw/main/mainnet/genesis.blob"
    elif [[ "$NETWORK" == "testnet" ]]; then
        CHECKPOINT_URL="https://checkpoints.testnet.sui.io"
        GENESIS_URL="https://github.com/MystenLabs/sui-genesis/raw/main/testnet/genesis.blob"
    else
        log_error "无效的网络选择"
        exit 1
    fi
    
    # 创建配置文件
    cat > /opt/sui/config/fullnode.yaml << EOF
db-path: "/opt/sui/db"
network-address: "/ip4/0.0.0.0/tcp/8080/http"
metrics-address: "0.0.0.0:9184"
json-rpc-address: "0.0.0.0:9000"
enable-event-processing: true

p2p-config:
  listen-address: "0.0.0.0:8084"

genesis:
  genesis-file-location: "/opt/sui/config/genesis.blob"

authority-store-pruning-config:
  num-latest-epoch-dbs-to-retain: 3
  epoch-db-pruning-period-secs: 3600
  num-epochs-to-retain: 1
  max-checkpoints-in-batch: 10
  max-transactions-in-batch: 1000
  pruning-run-delay-seconds: 60

state-archive-read-config:
  - ingestion-url: "$CHECKPOINT_URL"
    concurrency: 5
EOF
    
    log_info "配置文件创建完成 (网络: $NETWORK)"
}

# 下载创世文件
download_genesis() {
    log_step "下载创世文件..."
    
    wget "$GENESIS_URL" -O /opt/sui/config/genesis.blob
    
    if [[ $? -eq 0 ]]; then
        log_info "创世文件下载完成"
    else
        log_error "创世文件下载失败"
        exit 1
    fi
}

# 创建systemd服务
create_service() {
    log_step "创建systemd服务..."
    
    sudo tee /etc/systemd/system/sui-fullnode.service > /dev/null << EOF
[Unit]
Description=Sui Fullnode
After=network.target

[Service]
Type=simple
User=$(whoami)
Group=$(whoami)
WorkingDirectory=/opt/sui
ExecStart=/opt/sui/bin/sui-node --config-path /opt/sui/config/fullnode.yaml
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
Environment=RUST_LOG=info,sui_node=info
Environment=RUST_BACKTRACE=1
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "systemd服务创建完成"
}

# 启动服务
start_service() {
    log_step "启动Sui Fullnode服务..."
    
    sudo systemctl daemon-reload
    sudo systemctl enable sui-fullnode
    sudo systemctl start sui-fullnode
    
    sleep 5
    
    if systemctl is-active --quiet sui-fullnode; then
        log_info "Sui Fullnode服务启动成功"
    else
        log_error "Sui Fullnode服务启动失败"
        sudo systemctl status sui-fullnode
        exit 1
    fi
}

# 验证部署
verify_deployment() {
    log_step "验证部署..."
    
    # 等待服务稳定
    sleep 10
    
    # 检查RPC接口
    log_info "检查RPC接口..."
    if curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
        http://localhost:9000 | grep -q "result"; then
        log_info "RPC接口工作正常"
    else
        log_warn "RPC接口暂时不可用，可能还在同步中"
    fi
    
    # 检查指标接口
    log_info "检查指标接口..."
    if curl -s http://localhost:9184/metrics | grep -q "sui_"; then
        log_info "指标接口工作正常"
    else
        log_warn "指标接口不可用"
    fi
}

# 清理临时文件
cleanup() {
    log_step "清理临时文件..."
    rm -rf "$WORK_DIR"
    log_info "清理完成"
}

# 显示完成信息
show_completion() {
    echo
    echo "=========================================="
    echo -e "${GREEN}Sui Fullnode 部署完成！${NC}"
    echo "=========================================="
    echo
    echo "服务状态: $(systemctl is-active sui-fullnode)"
    echo "配置文件: /opt/sui/config/fullnode.yaml"
    echo "日志查看: journalctl -u sui-fullnode -f"
    echo "RPC接口: http://localhost:9000"
    echo "指标接口: http://localhost:9184/metrics"
    echo
    echo "常用命令:"
    echo "  启动服务: sudo systemctl start sui-fullnode"
    echo "  停止服务: sudo systemctl stop sui-fullnode"
    echo "  重启服务: sudo systemctl restart sui-fullnode"
    echo "  查看状态: sudo systemctl status sui-fullnode"
    echo "  查看日志: journalctl -u sui-fullnode -f"
    echo
    echo "注意: 初始同步可能需要几小时到几天时间"
}

# 主函数
main() {
    echo "=========================================="
    echo "    Sui Fullnode 自动化部署脚本"
    echo "=========================================="
    echo
    
    check_root
    check_os
    install_dependencies
    configure_time_sync
    install_rust
    #get_latest_version
    #build_sui
    #create_directories
    #install_binary
    #create_config
    #download_genesis
    create_service
    start_service
    verify_deployment
    cleanup
    show_completion
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi