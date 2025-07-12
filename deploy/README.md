# Sui Fullnode 部署指南

## 概述

本文档提供了 Sui Fullnode 的完整部署指南，包括自动化部署脚本和手动部署步骤。

## 系统要求

### 硬件要求
- **CPU**: 8核心 (推荐16核心)
- **内存**: 32 GB (推荐64 GB)
- **存储**: 2 TB SSD (推荐 NVMe)
- **网络**: 100 Mbps (推荐1 Gbps)

### 软件要求
- **操作系统**: Ubuntu 20.04+ / CentOS 8+
- **用户权限**: 非root用户 (具有sudo权限)
- **时钟同步**: 需要准确的系统时间 (使用 chrony)

## 网络端口

| 端口 | 协议 | 用途 | 访问范围 |
|------|------|------|----------|
| 8080 | TCP | 协议接口 | 内部 |
| 8084 | UDP | P2P 状态同步 | 公网 |
| 9000 | TCP | JSON-RPC 接口 | 可选公网 |
| 9184 | TCP | 指标接口 | 内部 |

## 快速部署

### 1. 自动化部署

#### 方式一：从GitHub克隆并编译
```bash
# 克隆项目
git clone https://github.com/MystenLabs/sui.git
cd sui/deploy

# 给脚本添加执行权限
chmod +x deploy-sui-fullnode.sh

# 运行部署脚本（自动克隆最新代码）
./deploy-sui-fullnode.sh
```

#### 方式二：编译本地源码
```bash
# 进入Sui项目目录
cd /path/to/sui

# 给脚本添加执行权限
chmod +x deploy/deploy-sui-fullnode.sh

# 编译当前目录的项目
./deploy/deploy-sui-fullnode.sh --local

# 或编译指定路径的项目
./deploy/deploy-sui-fullnode.sh --local /path/to/sui/source
```

#### 命令选项说明
- `-l, --local [PATH]` - 使用本地源码编译（可选指定路径，默认当前目录）
- `-h, --help` - 显示帮助信息

#### 使用示例
```bash
# 查看帮助
./deploy-sui-fullnode.sh --help

# 编译当前目录
./deploy-sui-fullnode.sh -l

# 编译指定目录
./deploy-sui-fullnode.sh --local /home/user/sui

# 从GitHub自动部署（默认）
./deploy-sui-fullnode.sh
```

### 2. 手动部署

#### 步骤1: 安装依赖

```bash
# Ubuntu/Debian
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

# CentOS/RHEL
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
```

#### 步骤2: 配置时钟同步

```bash
# 停止可能冲突的时间同步服务
sudo systemctl stop ntp ntpd systemd-timesyncd 2>/dev/null || true
sudo systemctl disable ntp ntpd systemd-timesyncd 2>/dev/null || true

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

# 启用并启动 chronyd
sudo systemctl enable chronyd
sudo systemctl start chronyd

# 启用时间同步
sudo timedatectl set-ntp true

# 验证时间同步状态
timedatectl status
chrony sources -v
```

#### 步骤3: 安装Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.bashrc
```

#### 步骤4: 编译Sui

```bash
git clone https://github.com/MystenLabs/sui.git
cd sui
cargo build --release --bin sui-node
```

#### 步骤5: 创建目录结构

```bash
sudo mkdir -p /opt/sui/{config,db,logs,bin}
sudo chown -R $(whoami):$(whoami) /opt/sui
cp target/release/sui-node /opt/sui/bin/
```

#### 步骤6: 配置文件

```bash
cat > /opt/sui/config/fullnode.yaml << 'EOF'
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
  - ingestion-url: "https://checkpoints.mainnet.sui.io"
    concurrency: 5
EOF
```

#### 步骤7: 下载创世文件

```bash
# Mainnet
wget https://github.com/MystenLabs/sui-genesis/raw/main/mainnet/genesis.blob -O /opt/sui/config/genesis.blob

# Testnet (可选)
# wget https://github.com/MystenLabs/sui-genesis/raw/main/testnet/genesis.blob -O /opt/sui/config/genesis.blob
```

#### 步骤8: 创建systemd服务

```bash
sudo tee /etc/systemd/system/sui-fullnode.service > /dev/null << 'EOF'
[Unit]
Description=Sui Fullnode
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
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
```

#### 步骤9: 启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl enable sui-fullnode
sudo systemctl start sui-fullnode
```

## 运维管理

### 服务管理

#### 使用脚本管理 (推荐)

```bash
# 启动服务
./scripts/start-node.sh

# 启动并检查状态
./scripts/start-node.sh -c

# 停止服务
./scripts/stop-node.sh

# 强制停止服务
./scripts/stop-node.sh -f

# 停止前备份数据
./scripts/stop-node.sh -b
```

#### 使用 systemctl 管理

```bash
# 查看服务状态
sudo systemctl status sui-fullnode

# 启动服务
sudo systemctl start sui-fullnode

# 停止服务
sudo systemctl stop sui-fullnode

# 重启服务
sudo systemctl restart sui-fullnode

# 查看日志
journalctl -u sui-fullnode -f
```

### 监控检查

```bash
# 检查RPC接口
curl -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
  http://localhost:9000

# 查看指标
curl http://localhost:9184/metrics

# 检查数据库大小
du -sh /opt/sui/db/

# 检查同步状态
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
  http://localhost:9000 | jq
```

### 软件更新

#### 方式一：使用更新脚本（推荐）

```bash
# 更新到最新版本
./scripts/update-node.sh

# 更新到指定版本
./scripts/update-node.sh -v v1.15.0

# 更新并备份数据
./scripts/update-node.sh -b

# 使用本地源码更新
./scripts/update-node.sh -l

# 使用指定路径的本地源码更新
./scripts/update-node.sh --local /path/to/sui

# 更新但不重启服务
./scripts/update-node.sh -n

# 查看更新脚本帮助
./scripts/update-node.sh -h
```

#### 方式二：手动更新

```bash
# 停止服务
sudo systemctl stop sui-fullnode

# 更新代码
cd /path/to/sui
git pull

# 重新编译
cargo build --release --bin sui-node

# 更新二进制文件
cp target/release/sui-node /opt/sui/bin/

# 启动服务
sudo systemctl start sui-fullnode
```

#### 更新脚本功能说明

更新脚本 `scripts/update-node.sh` 提供以下功能：

- **自动版本管理**：支持更新到最新版本或指定版本
- **数据备份**：可选择在更新前备份数据库和配置文件
- **本地源码编译**：支持使用本地源码编译，无需从GitHub克隆
- **服务管理**：自动停止、更新和重启服务
- **错误恢复**：更新失败时自动恢复到之前版本
- **版本验证**：编译前后验证版本信息

#### 更新最佳实践

1. **更新前检查**：
   ```bash
   # 检查当前服务状态
   sudo systemctl status sui-fullnode
   
   # 检查磁盘空间
   df -h /opt/sui/
   
   # 检查当前版本
   /opt/sui/bin/sui-node --version
   ```

2. **推荐更新流程**：
   ```bash
   # 带备份的更新
   ./scripts/update-node.sh -b
   
   # 验证更新结果
   sudo systemctl status sui-fullnode
   journalctl -u sui-fullnode -f
   ```

3. **回滚操作**：
   ```bash
   # 如果更新有问题，恢复备份
   sudo systemctl stop sui-fullnode
   sudo cp /opt/sui/bin/sui-node.bak /opt/sui/bin/sui-node
   sudo systemctl start sui-fullnode
   ```

### 数据备份

```bash
# 停止服务
sudo systemctl stop sui-fullnode

# 备份数据库
tar -czf sui-db-backup-$(date +%Y%m%d).tar.gz /opt/sui/db/

# 启动服务
sudo systemctl start sui-fullnode
```

### 故障排除

#### 常见问题

1. **编译失败**
   - 检查系统依赖是否完整安装
   - 确保有足够的内存和磁盘空间
   - 验证clang和libclang-dev是否正确安装

2. **服务启动失败**
   - 检查配置文件语法
   - 确保端口未被占用
   - 查看系统日志: `journalctl -u sui-fullnode -n 50`

3. **同步速度慢**
   - 检查网络连接
   - 考虑调整并发参数
   - 确保有足够的磁盘空间

4. **libclang错误**
   ```bash
   # 安装缺失的依赖
   sudo apt install -y clang libclang-dev llvm-dev
   
   # 设置环境变量
   export LIBCLANG_PATH=/usr/lib/x86_64-linux-gnu
   export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/include"
   ```

#### 日志分析

```bash
# 查看错误日志
journalctl -u sui-fullnode -p err

# 查看最近的日志
journalctl -u sui-fullnode --since "1 hour ago"

# 搜索特定关键词
journalctl -u sui-fullnode -g "ERROR"

# 查看详细启动日志
journalctl -u sui-fullnode -f --no-pager
```

## 性能优化

### 配置调优

```yaml
# 高性能配置示例
state-archive-read-config:
  - ingestion-url: "https://checkpoints.mainnet.sui.io"
    concurrency: 10  # 增加并发

authority-store-pruning-config:
  num-latest-epoch-dbs-to-retain: 2  # 减少保留
  epoch-db-pruning-period-secs: 1800  # 更频繁的清理
  
# 添加更多检查点服务器
state-archive-read-config:
  - ingestion-url: "https://checkpoints.mainnet.sui.io"
    concurrency: 5
  - ingestion-url: "https://checkpoints-alt.mainnet.sui.io"
    concurrency: 5
```

### 系统优化

```bash
# 增加文件描述符限制
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf

# 优化网络参数
echo "net.core.rmem_max = 268435456" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max = 268435456" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 268435456" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 268435456" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 磁盘优化

```bash
# 使用SSD并启用TRIM
sudo fstrim -v /opt/sui/db/

# 设置定期TRIM
echo "0 2 * * 0 /sbin/fstrim -v /opt/sui/db/" | sudo tee -a /etc/crontab
```

## 安全考虑

### 防火墙配置

```bash
# 仅开放必要端口
sudo ufw allow 8084/udp  # P2P
sudo ufw allow 9000/tcp  # RPC (仅在需要外部访问时)

# 限制SSH访问
sudo ufw allow from <YOUR_IP> to any port 22
```

### 访问控制

```bash
# 限制RPC访问 (修改配置文件)
json-rpc-address: "127.0.0.1:9000"  # 仅本地访问

# 或使用nginx代理进行访问控制
```

### 监控告警

```bash
# 创建监控脚本
cat > /opt/sui/monitor.sh << 'EOF'
#!/bin/bash
# 检查服务状态
if ! systemctl is-active --quiet sui-fullnode; then
    echo "Sui Fullnode service is down!" | mail -s "Sui Alert" admin@example.com
fi

# 检查磁盘空间
DISK_USAGE=$(df /opt/sui/db/ | awk 'NR==2 {print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 80 ]; then
    echo "Disk usage is ${DISK_USAGE}%" | mail -s "Disk Alert" admin@example.com
fi
EOF

chmod +x /opt/sui/monitor.sh

# 添加定时任务
echo "*/5 * * * * /opt/sui/monitor.sh" | crontab -
```

## 网络配置

### Mainnet vs Testnet

```bash
# Mainnet 配置
state-archive-read-config:
  - ingestion-url: "https://checkpoints.mainnet.sui.io"
    concurrency: 5

# Testnet 配置
state-archive-read-config:
  - ingestion-url: "https://checkpoints.testnet.sui.io"
    concurrency: 5
```

### 多网络支持

```bash
# 创建多个配置文件
cp /opt/sui/config/fullnode.yaml /opt/sui/config/mainnet.yaml
cp /opt/sui/config/fullnode.yaml /opt/sui/config/testnet.yaml

# 修改testnet配置
sed -i 's/mainnet/testnet/g' /opt/sui/config/testnet.yaml
```

## 支持和社区

- [Sui官方文档](https://docs.sui.io/)
- [Sui GitHub](https://github.com/MystenLabs/sui)
- [Sui Discord](https://discord.gg/sui)
- [Sui论坛](https://forum.sui.io/)
- [Sui开发者资源](https://sui.io/resources/)

## 常见问题解答

### Q: 初始同步需要多长时间？
A: 根据网络速度和硬件配置，通常需要几小时到几天。可以通过增加并发数来加速同步。

### Q: 如何检查同步进度？
A: 使用RPC接口查询当前检查点号，并与网络最新检查点比较。

### Q: 可以在同一台服务器上运行多个fullnode吗？
A: 可以，但需要使用不同的端口和数据目录。

### Q: 如何从快照恢复？
A: 停止服务，删除数据库，从备份恢复，然后重启服务。

### Q: 内存使用过高怎么办？
A: 调整pruning配置，减少保留的epoch数量。

## 变更日志

### v1.1
- 新增本地源码编译支持
- 增强更新脚本功能
- 添加自动化备份和恢复机制
- 改进错误处理和版本验证
- 优化部署文档和使用说明

### v1.0
- 初始版本发布
- 支持自动化部署
- 包含完整的运维文档

## 许可证

本部署指南遵循 MIT 许可证。