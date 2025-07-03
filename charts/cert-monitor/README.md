# Cert-Monitor Helm Chart

SSL 证书监控应用的 Helm Chart，支持 Istio 服务网格和 Prometheus 监控。

## 功能特性

- 🔍 SSL 证书监控（远程域名和本地证书文件）
- 📊 Prometheus 指标导出
- 🚀 Istio 服务网格支持
- 🔐 多种证书存储方式
- 📈 自动扩缩容支持
- 🚨 预配置告警规则

## 先决条件

- Kubernetes 1.19+
- Helm 3.2.0+
- Istio 1.10+ (可选)
- Prometheus Operator (用于监控)

## 安装

### 添加 Helm 仓库

```bash
# 如果有私有仓库
helm repo add cert-monitor https://your-helm-repo.com/charts
helm repo update
```

### 基础安装

```bash
# 使用默认配置安装
helm install cert-monitor ./charts/cert-monitor

# 或指定命名空间
helm install cert-monitor ./charts/cert-monitor -n monitoring --create-namespace
```

### 自定义安装

```bash
# 创建自定义 values 文件
cat > my-values.yaml <<EOF
image:
  repository: your-registry/cert-monitor
  tag: "v1.0.0"

istio:
  enabled: true
  gateway:
    hosts:
      - cert-monitor.yourdomain.com

config:
  nacos:
    addr: "http://nacos.default:8848"

certificates:
  local:
    enabled: true
    storage:
      persistentVolume:
        enabled: true
        storageClass: "fast-ssd"
        size: 2Gi
EOF

# 使用自定义配置安装
helm install cert-monitor ./charts/cert-monitor -f my-values.yaml
```

## 配置选项

### 应用配置

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `replicaCount` | 副本数量 | `1` |
| `image.repository` | 镜像仓库 | `cert-monitor` |
| `image.tag` | 镜像标签 | `latest` |
| `image.pullPolicy` | 镜像拉取策略 | `IfNotPresent` |

### Istio 配置

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `istio.enabled` | 启用 Istio | `true` |
| `istio.gateway.enabled` | 启用 Gateway | `true` |
| `istio.gateway.hosts` | Gateway 主机 | `["cert-monitor.local"]` |
| `istio.virtualService.enabled` | 启用 VirtualService | `true` |

### 证书存储配置

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `certificates.local.enabled` | 启用本地证书监控 | `true` |
| `certificates.local.storage.configMap.enabled` | 使用 ConfigMap 存储 | `true` |
| `certificates.local.storage.secret.enabled` | 使用 Secret 存储 | `false` |
| `certificates.local.storage.persistentVolume.enabled` | 使用持久卷 | `false` |

### 监控配置

| 参数 | 描述 | 默认值 |
|------|------|--------|
| `monitoring.serviceMonitor.enabled` | 启用 ServiceMonitor | `true` |
| `monitoring.prometheusRule.enabled` | 启用告警规则 | `true` |

## 证书管理

### 方式一：使用 ConfigMap（推荐用于测试）

```bash
# 从本地证书目录创建 ConfigMap
kubectl create configmap cert-monitor-certs \
  --from-file=certs/ssl/ \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 方式二：使用 Secret（推荐用于生产）

```bash
# 创建 Secret
kubectl create secret generic cert-monitor-certs-secret \
  --from-file=certs/ssl/

# 更新 values.yaml
cat >> my-values.yaml <<EOF
certificates:
  local:
    storage:
      configMap:
        enabled: false
      secret:
        enabled: true
        name: cert-monitor-certs-secret
EOF
```

### 方式三：使用持久卷

```bash
# 更新 values.yaml
cat >> my-values.yaml <<EOF
certificates:
  local:
    storage:
      configMap:
        enabled: false
      persistentVolume:
        enabled: true
        storageClass: "fast-ssd"
        size: 1Gi
EOF

# 然后将证书文件复制到 PV 中
```

## Istio 配置

### Gateway 和 VirtualService

该 Chart 自动创建 Istio Gateway 和 VirtualService：

```yaml
# 自定义 Istio 配置
istio:
  enabled: true
  gateway:
    enabled: true
    hosts:
      - cert-monitor.yourdomain.com
    tls:
      mode: SIMPLE
      credentialName: cert-monitor-tls
  virtualService:
    enabled: true
    hosts:
      - cert-monitor.yourdomain.com
    gateways:
      - cert-monitor-gateway
```

### 创建 TLS 证书

```bash
# 创建 TLS Secret
kubectl create secret tls cert-monitor-tls \
  --cert=path/to/cert.pem \
  --key=path/to/key.pem
```

## 监控和告警

### Prometheus 指标

应用导出以下 Prometheus 指标：

- `cert_expire_days{domain, source}` - 证书剩余天数
- `cert_status{domain, source}` - 证书状态
- `cert_type{domain, source}` - 证书类型（单域名/泛域名）
- `cert_san_count{domain, source}` - SAN 数量

### 预配置告警

Chart 包含以下预配置告警规则：

- **CertificateExpiringSoon**: 证书 30 天内过期
- **CertificateExpired**: 证书已过期
- **CertificateCheckFailed**: 证书检查失败

### 查看监控指标

```bash
# 通过 Istio Gateway 访问
curl https://cert-monitor.yourdomain.com/metrics

# 或通过 kubectl port-forward
kubectl port-forward svc/cert-monitor 9393:9393
curl http://localhost:9393/metrics
```

## 升级

```bash
# 升级 Release
helm upgrade cert-monitor ./charts/cert-monitor -f my-values.yaml

# 查看升级历史
helm history cert-monitor

# 回滚到上一版本
helm rollback cert-monitor
```

## 卸载

```bash
# 卸载 Release
helm uninstall cert-monitor

# 清理相关资源（如果需要）
kubectl delete configmap cert-monitor-certs
kubectl delete secret cert-monitor-tls
```

## 故障排除

### 查看应用日志

```bash
kubectl logs -f deployment/cert-monitor
```

### 检查 Istio 配置

```bash
# 检查 Gateway
kubectl get gateway cert-monitor-gateway -o yaml

# 检查 VirtualService
kubectl get virtualservice cert-monitor-vs -o yaml

# 检查 DestinationRule
kubectl get destinationrule cert-monitor-dr -o yaml
```

### 验证证书挂载

```bash
# 进入 Pod 检查证书文件
kubectl exec -it deployment/cert-monitor -- ls -la /app/certs/ssl/
```

### 检查服务连通性

```bash
# 内部服务测试
kubectl exec -it deployment/cert-monitor -- curl http://localhost:9393/health

# 通过 Service 测试
kubectl run test-pod --image=curlimages/curl -it --rm -- \
  curl http://cert-monitor:9393/metrics
```

## 开发

### 本地测试

```bash
# 模板渲染测试
helm template cert-monitor ./charts/cert-monitor -f values.yaml

# 语法检查
helm lint ./charts/cert-monitor

# 打包
helm package ./charts/cert-monitor
```

### 更新依赖

```bash
# 更新 Chart 依赖
helm dependency update ./charts/cert-monitor
```

## 许可证

[LICENSE](../../LICENSE)

## 贡献

欢迎提交 Pull Request 和 Issue！