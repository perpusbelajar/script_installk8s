#!/bin/bash

# Step 1: Disable SELinux
setenforce 0
sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config

# Step 2: Disable Swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Step 3: Install Docker
yum update -y
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce docker-ce-cli containerd.io --allowerasing

# Step 4: Configure Docker daemon
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

systemctl enable docker
systemctl daemon-reload
systemctl restart docker

# Step 5: Install cri-dockerd
wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.1/cri-dockerd-0.3.1.amd64.tgz
tar xvf cri-dockerd-0.3.1.amd64.tgz
mv cri-dockerd/cri-dockerd /usr/local/bin/

# Setup cri-dockerd systemd service
wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service \
     https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
mv cri-docker.socket cri-docker.service /etc/systemd/system/
sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
systemctl daemon-reload
systemctl enable cri-docker.service
systemctl enable --now cri-docker.socket

# Step 6: Add Kubernetes repository
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28.3/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28.3/rpm/repodata/repomd.xml.key
EOF

# Step 7: Install Kubernetes components
yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable kubelet

# Step 8: Initialize Kubernetes cluster
kubeadm init --cri-socket /run/cri-dockerd.sock

# Setup kubeconfig for regular user
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# Step 9: Apply Network Plugin (Calico)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/calico.yaml

# Step 10: Remove master taint to allow scheduling
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Step 11: Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Step 12: Add Elastic Helm repository and install Elasticsearch
kubectl create namespace efk-monitoring
helm repo add elastic https://helm.elastic.co
helm repo update
helm install elasticsearch elastic/elasticsearch --version 7.17.3 -n efk-monitoring --set persistence.enabled=false,replicas=1

# Step 13: Verify installation
kubectl get pods -n efk-monitoring
kubectl get svc -n efk-monitoring
