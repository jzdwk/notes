#cri

## 介绍

Kubernetes为了支持多种容器运行时，将关于容器的操作进行了抽象，定义了**CRI接口**，来供容器运行时接入。这个接口能让**kubelet**无需编译就可以支持多种容器运行时。

Kubelet与容器运行时通信（或者是实现了CRI插件的容器运行时）时，Kubelet就像是客户端，而CRI插件就像对应的服务器。它们之间可以通过Unix 套接字或者gRPC框架进行通信。

kubelet(grpc client)->cri interface->cri shim(grpc server)->container runtime->containers

[!kubelet
-cri](../images/docker/docker-kubelet-cri.jpg)

CRI的[接口](https://github.com/kubernetes/cri-api/blob/master/pkg/apis/runtime/v1alpha2/api.proto) 主要分为两类：
- 镜像相关的操作，包括：镜像拉取，删除，列表等
- 容器相关的操作：包括：Pod沙盒(sandbox)的创建、停止，Pod内容器的创建、启动、停止、删除等

因此，containerd对于cri的实现主要应用在容器编排领域，比如k8s，k3s。

参考：
- [k8s cri简介](https://www.kubernetes.org.cn/1079.html)
- [cri通过containerd创建pod](https://blog.51cto.com/u_15072904/2615587)

目前，containerd的cri插件，已经从独立的cri repo移入containerd repo的[cri目录下](https://github.com/containerd/cri)


### cri create过程

kubelet调用CRI接口创建Pod的过程主要分为3步：

1. **创建PodSandbox** 

对应的CRI接口是RunPodSandbox。PodSandbox就是k8s Pod，Pod中会默认运行一个的**pause容器**(父容器，共享网络)。不同的容器运行时，Pod沙盒的实现方式也不一样，比如使用kata作为runtime，Pod沙盒被实现为一个虚拟机；而使用runc作为runtime，Pod沙盒就是一个独立的namespace和cgroups。

2. **创建PodContainer**

对应的CRI接口是CreatePodContainer。PodContainer就是用户所要运行的容器，比如nginx容器。创建好的PodContainer会被加入到PodSanbox中，共享网络命名空间。
  
3. **启动PodContainer**

对应的CRI接口是StartPodContainer。启动上一步中创建的PodContainer。

## cri init

因为cri被移入containerd中，所以直接从master上看containerd cri插件。首先是`/containerd/pkg/cri/cri.go`的`init`函数：
```gofunc init() {
	config := criconfig.DefaultConfig()
	plugin.Register(&plugin.Registration{
		//类型为GRPC的插件
		Type:   plugin.GRPCPlugin,
		ID:     "cri",
		Config: &config,
		//依赖Service插件
		Requires: []plugin.Type{
			plugin.ServicePlugin,
		},
		InitFn: initCRIService,
	})
}
```
根据[docker-containerd](docker-containerd.md)中对于plugin的加载，定位`initCRIService`，该函数在containerd启动时被依次调用：
```go
//ic 即在containerd的main启动时的初始化上下文
func initCRIService(ic *plugin.InitContext) (interface{}, error) {
	//向全局initContext回写注册信息
	ic.Meta.Platforms = []imagespec.Platform{platforms.DefaultSpec()}
	ic.Meta.Exports = map[string]string{"CRIVersion": constants.CRIVersion}
	ctx := ic.Context
	//验证config
	pluginConfig := ic.Config.(*criconfig.PluginConfig)
	if err := criconfig.ValidatePluginConfig(ctx, pluginConfig); err != nil {
		return nil, errors.Wrap(err, "invalid plugin config")
	}
	//封装cri service config
	c := criconfig.Config{
		PluginConfig:       *pluginConfig,
		ContainerdRootDir:  filepath.Dir(ic.Root),
		ContainerdEndpoint: ic.Address,
		RootDir:            ic.Root,
		StateDir:           ic.State,
	}
	...
	//
	servicesOpts, err := getServicesOpts(ic)
	if err != nil {
		return nil, errors.Wrap(err, "failed to get services")
	}

	log.G(ctx).Info("Connect containerd service")
	client, err := containerd.New(
		"",
		containerd.WithDefaultNamespace(constants.K8sContainerdNamespace),
		containerd.WithDefaultPlatform(criplatforms.Default()),
		containerd.WithServices(servicesOpts...),
	)
	if err != nil {
		return nil, errors.Wrap(err, "failed to create containerd client")
	}
	//创建一个cri service
	//由于cri service实现了CRIService接口，CRIService由继承了plugin.Service
	//所以cri service会被注册为grpc服务
	s, err := server.NewCRIService(c, client)
	...
	//启动Run
	go func() {
		if err := s.Run(); err != nil {
			log.G(ctx).WithError(err).Fatal("Failed to run CRI service")
		}
		// TODO(random-liu): Whether and how we can stop containerd.
	}()
	return s, nil
}

```