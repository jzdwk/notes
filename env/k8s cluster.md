# 规划
 master 192.168.182.134
    环境  2 CPU以上; docker 18.09.0-3.el7 注意, 最新的19版不支持; k8s v1.16.3;
 work 1 192.168.182.135
 work 2 192.168.182.136
参考 ：https://segmentfault.com/a/1190000020738509?utm_source=tag-newest
# Master CentOS 7 134
## 环境准备
* 关闭防火墙
    systemctl disable firewalld
    systemctl stop firewalld
* 关闭selinux
 1.临时禁用selinux
    setenforce 0
 2. 永久关闭 修改/etc/sysconfig/selinux文件设置
    sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
* 关闭swap
   1. swapoff -a
   2.永久禁用，打开/etc/fstab注释掉swap那一行。
     sed -i 's/.*swap.*/#&/' /etc/fstab
* 修改 /etc/hosts  添加192.168.182.13X->master、node
* 修改内核参数 
   /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-ip6tables = 1
   net.bridge.bridge-nf-call-iptables = 1
   生效 sysctl --system
## 软件安装
* network config 
1. 将ip配置为192.168.182.134
     `cd /etc/sysconfig/network-scripts/`
     `vi ifcfg-ens33`
     配置方式请见 https://www.cnblogs.com/yanfly/p/10348103.html
     配置后 `systemctl restart NetworkManager   systemctl restart network`
* yum config
     配置阿里yum源，请查看指定OS的`帮助`：https://opsx.alibaba.com/mirror
* docker config
  see #3 
* 安装kube ctl  
  see https://www.kubernetes.org.cn/installkubectl
* 安装 kubeadm kubelet  see https://www.kubernetes.org.cn/4256.html
1. 配置k8s的源
  `/etc/yum.repos.d/kubernetes.repo`
   `[kubernetes]
    name=Kubernetes
    baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
    enabled=1
    gpgcheck=1
    repo_gpgcheck=1
    gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg 
    https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg` 
2. 安装 kubelet kubeadm  
    setenforce 0
    yum install -y kubelet kubeadm
    systemctl enable kubelet && systemctl start kubelet
3. 至此，节点的准备工作完毕，可将此虚拟机复制copy N份作为work的环境
## 使用kubeadm 创建 master 
* 选择安装过kubeadm的机器 执行
  kubeadm init  该命令首先会下载k8s的组件，如apiserver/etcd等等
  由于墙，访问不了国外repo，所以从阿里云下载镜像，首先，参考: https://segmentfault.com/a/1190000020738509?utm_source=tag-newest
1. 确认版本信息
  ` kubeadm config images list`
2. 编写脚本，注意将脚本的版本内容替换为本机实际值：
   `
    #!/bin/bash
  set -e

  KUBE_VERSION=v1.16.0
  KUBE_PAUSE_VERSION=3.1
  ETCD_VERSION=3.3.15-0
  CORE_DNS_VERSION=1.6.2

  GCR_URL=k8s.gcr.io
  ALIYUN_URL=registry.cn-hangzhou.aliyuncs.com/google_containers

  images=(kube-proxy:${KUBE_VERSION}
  kube-scheduler:${KUBE_VERSION}
  kube-controller-manager:${KUBE_VERSION}
  kube-apiserver:${KUBE_VERSION}
  pause:${KUBE_PAUSE_VERSION}
  etcd:${ETCD_VERSION}
  coredns:${CORE_DNS_VERSION})

  for imageName in ${images[@]} ; do
    docker pull $ALIYUN_URL/$imageName
    docker tag  $ALIYUN_URL/$imageName $GCR_URL/$imageName
    docker rmi $ALIYUN_URL/$imageName
  done
  3. 运行 sh ./kubeadm.sh
* 执行kubeadm
1. sudo kubeadm init \
 --apiserver-advertise-address 192.168.182.134 \
 --kubernetes-version=v1.16.3 \
 --pod-network-cidr=10.244.0.0/16
  该命令需要注意： 
    1. pod-network-cidr指的是pod的网络域
    2. docker的驱动模式改为systemd
        解决 在/etc/docker下创建daemon.json并编辑：
        mkdir /etc/docker/daemon.json
        加入以下内容：
       {"exec-opts":["native.cgroupdriver=systemd"]}
    3. cpu 2个以上 
    4. 内核环境配置，见`环境配置`
* 当出现 kubeadm join XXXX 以及token 时，说明配置成功。
    1. 如果是要安装多个master节点，则初始化命令使用
     kubeadm init --apiserver-advertise-address 192.168.182.134 --control-plane-endpoint 
     192.168.182.134 --kubernetes-version=v1.16.3 --pod-network-cidr=10.244.0.0/16 --upload-certs
    2. 添加master节点使用命令:
     kubeadm join 192.168.182.134:6443 --token z34zii.ur84appk8h9r3yik --discovery-token-ca-cert-hash sha256:dae426820f2c6073763a3697abeb14d8418c9268288e37b8fc25674153702801 --control- 
     plane --certificate-key 1b9b0f1fdc0959a9decef7d812a2f606faf69ca44ca24d2e557b3ea81f415afe
* 将kube相关文件粘贴至home下
   mkdir -p $HOME/.kube;
   cp -i /etc/kubernetes/admin.conf $HOME/.kube/config;
   chown $(id -u):$(id -g) $HOME/.kube/config
* 重复获取token的join命令为 kubeadm token create --print-join-command
* 执行kubectl get pods等命令，如果提示命令拒绝，将配置文件添加至环境变量
   echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bash_profile
# 安装pod 网络（fanneld）
* 获取fanneld的yaml文件 wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
* 拉取镜像脚本,被墙，所以只能脚本
 `#!/bin/bash
set -e
FLANNEL_VERSION=v0.11.0
QUAY_URL=quay.io/coreos
QINIU_URL=quay-mirror.qiniu.com/coreos
images=(flannel:${FLANNEL_VERSION}-amd64
flannel:${FLANNEL_VERSION}-arm64
flannel:${FLANNEL_VERSION}-arm
flannel:${FLANNEL_VERSION}-ppc64le
flannel:${FLANNEL_VERSION}-s390x)
for imageName in ${images[@]} ; do
  docker pull $QINIU_URL/$imageName
  docker tag  $QINIU_URL/$imageName $QUAY_URL/$imageName
  docker rmi $QINIU_URL/$imageName
done`
* 运行脚本，该脚本需要在每个node上运行 
* 安装flanneld kubectl apply -f kube-flanneld.yaml 
* 当work节点加入后，查看node状态，若一直notready，查看pod状态：
  kubectl -n kube-system get pods    
  出现的问题包括：
  1.  两个工作节点不能拉取pause和kube-proxy镜像
  首先在master上打包镜像
  docker save -o pause.tar k8s.gcr.io/pause:3.1
  docker save -o kube-proxy.tar k8s.gcr.io/kube-proxy
  上传到work node后 使用docker load
  docker load -i pause.tar 
  docker load -i kube-proxy.tar
  并重新安装
  kubectl delete -f kube-flannel.yml 
  kubectl create -f kube-flannel.yml

 2. 使用kubectl describe查看notready节点信息，出现cni config uninitialized 时，
   cat << EOF > /var/lib/kubelet/kubeadm-flags.env
   KUBELET_KUBEADM_ARGS="--cgroup-driver=systemd --pod-infra-container- 
   image=k8s.gcr.io/pause:3.1"
   EOF
   删除`--network-plugin=cni`
   systemctl restart kubelet

# Work CentOS 7
   工作节点 需要以下安装 kubeadm kubelet flanneld docker
## 安装kubectl kubelet kubeadm 与master相同 
## 配置环境，涉及selinux/内核等，与master相同
## node加入
    执行命令kubeadm join 192.168.182.134:6443 --token lixsl8.v1auqmf91ty0xl0k \
    --discovery-token-ca-cert-hash 
    sha256:c3f92a6ed9149ead327342f48a545e7e127a455d5b338129feac85893d918a55 \
   --ignore-preflight-errors=all 
   1. docker的驱动模式改为systemd
        解决 在/etc/docker下创建daemon.json并编辑：
        mkdir /etc/docker/daemon.json
        加入以下内容：
       {"exec-opts":["native.cgroupdriver=systemd"]}
   2. 提示加入成功后，查看master的node状态 kubectl get nodes

# 其他说明
* master和work都可以使用kubeadm reset重置，work节点的退出同样使用该命令
* work节点上/下线：
   1. work节点使用kubeadm reset 清空配置
   2. 在master节点使用 kubectl delete nodes <nodename>
   3. 重新上线 使用kubeadm join
* master节点上下线
  1. kubectl 删除所有work node 
  2. master 使用kubeadm reset重置，注意此时并没有重置 ~/.kube/config的描述
  3. 重新上线，使用kubeadm init 后， 将worknode加入，需要重新启用flaneld，kubectl delete -f kube-fanneld.yml / kubectl create -f kube-finneld.yml 