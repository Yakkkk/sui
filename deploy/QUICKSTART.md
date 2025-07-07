# Sui Fullnode 快速部署指南

## 一键部署

```bash
# 1. 进入部署目录
cd /home/yak/myrust/sui/deploy

# 2. 运行自动化部署脚本
./deploy-sui-fullnode.sh
```

## 部署后验证

```bash
# 检查服务状态
sudo systemctl status sui-fullnode

# 查看实时日志
journalctl -u sui-fullnode -f

# 运行状态检查
./scripts/check-status.sh

# 检查RPC接口
curl -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "sui_getLatestCheckpointSequenceNumber", "id": 1}' \
  http://localhost:9000
```

## 常用管理命令

### 启动停止服务
```bash
# 启动服务
./scripts/start-node.sh

# 停止服务
./scripts/stop-node.sh

# 强制停止
./scripts/stop-node.sh -f
```

### 监控管理
```bash
# 查看状态
./scripts/check-status.sh

# 更新节点
./scripts/update-node.sh

# 监控状态
./scripts/monitor.sh
```

### 系统命令
```bash
# 查看日志
journalctl -u sui-fullnode -f

# 重启服务
sudo systemctl restart sui-fullnode
```

## 文件结构

```
deploy/
├── deploy-sui-fullnode.sh          # 自动化部署脚本
├── README.md                       # 详细文档
├── QUICKSTART.md                   # 快速开始指南
├── config-templates/               # 配置模板
│   ├── fullnode-mainnet.yaml      # 主网配置
│   └── fullnode-testnet.yaml      # 测试网配置
├── scripts/                        # 运维脚本
│   ├── check-status.sh            # 状态检查
│   ├── update-node.sh             # 更新脚本
│   └── monitor.sh                 # 监控脚本
├── systemd/                        # 系统服务
│   └── sui-fullnode.service       # systemd服务文件
└── config/                         # 配置文件
    └── monitor.conf               # 监控配置
```

## 网络选择

部署脚本会询问选择网络：
- `mainnet`: 主网 (生产环境)
- `testnet`: 测试网 (开发测试)

## 配置文件位置

- **配置文件**: `/opt/sui/config/fullnode.yaml`
- **数据目录**: `/opt/sui/db/`
- **日志文件**: `journalctl -u sui-fullnode`
- **二进制文件**: `/opt/sui/bin/sui-node`

## 端口说明

| 端口 | 用途 | 公开 |
|------|------|------|
| 8080 | 协议接口 | 否 |
| 8084 | P2P同步 | 是 |
| 9000 | JSON-RPC | 可选 |
| 9184 | 监控指标 | 否 |

## 故障排除

1. **编译失败**: 确保安装了所有依赖包
2. **服务启动失败**: 检查配置文件和端口占用
3. **同步缓慢**: 检查网络连接和磁盘IO
4. **资源不足**: 查看内存和磁盘使用情况

更多详细信息请参阅 [README.md](README.md)。