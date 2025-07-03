#!/bin/bash

# Cert-Monitor 部署脚本
# 支持 Kubernetes + Istio 部署

set -e

# 默认值
NAMESPACE="monitoring"
RELEASE_NAME="cert-monitor"
CHART_PATH="./charts/cert-monitor"
VALUES_FILE=""
DRY_RUN=false
CREATE_NAMESPACE=true
ISTIO_ENABLED=true

# 帮助信息
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
    -n, --namespace NAMESPACE     指定命名空间 (默认: monitoring)
    -r, --release RELEASE_NAME    指定 Release 名称 (默认: cert-monitor)
    -f, --values VALUES_FILE      指定自定义 values 文件
    -d, --dry-run                 干跑模式，不实际部署
    --no-namespace                不创建命名空间
    --no-istio                    禁用 Istio
    -h, --help                    显示帮助信息

示例:
    $0                                          # 使用默认配置部署
    $0 -n production -f prod-values.yaml       # 生产环境部署
    $0 -d                                       # 干跑模式
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -r|--release)
            RELEASE_NAME="$2"
            shift 2
            ;;
        -f|--values)
            VALUES_FILE="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-namespace)
            CREATE_NAMESPACE=false
            shift
            ;;
        --no-istio)
            ISTIO_ENABLED=false
            shift
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

echo "🚀 开始部署 Cert-Monitor..."
echo "  命名空间: $NAMESPACE"
echo "  Release: $RELEASE_NAME"
echo "  Istio: $ISTIO_ENABLED"

# 检查必要工具
check_tools() {
    echo "🔍 检查必要工具..."

    if ! command -v kubectl &> /dev/null; then
        echo "❌ kubectl 未安装"
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        echo "❌ helm 未安装"
        exit 1
    fi

    if [[ "$ISTIO_ENABLED" == "true" ]] && ! command -v istioctl &> /dev/null; then
        echo "⚠️  istioctl 未安装，将跳过 Istio 检查"
    fi

    echo "✅ 工具检查完成"
}

# 检查 Kubernetes 连接
check_k8s() {
    echo "🔍 检查 Kubernetes 连接..."

    if ! kubectl cluster-info &> /dev/null; then
        echo "❌ 无法连接到 Kubernetes 集群"
        exit 1
    fi

    echo "✅ Kubernetes 连接正常"
}

# 检查 Istio 状态
check_istio() {
    if [[ "$ISTIO_ENABLED" == "true" ]]; then
        echo "🔍 检查 Istio 状态..."

        if ! kubectl get namespace istio-system &> /dev/null; then
            echo "⚠️  Istio 系统命名空间不存在，请先安装 Istio"
            echo "   安装命令: istioctl install --set values.defaultRevision=default"
            exit 1
        fi

        if ! kubectl get pods -n istio-system -l app=istiod | grep -q Running; then
            echo "⚠️  Istio 控制平面未运行"
            exit 1
        fi

        echo "✅ Istio 状态正常"
    fi
}

# 创建命名空间
create_namespace() {
    if [[ "$CREATE_NAMESPACE" == "true" ]]; then
        echo "📦 创建命名空间 $NAMESPACE..."

        if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
            kubectl create namespace "$NAMESPACE"

            # 如果启用 Istio，给命名空间添加 label
            if [[ "$ISTIO_ENABLED" == "true" ]]; then
                kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite
                echo "✅ 已为命名空间启用 Istio 注入"
            fi
        else
            echo "✅ 命名空间已存在"
        fi
    fi
}

# 创建证书 ConfigMap
create_cert_configmap() {
    echo "📜 创建证书 ConfigMap..."

    if [[ -d "certs/ssl" ]] && [[ -n "$(ls -A certs/ssl)" ]]; then
        kubectl create configmap cert-monitor-certs \
            --from-file=certs/ssl/ \
            --namespace="$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "✅ 证书 ConfigMap 创建完成"
    else
        echo "⚠️  certs/ssl 目录为空或不存在，跳过 ConfigMap 创建"
    fi
}

# 构建镜像（如果需要）
build_image() {
    if [[ -f "Dockerfile" ]] && docker info &> /dev/null; then
        echo "🏗️  构建 Docker 镜像..."

        IMAGE_TAG="${RELEASE_NAME}:$(date +%Y%m%d-%H%M%S)"
        docker build -t "$IMAGE_TAG" .

        echo "✅ 镜像构建完成: $IMAGE_TAG"

        # 如果有镜像仓库，推送镜像
        if [[ -n "$IMAGE_REGISTRY" ]]; then
            docker tag "$IMAGE_TAG" "$IMAGE_REGISTRY/$IMAGE_TAG"
            docker push "$IMAGE_REGISTRY/$IMAGE_TAG"
            echo "✅ 镜像推送完成: $IMAGE_REGISTRY/$IMAGE_TAG"
        fi
    fi
}

# 生成 values 文件
generate_values() {
    local values_content=""

    # 基础配置
    values_content+="image:
  repository: cert-monitor
  tag: latest
  pullPolicy: IfNotPresent

"

    # Istio 配置
    if [[ "$ISTIO_ENABLED" == "true" ]]; then
        values_content+="istio:
  enabled: true
  gateway:
    enabled: true
    hosts:
      - cert-monitor.local
  virtualService:
    enabled: true

"
    else
        values_content+="istio:
  enabled: false

"
    fi

    # 证书配置
    values_content+="certificates:
  local:
    enabled: true
    storage:
      configMap:
        enabled: true
        name: cert-monitor-certs

"

    # 监控配置
    values_content+="monitoring:
  serviceMonitor:
    enabled: true
  prometheusRule:
    enabled: true

"

    echo "$values_content" > /tmp/generated-values.yaml
    echo "✅ 生成临时 values 文件: /tmp/generated-values.yaml"
}

# 部署应用
deploy_app() {
    echo "🚀 部署应用..."

    local helm_cmd="helm"
    local helm_args=()

    if [[ "$DRY_RUN" == "true" ]]; then
        helm_args+=("--dry-run" "--debug")
        echo "🔍 干跑模式，将显示生成的 manifests"
    fi

    helm_args+=("upgrade" "--install" "$RELEASE_NAME" "$CHART_PATH")
    helm_args+=("--namespace" "$NAMESPACE")

    # 添加 values 文件
    if [[ -n "$VALUES_FILE" ]]; then
        helm_args+=("--values" "$VALUES_FILE")
    else
        helm_args+=("--values" "/tmp/generated-values.yaml")
    fi

    # 执行部署
    "$helm_cmd" "${helm_args[@]}"

    if [[ "$DRY_RUN" == "false" ]]; then
        echo "✅ 应用部署完成"
    fi
}

# 验证部署
verify_deployment() {
    if [[ "$DRY_RUN" == "false" ]]; then
        echo "🔍 验证部署..."

        # 等待 Pod 就绪
        kubectl wait --for=condition=ready pod \
            -l app.kubernetes.io/name=cert-monitor \
            -n "$NAMESPACE" \
            --timeout=300s

        # 检查服务状态
        kubectl get pods,svc -n "$NAMESPACE" -l app.kubernetes.io/name=cert-monitor

        echo "✅ 部署验证完成"
    fi
}

# 显示访问信息
show_access_info() {
    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        echo "🎉 部署完成！"
        echo ""
        echo "📊 访问监控指标:"
        echo "  kubectl port-forward svc/$RELEASE_NAME 9393:9393 -n $NAMESPACE"
        echo "  curl http://localhost:9393/metrics"
        echo ""

        if [[ "$ISTIO_ENABLED" == "true" ]]; then
            echo "🌐 通过 Istio Gateway 访问:"
            echo "  需要配置 DNS 将 cert-monitor.local 指向 Istio Ingress Gateway IP"
            echo "  获取 Gateway IP: kubectl get svc istio-ingressgateway -n istio-system"
            echo ""
        fi

        echo "📝 查看日志:"
        echo "  kubectl logs -f deployment/$RELEASE_NAME -n $NAMESPACE"
        echo ""
        echo "🗑️  卸载命令:"
        echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
    fi
}

# 主流程
main() {
    check_tools
    check_k8s
    check_istio
    create_namespace
    create_cert_configmap
    generate_values
    deploy_app
    verify_deployment
    show_access_info
}

# 执行主流程
main