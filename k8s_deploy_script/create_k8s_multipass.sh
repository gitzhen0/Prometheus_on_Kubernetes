set -euo pipefail

N_WORKERS="${1:-2}"             # 工作节点数量，默认 2
UBUNTU_VER="24.04"
CP_NAME="cp"
WORKER_PREFIX="worker"
CPUS="2"
MEM="4G"
DISK="20G"
POD_CIDR="10.244.0.0/16"        # Flannel 默认网段
CLOUD_INIT_FILE="cloud-init.yaml"
K8S_VERSION="v1.31.11"

if [[ ! -f "${CLOUD_INIT_FILE}" ]]; then
  echo "ERROR: 找不到 ${CLOUD_INIT_FILE}，请确保文件名正确（不要写成 cloud.init.yaml）" >&2
  exit 1
fi

echo "=== 1) 启动控制面节点 ==="
multipass launch "${UBUNTU_VER}" --name "${CP_NAME}" --cpus "${CPUS}" --memory "${MEM}" --disk "${DISK}" --cloud-init "${CLOUD_INIT_FILE}"

echo "=== 2) 启动工作节点（共 ${N_WORKERS} 个） ==="
for i in $(seq 1 "${N_WORKERS}"); do
  multipass launch "${UBUNTU_VER}" --name "${WORKER_PREFIX}${i}" --cpus "${CPUS}" --memory "${MEM}" --disk "${DISK}" --cloud-init "${CLOUD_INIT_FILE}"
done

echo "=== 3) 等待 cloud-init 完成 ==="
multipass exec "${CP_NAME}" -- bash -lc "cloud-init status --wait"
for i in $(seq 1 "${N_WORKERS}"); do
  multipass exec "${WORKER_PREFIX}${i}" -- bash -lc "cloud-init status --wait"
done

echo "=== 4) 读取控制面 IP ==="
CP_IP="$(multipass info ${CP_NAME} | awk '/IPv4/{print $2; exit}')"
echo "Control-plane IP: ${CP_IP}"

echo "=== 5) 二次校验 containerd 配置（确保 sandbox_image=3.10 且 SystemdCgroup=true） ==="
multipass exec "${CP_NAME}" -- bash -lc "sudo sed -i 's#sandbox_image = \".*\"#sandbox_image = \"registry.k8s.io/pause:3.10\"#; s/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && sudo systemctl restart containerd"
for i in $(seq 1 "${N_WORKERS}"); do
  multipass exec "${WORKER_PREFIX}${i}" -- bash -lc "sudo sed -i 's#sandbox_image = \".*\"#sandbox_image = \"registry.k8s.io/pause:3.10\"#; s/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && sudo systemctl restart containerd"
done

echo "=== 6) 预拉镜像（控制面 + 所有 worker） ==="
multipass exec "${CP_NAME}" -- bash -lc "sudo ctr -n k8s.io images pull registry.k8s.io/pause:3.10 || true; sudo kubeadm config images pull --kubernetes-version ${K8S_VERSION} || true"
for i in $(seq 1 "${N_WORKERS}"); do
  multipass exec "${WORKER_PREFIX}${i}" -- bash -lc "sudo ctr -n k8s.io images pull registry.k8s.io/pause:3.10 || true; sudo kubeadm config images pull --kubernetes-version ${K8S_VERSION} || true"
done

echo "=== 7) kubeadm init ==="
multipass exec "${CP_NAME}" -- sudo kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --kubernetes-version "${K8S_VERSION}"

echo "=== 8) 配置 kubectl（cp 节点，~/.kube/config） ==="
multipass exec "${CP_NAME}" -- bash -lc "mkdir -p \$HOME/.kube && sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config && sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"

echo "=== 9) 安装 Flannel CNI（ARM64 兼容） ==="
multipass exec "${CP_NAME}" -- bash -lc "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

echo "=== 10) 生成 join 命令并加入 worker ==="
JOIN_CMD="$(multipass exec "${CP_NAME}" -- sudo kubeadm token create --print-join-command)"
for i in $(seq 1 "${N_WORKERS}"); do
  multipass exec "${WORKER_PREFIX}${i}" -- bash -lc "sudo ${JOIN_CMD}"
done

echo "=== 11) 验证节点状态（可能需等待 20–60 秒 CNI 就绪） ==="
multipass exec "${CP_NAME}" -- bash -lc "kubectl get nodes -o wide; kubectl get pods -n kube-system -o wide"

# echo "=== 12) 示例：部署 Nginx 并以 NodePort 暴露 ==="
# multipass exec "${CP_NAME}" -- bash -lc "kubectl create deployment web --image=nginx || true"
# multipass exec "${CP_NAME}" -- bash -lc "kubectl expose deployment web --port=80 --type=NodePort || true"
# multipass exec "${CP_NAME}" -- bash -lc "kubectl get svc web -o wide"

echo
echo "✅ 集群就绪！访问方式：在 Mac 上打开 http://<任一节点IP>:<NodePort>"
echo "➤ 节点 IP："
multipass list

echo
echo "🛠 常见操作："
echo "  - 在 cp 上查看节点：multipass exec ${CP_NAME} -- kubectl get nodes -o wide"
echo "  - 若本机 kubectl 要直连，可将 admin.conf 拉回："
echo "      multipass exec ${CP_NAME} -- sudo cat /etc/kubernetes/admin.conf > kubeconfig.${CP_NAME}"
echo "      export KUBECONFIG=\$PWD/kubeconfig.${CP_NAME}"