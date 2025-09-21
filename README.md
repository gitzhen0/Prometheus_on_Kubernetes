# Prometheus_on_Kubernetes
---
## Intro
### Project Description
* **Deploy Prometheus on Kubernetes and Monitoring services**
    * (not using Operator)
* **Monitoring** (Pulling Metrics From)
    * Kubernetes services
        * coredns
        * kube-apiserver
        * kube-controller-manager
        * kube-scheduler
        * etcd
    * K8s Nodes by node exporter
    * K8s Pods by Cadvisor
    * K8s Services by Service Discovery
    * K8s resources info by kube-state-metrics
* **Other Features**
    * **Silence**
	    * Needs to setup at Alertmanager webpage
    * **Inhibition**
	    * Simple rule for demonstration is ready
    * **Email Alerts in Template** 
    * **Dingding Webhook Message in Template**
---
### Environment
* Macbook Air m4 (arm)
    * Helm 
        * v3.18.6 
    * Multipass
        * v1.15.1+mac
* Kubernetes on Multipass Ubuntu 24.04 LTS
    * v1.31.11   
    * 1 control-plane node
    * 3 worker nodes
* Prometheus
    * v2.53.0 
* Grafana
    * v12.1.1
* Alertmanager
    * v0.28.0
---
### Notes
1. **Prometheus Persistent Volume**
    * PV is fixed on worker2 node, 
    * feel free to bind to other nodes (master node not tested yet)
2. **kube-state-metrics**
    * Code from git clone and removed extraneous files
    * with tiny modifications  
3. **HTTPS `/metrics` endpoints**
    * The endpoints on Prometheus webpage with start with `https` won't be accessible
    * because local browser don't have the certs
    * but the data can be queried in `Graph` page
        * because prometheus got the data in its server 
```sh
git clone https://github.com/kubernetes/kube-state-metrics.git
cd kube-state-metrics/examples/standard
```
4. **NodePort Selection** 
    * NodePort is hardcoded for convenience
	* Prometheus → **31090**
		* Corresponds to its original **9090** Port 
	* Alertmanager → **31093**
		* Corresponds to its original **9093** Port 
	* Grafana → **31300**
		* Corresponds to its original **3000** Port 
5. **Node Assignment**
	* **cp**
	    * Just control-plane
	* **worker1**
	    * stress-ng Stressing Test
	* **worker2**
	    * Prometheus PV
	* **worker3**
	    * Grafana's StorageClass on NFS 
---
## Project Setup Instruction
### 1. Preparation
1. Install Multipass on Mac(arm)
    * https://canonical.com/multipass/install
2. Install Mac brew packages
```sh
brew install gettext && brew link --force gettext # install envsubst (a command in gettext)
brew install helm
```
3. (Optional) - For Alertmanager's Functions Only
    * If you want Alertmanager to send email alerts ✅
        * Needs to provide a sender Email's POP3/SMTP CODE to Alertmanager
        * Sender email needs POP3/IMAP/SMTP setup 
        * Assuming you are using QQ Email for this project
            * Otherwise, you'll have to tweak a bit in `alertmanager/alertmanager-config.tmpl`
                * default: `global.smtp_smarthost:'smtp.qq.com:587'`
        * **Detailed Operation Process Omitted -> Google it~**
            * If you eventually got a email auth code (16-letter string), you'll be all good!
            * Put the in your own `.env` file, field name: `EMAIL_AUTH_CODE`
    * If you want Alertmanager to send DingDing message alerts ✅ 
		1. Needs 2 Phone Number (at least one Chinese mobile number) for 2 DingTalk account, and create a group for them
		2. Setup a Webhook Robot for the group
		* **Detailed Operation Process Omitted -> Google it~**
			* Will eventually get a **Signature Secret** and a **URL**
			* Put in `.env` file
---
### 2. Kubernetes Environment Setup
1. Script is Ready, just run it
```bash
cd ./k8s_deploy_script            
bash create_k8s_multipass.sh 3    # 1 control-plane + 3 worker
```
2. Pull kubeconfig from control-plane
    * Inorder to use `kubectl` in your local terminal
    * **Whenever you can't connect to K8s cluster, just do this**
```sh
cd $(git rev-parse --show-toplevel)
multipass exec cp -- sudo cat /etc/kubernetes/admin.conf > kubeconfig.cp
export KUBECONFIG=$PWD/kubeconfig.cp
```
3. Check Connection
```bash
kubectl get nodes -o wide
```
---
### 3. Deploy Prometheus on Kubernetes
1. Grant script authorization
```sh
chmod +x deploy_project.sh
```
2. Run the deploy script (idempotent)
```sh
./deploy_project.sh
```
* Will generate a `.env` file in project root directory 
    * for you to put in variables for alertmanager to work
    * (after put in variables just rerun the deploy script)
---
### 4. Verify
* Prometheus
	* `http://<Whichever_Nodes_IP>:31090`
* Alertmanager
	* `http://<Whichever_Nodes_IP>:31093`
* Grafana
	* `http://<Whichever_Nodes_IP>:31300`
	* User/Pass: admin / admin321
---
## Project Feature Demonstration
### Prometheus Features
* Go to `http://<Whichever_Nodes_IP>:31090` 
    * Web page nav bar -> `Status` -> `Targets`
    * See all the monitored resources
---
### Alertmanager Features
#### Alerts Definition
* See `prometheus/prometheus-configmap.yaml`
#### Trigger Alerts
* Use this command to trigger alerts
	* Can be used in whichever node
```sh
stress-ng --vm 2 --vm-bytes 2G --timeout 600s --metrics-brief
```
* Explanation
	* `--vm 2`
		* Launches 2 memory allocation workers (virtual memory stressors)
	* `--vm-bytes 2G`
		* Allocates 2GB of memory to each worker (total ~4GB)
	* `--timeout 600s`
		* Runs the stress test for 600 seconds
		* (ensuring it exceeds the for: 2m threshold in alert rules)
	* `--metrics-brief`
		* Prints summarized metrics at the end of the test
#### Receive Alert From Email
* Skip
#### Receive Alert From DingTalk
* Skip
#### Inhibition
* Due to Inhibition rules setup inside, only one of two alerts will be sent

#### Silence
* Currently no silence existing
* Can be set up at Alertmanager's webpage
	* `http://<Whichever_Nodes_IP>:31093`
---
### Grafana Features
* Go to `http://<Whichever_Nodes_IP>:31300`
    * User/Pass: admin / admin321
    * Do whatever you like
        * Import Dashboard
        * Create Dashboard
        * etc.
---
## Debugging Commands
```sh
# switch namespace to monitor
kubectl config set-context --current --namespace=monitor

# check used NodePort number
kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[*].nodePort}{"\n"}{end}' | sort -n | uniq

# Into Node Shell
multipass list     # List VMs
multipass exec worker2 -- bash

# Into Pod Shell
kubectl get pods -o wide -n monitor
kubectl exec -it <pod-name> -n monitor -- bash

# After Applied Prometheus's Configmap settings -> Trigger Pod to Refresh Settings
kubectl apply -f prometheus-cm.yaml
kubectl apply -f prometheus-configmap.yaml
# Run this: 
curl -i -X POST http://<Whichever_Nodes_IP>:31090/-/reload

# Check yaml file for a resource
kubectl get deployment alertmanager -n monitor -o yaml

# Monitoring whether the pod updated with the new configmap settings
kubectl -n monitor exec -ti <prometheus-pod-name> -- sh
cat /etc/prometheus/prometheus.yml
# Refresh every 1 sec, will update the terminal when updates in configmap take effect
watch -n 1 cat /etc/prometheus/prometheus.yml


# Delete everything applied by kustomization
kubectl delete -k .

# When shell script not working/needs permission
chmod +x <scriptpath>

# Stressing command
stress-ng --vm 2 --vm-bytes 2G --timeout 600s --metrics-brief
```
---
## TODO
1. Upgrade code quality, Remove deprecated code
2. Deploy a redis on K8s and monitor it
3. Try fix time problem for Silence 
