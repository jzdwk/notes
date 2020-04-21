# Helm 是什么？？
Helm 是 Kubernetes 的包管理器。包管理器类似于我们在 Ubuntu 中使用的apt、Centos中使用的yum 或者Python中的 pip 一样，能快速查找、下载和安装软件包。Helm 由客户端组件 helm 和服务端组件 Tiller 组成, 能够将一组K8S资源打包统一管理, 是查找、共享和使用为Kubernetes构建的软件的最佳方式。
# Helm 解决了什么痛点？
在 Kubernetes中部署一个可以使用的应用，需要涉及到很多的 Kubernetes 资源的共同协作。比如你安装一个 WordPress 博客，用到了一些 Kubernetes (下面全部简称k8s)的一些资源对象，包括 Deployment 用于部署应用、Service 提供服务发现、Secret 配置 WordPress 的用户名和密码，可能还需要 pv 和 pvc 来提供持久化服务。并且 WordPress 数据是存储在mariadb里面的，所以需要 mariadb 启动就绪后才能启动 WordPress。这些 k8s 资源过于分散，不方便进行管理，直接通过 kubectl 来管理一个应用，你会发现这十分蛋疼。
所以总结以上，我们在 k8s 中部署一个应用，通常面临以下几个问题：
* 如何统一管理、配置和更新这些分散的 k8s 的应用资源文件
* 如何分发和复用一套应用模板
* 如何将应用的一系列资源当做一个软件包管理
see : https://www.hi-linux.com/posts/21466.html
# 环境
   minikube v1.15、helm3、ubuntu 16、harbor 1.8.2
* 获取helm3 see https://github.com/helm/helm/releases
* 安装 see https://helm.sh/docs/intro/install/
  1. 解压tar包 tar -zxvf helm-v3.0.0-linux-amd64.tgz
  2. mv linux-amd64/helm /usr/local/bin/helm
  3. helm version 检查版本
# 常用命令
 see https://v3.helm.sh/docs/intro/using_helm/
# 使用harbor进行chart管理
* ui模式，见https://github.com/goharbor/harbor/blob/master/docs/user_guide.md#manage-helm-charts
* cli模式 首先安装plugin： `helm plugin install https://github.com/chartmuseum/helm-push`
  helm3并不能按照本地repo list的名称进行push ，因此需要直接使用url， 如果harbor以https方式部署，需要添加颁发者ca.crt
 即： `helm push --ca-file=ca.crt --username=admin --password=passw0rd chart_repo/hello-helm-0.1.0.tgz https://192.168.1.123:443/chartrepo/chartrepo`