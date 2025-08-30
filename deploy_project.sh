#!/bin/bash

# 任何命令非 0 状态都会立刻退出
set -e

# === 配置区 ===
NAMESPACE="monitor"
PROMETHEUS_NODE="worker2"
PROM_DIR="/data/k8s/prometheus"
CP_NODE="cp"
WORKER_NODES=("worker1" "worker2" "worker3")  # 所有 worker 节点
ALL_NODES=("$CP_NODE" "${WORKER_NODES[@]}")  # 全部节点

# 是否执行 rollout restart（1=启用，0=跳过）
ROLL_RESTART=1

# === 1. 检查 .env 文件 ===
echo "1️⃣ Checking .env file..."
if [ -f ".env" ]; then
  echo "✅ .env exists, skip creating"
else
  if [ -f ".env.example" ]; then
    cp .env.example .env
    echo "✅ .env created from .env.example"
  else
    echo "❌ Neither .env nor .env.example found, aborting"
    exit 1
  fi
fi

# === 2. 预处理 ===
echo "2️⃣ Preparing variables..."
set -a; source .env; set +a
envsubst < ./alertmanager/alertmanager-config.tmpl > ./alertmanager/alertmanager-config.yaml
envsubst < ./dingding/webhook-config.tmpl > ./dingding/webhook-config.yaml
echo "✅ webhook-config.yaml & alertmanager-config.yaml rendered"

# 拿 kubeconfig 并导出
multipass exec $CP_NODE -- sudo cat /etc/kubernetes/admin.conf > kubeconfig.cp
export KUBECONFIG=$PWD/kubeconfig.cp

# === 3. 所有节点安装 stress-ng ===
echo "3️⃣ Installing stress-ng on all nodes..."
for NODE in "${ALL_NODES[@]}"; do
  echo "   👉 $NODE"
  multipass exec "$NODE" -- bash -c "sudo apt-get update -y && sudo apt-get install -y stress-ng"
done
echo "✅ stress-ng installed on all nodes"

# === 4. Namespace 检查 ===
echo "4️⃣ Checking namespace $NAMESPACE..."
kubectl get ns $NAMESPACE >/dev/null 2>&1 || kubectl create namespace $NAMESPACE

# === 5. Worker 节点目录准备 ===
echo "5️⃣ Creating $PROM_DIR on $PROMETHEUS_NODE..."
multipass exec $PROMETHEUS_NODE -- sudo mkdir -p $PROM_DIR
multipass exec $PROMETHEUS_NODE -- ls -ld $PROM_DIR

# === 6. Control-plane 静态 Pod 配置修改（开放外部访问） ===
echo "6️⃣ Updating static pod manifests on $CP_NODE..."

# 6.1 修改 controller-manager
multipass exec $CP_NODE -- sudo sed -i \
  's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

# 6.2 修改 scheduler
multipass exec $CP_NODE -- sudo sed -i \
  's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# 6.3 修改 etcd
multipass exec $CP_NODE -- sudo sed -i \
  's|--listen-metrics-urls=http://127.0.0.1:2381|--listen-metrics-urls=http://0.0.0.0:2381|' \
  /etc/kubernetes/manifests/etcd.yaml

# === 7. Grafana 部署 ===
echo "7️⃣ Deploying Grafana..."
chmod +x grafana_prep.sh
./grafana_prep.sh

# === 8. 部署 Prometheus & Alertmanager ===
echo "8️⃣ Dry-run check..."
kubectl apply --dry-run=client -k .
echo "✅ Dry-run check passed"

echo "🚀 Applying manifests..."
kubectl apply -k .

# === 9. 刷新资源状态 & 验证 ===
if [ "$ROLL_RESTART" -eq 1 ]; then
  echo "🔄 Restarting Deployments to reload ConfigMaps..."
  kubectl -n $NAMESPACE rollout restart deploy/alertmanager || true
  kubectl -n $NAMESPACE rollout restart deploy/prometheus || true
  kubectl -n $NAMESPACE rollout restart deploy/webhook || true
  echo "✅ Restart triggered"
else
  echo "⏩ Rollout restart skipped (ROLL_RESTART=$ROLL_RESTART)"
fi

echo "9️⃣ Checking resources in $NAMESPACE..."
kubectl -n $NAMESPACE get all
kubectl -n $NAMESPACE get pvc
kubectl -n $NAMESPACE get pv

# === 打印访问地址 ===
echo "🔗 Service Endpoints:"
multipass exec $PROMETHEUS_NODE -- sh -c \
  "IP=\$(hostname -I | awk '{print \$1}');
   echo 'Prometheus:   http://'\$IP':31090';
   echo 'Alertmanager: http://'\$IP':31093';
   echo 'Grafana:      http://'\$IP':31300';
   echo '';
   echo '📊 Grafana login -> admin / admin321'"