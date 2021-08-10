# 规划
- 使用**kubeadm**安装k8s v1.20
- 环境 2CPU以上; docker18.09.0-3.el7
- master134： 192.168.182.134
- node135 192.168.182.135
- node136 192.168.182.136

参考 ：https://segmentfault.com/a/1190000020738509?utm_source=tag-newest


# 环境准备

如无特殊说明，需要在**各节点**执行。

## network配置 

将ip配置为192.168.182.134
```bash    
	cd /etc/sysconfig/network-scripts/ 
    vi ifcfg-ens33 #视具体网卡名称而定
```
比如配置详情：
```bash
[root@master network-scripts]# cat ifcfg-ens33 
TYPE=Ethernet
PROXY_METHOD=none
BROWSER_ONLY=no
BOOTPROTO=static
DEFROUTE=yes
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_FAILURE_FATAL=no
IPV6_ADDR_GEN_MODE=stable-privacy
NAME=ens33
UUID=a1b4c1c1-a0b5-4d98-a5d1-aae03a0516a5
DEVICE=ens33
ONBOOT=yes
IPADDR=192.168.182.134   #静态IP
NETMASK=255.255.255.0	
GATEWAY=192.168.182.2
DNS1=192.168.182.2
DEVICE=ens33
NAME=ens33
```
配置后
```bash
	systemctl restart NetworkManager
	service network restart	
```

## 配置yum源

使用阿里yum源，请查看指定OS的`帮助`：https://opsx.alibaba.com/mirror
	 
## 安装docker，不再赘述

## 关闭防火墙

```bash
	systemctl disable firewalld
	systemctl stop firewalld
```
原因为，master与node间有大量通信。
更安全的做法是在防火墙上配置各个组件互通的端口号。
这里选择关闭即省事。

## 关闭selinux
 
- 临时禁用selinux:`setenforce 0`
 
- 永久关闭 修改/etc/sysconfig/selinux文件设置:

```bash
    sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
```

关闭的原因为，容器需要读取主机文件系统（比如容器网络的pod）。

## 关闭swap

- `swapoff -a`

-  永久禁用 打开`/etc/fstab`注释掉swap那一行
```bash
	sed -i 's/.*swap.*/#&/' /etc/fstab
```   
关闭的原因为，k8s在调度pod时需要评估node的内存，swap增加了此项工作的复杂度，同时影响了性能。
  
## 设置主机名

``` bash
hostnamectl set-hostname master134 # 将 master134 替换为当前主机名
```
同理，在`135`和`136`上设置hostname

在每台机器的 `/etc/hosts` 文件中添加主机名和 IP 的对应关系：

``` bash
cat >> /etc/hosts <<EOF
192.168.182.134 master134
192.168.182.135 node135
192.168.182.136 node136
EOF
```

## 添加节点信任

只需要在**master134 节点上执行**，设置 root 账户可以无密码登录**所有节点**：
``` bash
ssh-keygen -t rsa 
ssh-copy-id root@master134
ssh-copy-id root@node135
ssh-copy-id root@node136
```
`ssh-copy-id`命令用于将本地主机的公钥复制到远程主机的authorized_keys文件上，ssh-copy-id命令也会给远程主机的用户主目录（home）和~/.ssh, 和~/.ssh/authorized_keys设置合适的权限。


## 优化内核参数 

``` bash
cat > k8s.conf <<EOF
# 设置二层的网桥在转发包被iptables的FORWARD规则所过滤
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
# 开启IP转发，使宿主机机像路由器一样将数据从一个网络发送到另一个网络
net.ipv4.ip_forward=1
net.ipv4.tcp_tw_recycle=0

net.ipv4.neigh.default.gc_thresh1=1024
net.ipv4.neigh.default.gc_thresh1=2048
net.ipv4.neigh.default.gc_thresh1=4096

vm.swappiness=0
vm.overcommit_memory=1
vm.panic_on_oom=0

fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
fs.file-max=52706963
fs.nr_open=52706963

net.ipv6.conf.all.disable_ipv6=1
net.netfilter.nf_conntrack_max=2310720
EOF
cp k8s.conf  /etc/sysctl.d/k8s.conf
sysctl -p /etc/sysctl.d/k8s.conf
```

## 设置时间

设置时区
``` bash
timedatectl set-timezone Asia/Shanghai
```
设置系统时钟同步
``` bash
systemctl enable chronyd
systemctl start chronyd
```
查看同步状态：
``` bash
timedatectl status
```

输出：
``` text
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```
`System clock synchronized: yes`，表示时钟已同步；
`NTP service: active`，表示开启了时钟同步服务；

``` bash
# 将当前的 UTC 时间写入硬件时钟
timedatectl set-local-rtc 0

# 重启依赖于系统时间的服务
systemctl restart rsyslog 
systemctl restart crond
```
## 关闭无关的服务

``` bash
systemctl stop postfix && systemctl disable postfix
```

## 升级内核

CentOS 7.x 系统自带的 3.10.x 内核存在一些 Bugs，导致运行的 Docker、Kubernetes 不稳定，例如：
- 高版本的 docker(1.13 以后) 启用了 3.10 kernel 实验支持的 kernel memory account 功能(无法关闭)，当节点压力大如频繁启动和停止容器时会导致 cgroup memory leak；
- 网络设备引用计数泄漏，会导致类似于报错："kernel:unregister_netdevice: waiting for eth0 to become free. Usage count = 1";

``` bash
rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
# 安装完成后检查 /boot/grub2/grub.cfg 中对应内核 menuentry 中是否包含 initrd16 配置，如果没有，再安装一次！
yum --enablerepo=elrepo-kernel install -y kernel-lt
# 设置开机从新内核启动
grub2-set-default 0
```

重启机器：

``` bash
sync
reboot
```

# master134配置
  
## 安装kubectl kubeadm kubelet

配置k8s的源，这里使用aliyun的替换官方的google
```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
gpgcheck=1
enabled=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
```
安装指定版本v1.20
```
yum install -y kubelet-1.20.0 kubeadm-1.20.0 kubectl-1.20.0 --disableexcludes=kubernetes
```
- 将`/usr/bin/kubectl`拷贝到`/usr/local/bin/kubectl`

## kubeadm init

选择安装过kubeadm的机器 执行`kubeadm init`

该命令首先会下载k8s的组件，如apiserver/etcd等等
由于墙，访问不了国外repo，所以从阿里云下载镜像，首先，参考: https://segmentfault.com/a/1190000020738509?utm_source=tag-newest

- 确认版本信息`kubeadm config images list`
```bash
[root@master134 yum.repos.d]# kubeadm config images list
I0605 11:03:59.755418    3401 version.go:251] remote version is much newer: v1.21.1; falling back to: stable-1.20
k8s.gcr.io/kube-apiserver:v1.20.7
k8s.gcr.io/kube-controller-manager:v1.20.7
k8s.gcr.io/kube-scheduler:v1.20.7
k8s.gcr.io/kube-proxy:v1.20.7
k8s.gcr.io/pause:3.2
k8s.gcr.io/etcd:3.4.13-0
k8s.gcr.io/coredns:1.7.0
```
- 编写脚本，注意将脚本的版本内容替换为**上条命令返回的版本信息**：
```bash
  #!/bin/bash
  # 脚本的目的为从aliyun上pull镜像，tag为官方镜像
  set -e

  KUBE_VERSION=v1.20.7
  KUBE_PAUSE_VERSION=3.2
  ETCD_VERSION=3.4.13-0
  CORE_DNS_VERSION=1.7.0

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
```
运行`sh k8s_image.sh`.
node也需要上述镜像，所以：
```bash
[root@master134 install]# scp k8s_images.sh root@node135:/root/k8sdemo/
k8s_images.sh                                                                             100%  579   198.2KB/s   00:00    
[root@master134 install]# scp k8s_images.sh root@node136:/root/k8sdemo/
k8s_images.sh                                                                             100%  579   272.9KB/s   00:00    
[root@master134 install]# 
```

- 执行kubeadm:

```bash
 sudo kubeadm init \
 --apiserver-advertise-address 192.168.182.134 \
 --kubernetes-version=v1.20.7 \
 --pod-network-cidr=10.244.0.0/16
```

该命令需要注意： 
- **pod-network-cidr**指的是pod的网络域
- docker的驱动模式要改为**systemd**，在`/etc/docker`下创建`daemon.json`并加入以下内容：
```json
{
    //other configs
	"xxxx":"xxxx",
	"exec-opts":["native.cgroupdriver=systemd"]
}
```
当出现以下输出，说明配置成功:
```bash
Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.182.134:6443 --token u68djx.q40ejbwsrsct8g0w \
    --discovery-token-ca-cert-hash sha256:17ddf76718a5249b3407c39e95c02887684c8f16a682efa0dd0816f18293acab
```

- 要使**非root用户**可以运行**kubectl**，执行：
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

# node节点加入

首先执行`/root/k8sdemo/k8s_image.sh`，下载镜像。

根据上面`kubeadm join`的输出，添加work节点使用命令:
```
kubeadm join 192.168.182.134:6443 --token u68djx.q40ejbwsrsct8g0w \
    --discovery-token-ca-cert-hash sha256:17ddf76718a5249b3407c39e95c02887684c8f16a682efa0dd0816f18293acab
```

- 重复获取token的join命令为 `kubeadm token create --print-join-command`

- 执行kubectl get pods等命令，如果提示命令拒绝，将配置文件添加至环境变量
```bash   
   echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bash_profile
```
   
# 安装pod网络

## calico(推荐)

https://docs.projectcalico.org/getting-started/kubernetes/quickstart

```bash
#1
kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
#2
kubectl create -f https://docs.projectcalico.org/manifests/custom-resources.yaml
```

## fanneld

- 获取fanneld的yaml文件 
```bash
wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```
- 拉取镜像脚本,被墙，所以只能脚本
```bash
#!/bin/bash
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
done
```
- 运行脚本，该脚本需要在每个node上运行 
- 安装flanneld kubectl apply -f kube-flanneld.yaml 
- 当work节点加入后，查看node状态，若一直notready，查看pod状态：`kubectl -n kube-system get pods`    
- 出现的问题包括：
  
1.  两个工作节点不能拉取pause和kube-proxy镜像,首先在master上打包镜像
```
docker save -o pause.tar k8s.gcr.io/pause:3.1
docker save -o kube-proxy.tar k8s.gcr.io/kube-proxy
```
上传到work node后 使用docker load
```
docker load -i pause.tar 
docker load -i kube-proxy.tar
```
并重新安装
```
kubectl delete -f kube-flannel.yml 
kubectl create -f kube-flannel.yml
```
2. 使用kubectl describe查看notready节点信息，出现cni config uninitialized 时，
```
cat << EOF > /var/lib/kubelet/kubeadm-flags.env
KUBELET_KUBEADM_ARGS="--cgroup-driver=systemd --pod-infra-container- 
image=k8s.gcr.io/pause:3.1"
EOF
删除`--network-plugin=cni`
systemctl restart kubelet
```
## weave

- 获取yaml文件
```bash
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version|base64|tr -d `\n`)" 
```
- 注意

因codedns组件会被调度到node上，所以确保node上存在`k8s.gcr.io/coredns:{version}`

# 重启集群

master和work都可以使用`kubeadm reset`重置，work节点的退出同样使用该命令

- work节点上/下线：
1. work节点使用`kubeadm reset`清空配置
2. 在master节点使用 kubectl delete nodes <nodename>
3. 重新上线 使用`kubeadm join`

- master节点上下线
1. kubectl删除所有work node 
2. master使用`kubeadm reset`重置，注意此时并没有重置 ~/.kube/config的描述
3. 重新上线，使用`kubeadm init`后，将work node加入，需要重新部署网络插件

# 删除集群

1. 卸载服务:`kubeadm reset`

2. 删除组件
```bash
yum remove kubelet kubeadm kubectl -y
```
3. 删除容器及镜像
```bash
docker images -qa|xargs docker rmi -f
```