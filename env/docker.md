# CentOS 7
* see https://docs.docker.com/install/linux/docker-ce/centos/
1. ����yumԴ yum update
2. ɾ������ 
  `$ sudo yum remove docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-engine`
3. ��װ����
  `$ sudo yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2`
4.  ��docker ��ӵ�repo
 `$ sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo`
5. ��װ 
   * ָ���汾
      1. ���  `sudo yum install docker-ce docker-ce-cli containerd.io`
      2. ָ���汾 `yum install -y docker-ce-18.09.0-3.el7 docker-ce-cli-18.09.0-3.el7 
          containerd.io-1.2.0-3.el7`

7. ���ð��ﾵ��
     ��¼�����ƣ�ѡ��`�����������->���������`
8. ����  docker run hello-world  docker images