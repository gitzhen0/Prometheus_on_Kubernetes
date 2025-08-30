#!/usr/bin/env bash
set -Eeuo pipefail

# ====================== 配置区（可改） ======================
# Mac 本机的 kubeconfig 路径（默认用当前目录下的 kubeconfig.cp）
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$PWD/kubeconfig.cp}"

# NFS 服务端要部署到哪个 Multipass 节点
NFS_NODE="${NFS_NODE:-worker3}"

# 全部集群节点（给每台装 nfs-common 客户端）
NODES_CSV="${NODES_CSV:-cp,worker1,worker2,worker3}"

# NFS 共享目录
NFS_EXPORT="${NFS_EXPORT:-/data/nfs}"

# Helm 安装的 NFS 动态存储 Provisioner
HELM_RELEASE="${HELM_RELEASE:-nfs-subdir-external-provisioner}"
HELM_CHART="${HELM_CHART:-nfs-subdir-external-provisioner/nfs-subdir-external-provisioner}"
HELM_NAMESPACE="${HELM_NAMESPACE:-kube-system}"

# StorageClass 名称（chart 会创建/使用）
STORAGECLASS_NAME="${STORAGECLASS_NAME:-nfs-client}"
: "${STORAGECLASS_NAME:=nfs-client}"   # 兜底，防止 -u 触发

# ====================== 前置检查 ======================
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ 需要命令：$1"; exit 1; }; }
need multipass
need kubectl
need helm
[ -f "$KUBECONFIG_PATH" ] || { echo "❌ 找不到 kubeconfig：$KUBECONFIG_PATH"; exit 1; }

# 解析节点数组
IFS=',' read -r -a ALL_NODES <<< "$NODES_CSV"

# 小工具：取某个 VM 的 IP（第一块网卡）
vm_ip() {
  local node="$1"
  multipass exec "$node" -- bash -lc "hostname -I | awk '{print \$1}'"
}

# 显示大段分隔
bar() { echo "────────────────────────────────────────────────────────────────────────"; }

# ====================== 1) 在 $NFS_NODE 上配置 NFS 服务端 ======================
bar
echo "1) 在 $NFS_NODE 上配置 NFS 服务端"

echo "• 关闭防火墙（若无 ufw 会忽略）"
multipass exec "$NFS_NODE" -- bash -lc 'sudo ufw disable || true'

echo "• 安装 nfs-kernel-server / nfs-common / rpcbind"
multipass exec "$NFS_NODE" -- bash -lc 'sudo apt-get update && sudo apt-get install -y nfs-kernel-server nfs-common rpcbind'

echo "• 创建导出目录 ${NFS_EXPORT}"
multipass exec "$NFS_NODE" -- bash -lc "sudo mkdir -p '${NFS_EXPORT}' && sudo chmod 755 '${NFS_EXPORT}'"

echo "• 写入 /etc/exports"
multipass exec "$NFS_NODE" -- bash -lc "echo '${NFS_EXPORT} *(rw,sync,no_root_squash)' | sudo tee /etc/exports >/dev/null"

echo "• 启动/开机自启 nfs 服务"
multipass exec "$NFS_NODE" -- bash -lc 'sudo systemctl enable --now nfs-kernel-server rpcbind'

echo "• 刷新倒出表"
multipass exec "$NFS_NODE" -- bash -lc 'sudo exportfs -ra'

echo "• 验证 NFS 导出"
multipass exec "$NFS_NODE" -- bash -lc 'rpcinfo -p | grep nfs || true'
multipass exec "$NFS_NODE" -- bash -lc 'sudo exportfs -v'

NFS_IP="$(vm_ip "$NFS_NODE")"
echo "✅ NFS 服务端：${NFS_NODE}  /  IP: ${NFS_IP}  /  导出目录：${NFS_EXPORT}"

# ====================== 2) 给所有节点安装 nfs-common 客户端 ======================
bar
echo "2) 在所有节点安装 nfs-common（客户端）: ${ALL_NODES[*]}"
for node in "${ALL_NODES[@]}"; do
  echo "• $node 安装 nfs-common"
  multipass exec "$node" -- bash -lc 'sudo apt-get update && sudo apt-get install -y nfs-common'
done
echo "✅ nfs-common 客户端准备完成"

# ====================== 3) 用 Mac 上的 Helm 部署 Provisioner ======================
bar
echo "3) 用 Mac 上的 Helm 部署 nfs-subdir-external-provisioner（命名空间：${HELM_NAMESPACE}）"
echo "• 添加/更新 Helm 仓库"
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "• 安装/升级 Helm Release：${HELM_RELEASE}"
helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
  --set nfs.server="${NFS_IP}" \
  --set nfs.path="${NFS_EXPORT}" \
  --set storageClass.name="${STORAGECLASS_NAME}" \
  --set storageClass.defaultClass=true \
  -n "${HELM_NAMESPACE}" --create-namespace \
  --kubeconfig "${KUBECONFIG_PATH}"

# ====================== 4) 验证结果 ======================
bar
echo "4) 验证部署结果"

echo "• 查看 Helm releases"
helm -n "${HELM_NAMESPACE}" list --kubeconfig "${KUBECONFIG_PATH}"

echo "• 查看 Pod（Provisioner）"
kubectl --kubeconfig "${KUBECONFIG_PATH}" -n "${HELM_NAMESPACE}" get pods -l app=nfs-subdir-external-provisioner

echo "• 查看 StorageClass"
kubectl --kubeconfig "${KUBECONFIG_PATH}" get sc

# 检查默认 StorageClass
IS_DEFAULT="$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get sc "${STORAGECLASS_NAME}" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || echo "")"
if [[ "${IS_DEFAULT}" != "true" ]]; then
  echo "⚠️  当前默认 StorageClass 不是 ${STORAGECLASS_NAME}，尝试设置为默认..."
  kubectl --kubeconfig "${KUBECONFIG_PATH}" patch sc "${STORAGECLASS_NAME}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
  echo "• 重新检查："
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get sc
fi

bar
echo "✅ 全部完成！"
echo "   - NFS 服务器：${NFS_IP}:${NFS_EXPORT}"
echo "   - StorageClass：${STORAGECLASS_NAME}（已尝试设为默认）"
echo "   - 如需测试动态存储：创建一个使用 storageClassName=${STORAGECLASS_NAME} 的 PVC 即可。"