# CentOS 7
* see https://docs.docker.com/install/linux/docker-ce/centos/
1. 更新yum源 yum update
2. 删除已有 
  `$ sudo yum remove docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-engine`
3. 安装工具
  `$ sudo yum install -y yum-utils \
  device-mapper-persistent-data \
  lvm2`
4.  将docker 添加到repo
 `$ sudo yum-config-manager \
    --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo`
5. 安装 
   * 指定版本
      1. 最近  `sudo yum install docker-ce docker-ce-cli containerd.io`
      2. 指定版本 `yum install -y docker-ce-18.09.0-3.el7 docker-ce-cli-18.09.0-3.el7 
          containerd.io-1.2.0-3.el7`

7. 配置阿里镜像：
     登录阿里云，选择`容器镜像服务->镜像加速器`
8. 测试  docker run hello-world  docker images