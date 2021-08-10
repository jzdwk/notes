# �滮
- ʹ��**kubeadm**��װk8s v1.20
- ���� 2CPU����; docker18.09.0-3.el7
- master134�� 192.168.182.134
- node135 192.168.182.135
- node136 192.168.182.136

�ο� ��https://segmentfault.com/a/1190000020738509?utm_source=tag-newest


# ����׼��

��������˵������Ҫ��**���ڵ�**ִ�С�

## network���� 

��ip����Ϊ192.168.182.134
```bash    
	cd /etc/sysconfig/network-scripts/ 
    vi ifcfg-ens33 #�Ӿ����������ƶ���
```
�����������飺
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
IPADDR=192.168.182.134   #��̬IP
NETMASK=255.255.255.0	
GATEWAY=192.168.182.2
DNS1=192.168.182.2
DEVICE=ens33
NAME=ens33
```
���ú�
```bash
	systemctl restart NetworkManager
	service network restart	
```

## ����yumԴ

ʹ�ð���yumԴ����鿴ָ��OS��`����`��https://opsx.alibaba.com/mirror
	 
## ��װdocker������׸��

## �رշ���ǽ

```bash
	systemctl disable firewalld
	systemctl stop firewalld
```
ԭ��Ϊ��master��node���д���ͨ�š�
����ȫ���������ڷ���ǽ�����ø��������ͨ�Ķ˿ںš�
����ѡ��رռ�ʡ�¡�

## �ر�selinux
 
- ��ʱ����selinux:`setenforce 0`
 
- ���ùر� �޸�/etc/sysconfig/selinux�ļ�����:

```bash
    sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
```

�رյ�ԭ��Ϊ��������Ҫ��ȡ�����ļ�ϵͳ���������������pod����

## �ر�swap

- `swapoff -a`

-  ���ý��� ��`/etc/fstab`ע�͵�swap��һ��
```bash
	sed -i 's/.*swap.*/#&/' /etc/fstab
```   
�رյ�ԭ��Ϊ��k8s�ڵ���podʱ��Ҫ����node���ڴ棬swap�����˴�����ĸ��Ӷȣ�ͬʱӰ�������ܡ�
  
## ����������

``` bash
hostnamectl set-hostname master134 # �� master134 �滻Ϊ��ǰ������
```
ͬ����`135`��`136`������hostname

��ÿ̨������ `/etc/hosts` �ļ�������������� IP �Ķ�Ӧ��ϵ��

``` bash
cat >> /etc/hosts <<EOF
192.168.182.134 master134
192.168.182.135 node135
192.168.182.136 node136
EOF
```

## ��ӽڵ�����

ֻ��Ҫ��**master134 �ڵ���ִ��**������ root �˻������������¼**���нڵ�**��
``` bash
ssh-keygen -t rsa 
ssh-copy-id root@master134
ssh-copy-id root@node135
ssh-copy-id root@node136
```
`ssh-copy-id`�������ڽ����������Ĺ�Կ���Ƶ�Զ��������authorized_keys�ļ��ϣ�ssh-copy-id����Ҳ���Զ���������û���Ŀ¼��home����~/.ssh, ��~/.ssh/authorized_keys���ú��ʵ�Ȩ�ޡ�


## �Ż��ں˲��� 

``` bash
cat > k8s.conf <<EOF
# ���ö����������ת������iptables��FORWARD����������
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
# ����IPת����ʹ����������·����һ�������ݴ�һ�����緢�͵���һ������
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

## ����ʱ��

����ʱ��
``` bash
timedatectl set-timezone Asia/Shanghai
```
����ϵͳʱ��ͬ��
``` bash
systemctl enable chronyd
systemctl start chronyd
```
�鿴ͬ��״̬��
``` bash
timedatectl status
```

�����
``` text
System clock synchronized: yes
              NTP service: active
          RTC in local TZ: no
```
`System clock synchronized: yes`����ʾʱ����ͬ����
`NTP service: active`����ʾ������ʱ��ͬ������

``` bash
# ����ǰ�� UTC ʱ��д��Ӳ��ʱ��
timedatectl set-local-rtc 0

# ����������ϵͳʱ��ķ���
systemctl restart rsyslog 
systemctl restart crond
```
## �ر��޹صķ���

``` bash
systemctl stop postfix && systemctl disable postfix
```

## �����ں�

CentOS 7.x ϵͳ�Դ��� 3.10.x �ں˴���һЩ Bugs���������е� Docker��Kubernetes ���ȶ������磺
- �߰汾�� docker(1.13 �Ժ�) ������ 3.10 kernel ʵ��֧�ֵ� kernel memory account ����(�޷��ر�)�����ڵ�ѹ������Ƶ��������ֹͣ����ʱ�ᵼ�� cgroup memory leak��
- �����豸���ü���й©���ᵼ�������ڱ���"kernel:unregister_netdevice: waiting for eth0 to become free. Usage count = 1";

``` bash
rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
# ��װ��ɺ��� /boot/grub2/grub.cfg �ж�Ӧ�ں� menuentry ���Ƿ���� initrd16 ���ã����û�У��ٰ�װһ�Σ�
yum --enablerepo=elrepo-kernel install -y kernel-lt
# ���ÿ��������ں�����
grub2-set-default 0
```

����������

``` bash
sync
reboot
```

# master134����
  
## ��װkubectl kubeadm kubelet

����k8s��Դ������ʹ��aliyun���滻�ٷ���google
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
��װָ���汾v1.20
```
yum install -y kubelet-1.20.0 kubeadm-1.20.0 kubectl-1.20.0 --disableexcludes=kubernetes
```
- ��`/usr/bin/kubectl`������`/usr/local/bin/kubectl`

## kubeadm init

ѡ��װ��kubeadm�Ļ��� ִ��`kubeadm init`

���������Ȼ�����k8s���������apiserver/etcd�ȵ�
����ǽ�����ʲ��˹���repo�����ԴӰ��������ؾ������ȣ��ο�: https://segmentfault.com/a/1190000020738509?utm_source=tag-newest

- ȷ�ϰ汾��Ϣ`kubeadm config images list`
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
- ��д�ű���ע�⽫�ű��İ汾�����滻Ϊ**��������صİ汾��Ϣ**��
```bash
  #!/bin/bash
  # �ű���Ŀ��Ϊ��aliyun��pull����tagΪ�ٷ�����
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
����`sh k8s_image.sh`.
nodeҲ��Ҫ�����������ԣ�
```bash
[root@master134 install]# scp k8s_images.sh root@node135:/root/k8sdemo/
k8s_images.sh                                                                             100%  579   198.2KB/s   00:00    
[root@master134 install]# scp k8s_images.sh root@node136:/root/k8sdemo/
k8s_images.sh                                                                             100%  579   272.9KB/s   00:00    
[root@master134 install]# 
```

- ִ��kubeadm:

```bash
 sudo kubeadm init \
 --apiserver-advertise-address 192.168.182.134 \
 --kubernetes-version=v1.20.7 \
 --pod-network-cidr=10.244.0.0/16
```

��������Ҫע�⣺ 
- **pod-network-cidr**ָ����pod��������
- docker������ģʽҪ��Ϊ**systemd**����`/etc/docker`�´���`daemon.json`�������������ݣ�
```json
{
    //other configs
	"xxxx":"xxxx",
	"exec-opts":["native.cgroupdriver=systemd"]
}
```
���������������˵�����óɹ�:
```bash
Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.182.134:6443 --token u68djx.q40ejbwsrsct8g0w \
    --discovery-token-ca-cert-hash sha256:17ddf76718a5249b3407c39e95c02887684c8f16a682efa0dd0816f18293acab
```

- Ҫʹ**��root�û�**��������**kubectl**��ִ�У�
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

# node�ڵ����

����ִ��`/root/k8sdemo/k8s_image.sh`�����ؾ���

��������`kubeadm join`����������work�ڵ�ʹ������:
```
kubeadm join 192.168.182.134:6443 --token u68djx.q40ejbwsrsct8g0w \
    --discovery-token-ca-cert-hash sha256:17ddf76718a5249b3407c39e95c02887684c8f16a682efa0dd0816f18293acab
```

- �ظ���ȡtoken��join����Ϊ `kubeadm token create --print-join-command`

- ִ��kubectl get pods����������ʾ����ܾ����������ļ��������������
```bash   
   echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bash_profile
```
   
# ��װpod����

## calico(�Ƽ�)

https://docs.projectcalico.org/getting-started/kubernetes/quickstart

```bash
#1
kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml
#2
kubectl create -f https://docs.projectcalico.org/manifests/custom-resources.yaml
```

## fanneld

- ��ȡfanneld��yaml�ļ� 
```bash
wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
```
- ��ȡ����ű�,��ǽ������ֻ�ܽű�
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
- ���нű����ýű���Ҫ��ÿ��node������ 
- ��װflanneld kubectl apply -f kube-flanneld.yaml 
- ��work�ڵ����󣬲鿴node״̬����һֱnotready���鿴pod״̬��`kubectl -n kube-system get pods`    
- ���ֵ����������
  
1.  ���������ڵ㲻����ȡpause��kube-proxy����,������master�ϴ������
```
docker save -o pause.tar k8s.gcr.io/pause:3.1
docker save -o kube-proxy.tar k8s.gcr.io/kube-proxy
```
�ϴ���work node�� ʹ��docker load
```
docker load -i pause.tar 
docker load -i kube-proxy.tar
```
�����°�װ
```
kubectl delete -f kube-flannel.yml 
kubectl create -f kube-flannel.yml
```
2. ʹ��kubectl describe�鿴notready�ڵ���Ϣ������cni config uninitialized ʱ��
```
cat << EOF > /var/lib/kubelet/kubeadm-flags.env
KUBELET_KUBEADM_ARGS="--cgroup-driver=systemd --pod-infra-container- 
image=k8s.gcr.io/pause:3.1"
EOF
ɾ��`--network-plugin=cni`
systemctl restart kubelet
```
## weave

- ��ȡyaml�ļ�
```bash
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version|base64|tr -d `\n`)" 
```
- ע��

��codedns����ᱻ���ȵ�node�ϣ�����ȷ��node�ϴ���`k8s.gcr.io/coredns:{version}`

# ������Ⱥ

master��work������ʹ��`kubeadm reset`���ã�work�ڵ���˳�ͬ��ʹ�ø�����

- work�ڵ���/���ߣ�
1. work�ڵ�ʹ��`kubeadm reset`�������
2. ��master�ڵ�ʹ�� kubectl delete nodes <nodename>
3. �������� ʹ��`kubeadm join`

- master�ڵ�������
1. kubectlɾ������work node 
2. masterʹ��`kubeadm reset`���ã�ע���ʱ��û������ ~/.kube/config������
3. �������ߣ�ʹ��`kubeadm init`�󣬽�work node���룬��Ҫ���²���������

# ɾ����Ⱥ

1. ж�ط���:`kubeadm reset`

2. ɾ�����
```bash
yum remove kubelet kubeadm kubectl -y
```
3. ɾ������������
```bash
docker images -qa|xargs docker rmi -f
```