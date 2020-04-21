# �滮
 master 192.168.182.134
    ����  2 CPU����; docker 18.09.0-3.el7 ע��, ���µ�19�治֧��; k8s v1.16.3;
 work 1 192.168.182.135
 work 2 192.168.182.136
�ο� ��https://segmentfault.com/a/1190000020738509?utm_source=tag-newest
# Master CentOS 7 134
## ����׼��
* �رշ���ǽ
    systemctl disable firewalld
    systemctl stop firewalld
* �ر�selinux
 1.��ʱ����selinux
    setenforce 0
 2. ���ùر� �޸�/etc/sysconfig/selinux�ļ�����
    sed -i 's/SELINUX=permissive/SELINUX=disabled/' /etc/sysconfig/selinux
    sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
* �ر�swap
   1. swapoff -a
   2.���ý��ã���/etc/fstabע�͵�swap��һ�С�
     sed -i 's/.*swap.*/#&/' /etc/fstab
* �޸� /etc/hosts  ���192.168.182.13X->master��node
* �޸��ں˲��� 
   /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-ip6tables = 1
   net.bridge.bridge-nf-call-iptables = 1
   ��Ч sysctl --system
## �����װ
* network config 
1. ��ip����Ϊ192.168.182.134
     `cd /etc/sysconfig/network-scripts/`
     `vi ifcfg-ens33`
     ���÷�ʽ��� https://www.cnblogs.com/yanfly/p/10348103.html
     ���ú� `systemctl restart NetworkManager   systemctl restart network`
* yum config
     ���ð���yumԴ����鿴ָ��OS��`����`��https://opsx.alibaba.com/mirror
* docker config
  see #3 
* ��װkube ctl  
  see https://www.kubernetes.org.cn/installkubectl
* ��װ kubeadm kubelet  see https://www.kubernetes.org.cn/4256.html
1. ����k8s��Դ
  `/etc/yum.repos.d/kubernetes.repo`
   `[kubernetes]
    name=Kubernetes
    baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
    enabled=1
    gpgcheck=1
    repo_gpgcheck=1
    gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg 
    https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg` 
2. ��װ kubelet kubeadm  
    setenforce 0
    yum install -y kubelet kubeadm
    systemctl enable kubelet && systemctl start kubelet
3. ���ˣ��ڵ��׼��������ϣ��ɽ������������copy N����Ϊwork�Ļ���
## ʹ��kubeadm ���� master 
* ѡ��װ��kubeadm�Ļ��� ִ��
  kubeadm init  ���������Ȼ�����k8s���������apiserver/etcd�ȵ�
  ����ǽ�����ʲ��˹���repo�����ԴӰ��������ؾ������ȣ��ο�: https://segmentfault.com/a/1190000020738509?utm_source=tag-newest
1. ȷ�ϰ汾��Ϣ
  ` kubeadm config images list`
2. ��д�ű���ע�⽫�ű��İ汾�����滻Ϊ����ʵ��ֵ��
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
  3. ���� sh ./kubeadm.sh
* ִ��kubeadm
1. sudo kubeadm init \
 --apiserver-advertise-address 192.168.182.134 \
 --kubernetes-version=v1.16.3 \
 --pod-network-cidr=10.244.0.0/16
  ��������Ҫע�⣺ 
    1. pod-network-cidrָ����pod��������
    2. docker������ģʽ��Ϊsystemd
        ��� ��/etc/docker�´���daemon.json���༭��
        mkdir /etc/docker/daemon.json
        �����������ݣ�
       {"exec-opts":["native.cgroupdriver=systemd"]}
    3. cpu 2������ 
    4. �ں˻������ã���`��������`
* ������ kubeadm join XXXX �Լ�token ʱ��˵�����óɹ���
    1. �����Ҫ��װ���master�ڵ㣬���ʼ������ʹ��
     kubeadm init --apiserver-advertise-address 192.168.182.134 --control-plane-endpoint 
     192.168.182.134 --kubernetes-version=v1.16.3 --pod-network-cidr=10.244.0.0/16 --upload-certs
    2. ���master�ڵ�ʹ������:
     kubeadm join 192.168.182.134:6443 --token z34zii.ur84appk8h9r3yik --discovery-token-ca-cert-hash sha256:dae426820f2c6073763a3697abeb14d8418c9268288e37b8fc25674153702801 --control- 
     plane --certificate-key 1b9b0f1fdc0959a9decef7d812a2f606faf69ca44ca24d2e557b3ea81f415afe
* ��kube����ļ�ճ����home��
   mkdir -p $HOME/.kube;
   cp -i /etc/kubernetes/admin.conf $HOME/.kube/config;
   chown $(id -u):$(id -g) $HOME/.kube/config
* �ظ���ȡtoken��join����Ϊ kubeadm token create --print-join-command
* ִ��kubectl get pods����������ʾ����ܾ����������ļ��������������
   echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bash_profile
# ��װpod ���磨fanneld��
* ��ȡfanneld��yaml�ļ� wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
* ��ȡ����ű�,��ǽ������ֻ�ܽű�
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
* ���нű����ýű���Ҫ��ÿ��node������ 
* ��װflanneld kubectl apply -f kube-flanneld.yaml 
* ��work�ڵ����󣬲鿴node״̬����һֱnotready���鿴pod״̬��
  kubectl -n kube-system get pods    
  ���ֵ����������
  1.  ���������ڵ㲻����ȡpause��kube-proxy����
  ������master�ϴ������
  docker save -o pause.tar k8s.gcr.io/pause:3.1
  docker save -o kube-proxy.tar k8s.gcr.io/kube-proxy
  �ϴ���work node�� ʹ��docker load
  docker load -i pause.tar 
  docker load -i kube-proxy.tar
  �����°�װ
  kubectl delete -f kube-flannel.yml 
  kubectl create -f kube-flannel.yml

 2. ʹ��kubectl describe�鿴notready�ڵ���Ϣ������cni config uninitialized ʱ��
   cat << EOF > /var/lib/kubelet/kubeadm-flags.env
   KUBELET_KUBEADM_ARGS="--cgroup-driver=systemd --pod-infra-container- 
   image=k8s.gcr.io/pause:3.1"
   EOF
   ɾ��`--network-plugin=cni`
   systemctl restart kubelet

# Work CentOS 7
   �����ڵ� ��Ҫ���°�װ kubeadm kubelet flanneld docker
## ��װkubectl kubelet kubeadm ��master��ͬ 
## ���û������漰selinux/�ں˵ȣ���master��ͬ
## node����
    ִ������kubeadm join 192.168.182.134:6443 --token lixsl8.v1auqmf91ty0xl0k \
    --discovery-token-ca-cert-hash 
    sha256:c3f92a6ed9149ead327342f48a545e7e127a455d5b338129feac85893d918a55 \
   --ignore-preflight-errors=all 
   1. docker������ģʽ��Ϊsystemd
        ��� ��/etc/docker�´���daemon.json���༭��
        mkdir /etc/docker/daemon.json
        �����������ݣ�
       {"exec-opts":["native.cgroupdriver=systemd"]}
   2. ��ʾ����ɹ��󣬲鿴master��node״̬ kubectl get nodes

# ����˵��
* master��work������ʹ��kubeadm reset���ã�work�ڵ���˳�ͬ��ʹ�ø�����
* work�ڵ���/���ߣ�
   1. work�ڵ�ʹ��kubeadm reset �������
   2. ��master�ڵ�ʹ�� kubectl delete nodes <nodename>
   3. �������� ʹ��kubeadm join
* master�ڵ�������
  1. kubectl ɾ������work node 
  2. master ʹ��kubeadm reset���ã�ע���ʱ��û������ ~/.kube/config������
  3. �������ߣ�ʹ��kubeadm init �� ��worknode���룬��Ҫ��������flaneld��kubectl delete -f kube-fanneld.yml / kubectl create -f kube-finneld.yml 