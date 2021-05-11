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
	//获取serviceOpts数组，数组中的每一个serviceOpt元素是一个函数变量，用于给service设置依赖的插件项
	servicesOpts, err := getServicesOpts(ic)
```
这里进入`getServicesOpts(ic)`的实现:
```go
// getServicesOpts get service options from plugin context.
func getServicesOpts(ic *plugin.InitContext) ([]containerd.ServicesOpt, error) {
	//从ic的plugins的map中获取值map[pluginID]plugins
	//getByType是从一个2层map中，根据plugin.ServicePlugin取一个map
	//2层map定义为：byTypeAndID = make(map[Type]map[string]*Plugin)
	//即[typeOrId,[pluginId,plugin]]
	plugins, err := ic.GetByType(plugin.ServicePlugin)
	...
	//opts数组，第一个元素为“向service的eventService中写入ic.Events”函数变量
	opts := []containerd.ServicesOpt{
		containerd.WithEventService(ic.Events),
	}
	//定义cri依赖的插件
	//具体操作为定义一个map，key为插件id，比如ContentService，value为serviceOpt函数。
	//可以看到依赖的有ContentService/ImagesService/ContainersService等等
	for s, fn := range map[string]func(interface{}) containerd.ServicesOpt{
		services.ContentService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithContentStore(s.(content.Store))
		},
		services.ImagesService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithImageService(s.(images.ImagesClient))
		},
		services.SnapshotsService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithSnapshotters(s.(map[string]snapshots.Snapshotter))
		},
		services.ContainersService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithContainerService(s.(containers.ContainersClient))
		},
		services.TasksService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithTaskService(s.(tasks.TasksClient))
		},
		services.DiffService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithDiffService(s.(diff.DiffClient))
		},
		services.NamespacesService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithNamespaceService(s.(namespaces.NamespacesClient))
		},
		services.LeasesService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithLeasesService(s.(leases.Manager))
		},
		services.IntrospectionService: func(s interface{}) containerd.ServicesOpt {
			return containerd.WithIntrospectionService(s.(introspectionapi.IntrospectionClient))
		},
	} {
		//如果在map[pluginId]plugin中存在
		p := plugins[s]
		...
		i, err := p.Instance()
		...
		//fn即func WithXXX(xxx interface{}) ServicesOpt
		opts = append(opts, fn(i))
	}
	return opts, nil
}

//以contentService为例
//WithContentStore sets the content store.
func WithContentStore(contentStore content.Store) ServicesOpt {
	//返回的servicesOpt为，向s.contentStore项中设置插件服务contentStore
	return func(s *services) {
		s.contentStore = contentStore
	}
}
```
继续回到外层`initCRIService`，接下来将创建服务对象并启动:
```go
	...
	//New函数传入了3个ClientOpt
	client, err := containerd.New(
		"",
		//设置client的ns
		containerd.WithDefaultNamespace(constants.K8sContainerdNamespace),
		//设置client的platform
		containerd.WithDefaultPlatform(criplatforms.Default()),
		//设置client需要用到的插件服务依赖
		containerd.WithServices(servicesOpts...),
	)
	...
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

// NewCRIService returns a new instance of CRIService
func NewCRIService(config criconfig.Config, client *containerd.Client) (CRIService, error) {
	var err error
	labels := label.NewStore()
	c := &criService{
		config:             config,
		client:             client,
		os:                 osinterface.RealOS{},
		sandboxStore:       sandboxstore.NewStore(labels),
		containerStore:     containerstore.NewStore(labels),
		imageStore:         imagestore.NewStore(client),
		snapshotStore:      snapshotstore.NewStore(),
		sandboxNameIndex:   registrar.NewRegistrar(),
		containerNameIndex: registrar.NewRegistrar(),
		initialized:        atomic.NewBool(false),
	}

	if client.SnapshotService(c.config.ContainerdConfig.Snapshotter) == nil {
		return nil, errors.Errorf("failed to find snapshotter %q", c.config.ContainerdConfig.Snapshotter)
	}
	c.imageFSPath = imageFSPath(config.ContainerdRootDir, config.ContainerdConfig.Snapshotter)
	...
	if err := c.initPlatform(); err != nil {
		return nil, errors.Wrap(err, "initialize platform")
	}
	// prepare streaming server
	c.streamServer, err = newStreamServer(c, config.StreamServerAddress, config.StreamServerPort, config.StreamIdleTimeout)
	...
	c.eventMonitor = newEventMonitor(c)
	c.cniNetConfMonitor, err = newCNINetConfSyncer(c.config.NetworkPluginConfDir, c.netPlugin, c.cniLoadOptions())
	...
	// Preload base OCI specs
	c.baseOCISpecs, err = loadBaseOCISpecs(&config)
	...
	return c, nil
}
```
最后，看下`Run()`函数：
```go
// Run starts the CRI service.
func (c *criService) Run() error {
	logrus.Info("Start subscribing containerd event")
	//1. 向事件监听器注册
	//过滤事件主题 topic=="/tasks/oom" && topic~="/images/"
	c.eventMonitor.subscribe(c.client)
	//恢复已拉起的sandbox
	logrus.Infof("Start recovering state")
	if err := c.recover(ctrdutil.NamespacedContext()); err != nil {
		return errors.Wrap(err, "failed to recover state")
	}
	//2. 拉起到达事件的处理
	// Start event handler.
	logrus.Info("Start event monitor")
	eventMonitorErrCh := c.eventMonitor.start()
	//3. snapshot同步服务
	// Start snapshot stats syncer, it doesn't need to be stopped.
	logrus.Info("Start snapshots syncer")
	snapshotsSyncer := newSnapshotsSyncer(
		c.snapshotStore,
		c.client.SnapshotService(c.config.ContainerdConfig.Snapshotter),
		time.Duration(c.config.StatsCollectPeriod)*time.Second,
	)
	snapshotsSyncer.start()
    //4. CNI网络配置同步
	// Start CNI network conf syncer
	logrus.Info("Start cni network conf syncer")
	cniNetConfMonitorErrCh := make(chan error, 1)
	go func() {
		defer close(cniNetConfMonitorErrCh)
		cniNetConfMonitorErrCh <- c.cniNetConfMonitor.syncLoop()
	}()
    //5. 拉起http服务
	// Start streaming server.
	logrus.Info("Start streaming server")
	streamServerErrCh := make(chan error)
	go func() {
		defer close(streamServerErrCh)
		if err := c.streamServer.Start(true); err != nil && err != http.ErrServerClosed {
			logrus.WithError(err).Error("Failed to start streaming server")
			streamServerErrCh <- err
		}
	}()

	// Set the server as initialized. GRPC services could start serving traffic.
	c.initialized.Set()

	var eventMonitorErr, streamServerErr, cniNetConfMonitorErr error
	// Stop the whole CRI service if any of the critical service exits.
	select {
	case eventMonitorErr = <-eventMonitorErrCh:
	case streamServerErr = <-streamServerErrCh:
	case cniNetConfMonitorErr = <-cniNetConfMonitorErrCh:
	}
	if err := c.Close(); err != nil {
		return errors.Wrap(err, "failed to stop cri service")
	}
	// If the error is set above, err from channel must be nil here, because
	// the channel is supposed to be closed. Or else, we wait and set it.
	if err := <-eventMonitorErrCh; err != nil {
		eventMonitorErr = err
	}
	logrus.Info("Event monitor stopped")
	// There is a race condition with http.Server.Serve.
	// When `Close` is called at the same time with `Serve`, `Close`
	// may finish first, and `Serve` may still block.
	// See https://github.com/golang/go/issues/20239.
	// Here we set a 2 second timeout for the stream server wait,
	// if it timeout, an error log is generated.
	// TODO(random-liu): Get rid of this after https://github.com/golang/go/issues/20239
	// is fixed.
	const streamServerStopTimeout = 2 * time.Second
	select {
	case err := <-streamServerErrCh:
		if err != nil {
			streamServerErr = err
		}
		logrus.Info("Stream server stopped")
	case <-time.After(streamServerStopTimeout):
		logrus.Errorf("Stream server is not stopped in %q", streamServerStopTimeout)
	}
	if eventMonitorErr != nil {
		return errors.Wrap(eventMonitorErr, "event monitor error")
	}
	if streamServerErr != nil {
		return errors.Wrap(streamServerErr, "stream server error")
	}
	if cniNetConfMonitorErr != nil {
		return errors.Wrap(cniNetConfMonitorErr, "cni network conf monitor error")
	}
	return nil
}
```