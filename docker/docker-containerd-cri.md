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

**注意，此时启动的pod中，仅存在一个pause容器**

cri create的整体流程可参考

[!cri-create](../images/docker/kubelet-cri-containerd.png)


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
	//初始化CNI插件，用于后续的sandbox网络配置
	if err := c.initPlatform(); err != nil {
		return nil, errors.Wrap(err, "initialize platform")
	}
	// prepare streaming server
	//定义http服务的路由，在run中被拉起
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
	//路由 ：GET/POST "/exec/{token}", "/attach/{token}", "/portforward/{token}"
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
以上为`initCRIService`的实现，其调用时机为**containerd load plugin**后，具体可参考[containerd笔记](docker-containerd.md)

由于`criService`实现了grpc接口：
```go
// grpcServices are all the grpc services provided by cri containerd.
type grpcServices interface {
	//runtime的grpc接口定义，来自"k8s.io/cri-api/pkg/apis/runtime/v1alpha2"
	runtime.RuntimeServiceServer  
	//image的grpc接口定义，依赖同上
	runtime.ImageServiceServer    
}
//CRIService接口
type CRIService interface {
	Run() error
	// io.Closer is used by containerd to gracefully stop cri service.
	io.Closer
	plugin.Service
	grpcServices //继承grpc接口
}
//criService的grpc实现
func (c *criService) Register(s *grpc.Server) error {
	return c.register(s)
}
//分别注册image和runtime服务
func (c *criService) register(s *grpc.Server) error {
	instrumented := newInstrumentedService(c)
	runtime.RegisterRuntimeServiceServer(s, instrumented)
	runtime.RegisterImageServiceServer(s, instrumented)
	return nil
}
```
因此，在containerd拉起服务时，（参考：[containerd笔记](docker-containerd.md)），便会注册服务。

## cri接口

containerd的criService实现了cri定义的两个接口：`RuntimeServiceServer`和`ImageServiceServer`,其定义如下：

- **RuntimeServiceServer**：负责管理Pod和容器的生命周期 

1. PodSandbox的管理接口: PodSandbox是对kubernete Pod的抽象,用来给容器提供一个隔离的环境(比如挂载到相同的cgroup下面)并提供网络等共享的命名空间.PodSandbox通常对应到一个Pause容器或者一台虚拟机
 
2. Container的管理接口: 在指定的 PodSandbox 中创建、启动、停止和删除容器。

3. Streaming API接口: 包括Exec、Attach和PortForward 等三个和容器进行数据交互的接口,这三个接口返回的是运行时Streaming Server的URL,而不是直接跟容器交互

4. 状态接口: 包括查询API版本和查询运行时状态


```go
// RuntimeServiceServer is the server API for RuntimeService service.
type RuntimeServiceServer interface {
	// Version returns the runtime name, runtime version, and runtime API version.
	Version(context.Context, *VersionRequest) (*VersionResponse, error)
	// RunPodSandbox creates and starts a pod-level sandbox. Runtimes must ensure
	// the sandbox is in the ready state on success.
	RunPodSandbox(context.Context, *RunPodSandboxRequest) (*RunPodSandboxResponse, error)
	// StopPodSandbox stops any running process that is part of the sandbox and
	// reclaims network resources (e.g., IP addresses) allocated to the sandbox.
	// If there are any running containers in the sandbox, they must be forcibly
	// terminated.
	// This call is idempotent, and must not return an error if all relevant
	// resources have already been reclaimed. kubelet will call StopPodSandbox
	// at least once before calling RemovePodSandbox. It will also attempt to
	// reclaim resources eagerly, as soon as a sandbox is not needed. Hence,
	// multiple StopPodSandbox calls are expected.
	StopPodSandbox(context.Context, *StopPodSandboxRequest) (*StopPodSandboxResponse, error)
	// RemovePodSandbox removes the sandbox. If there are any running containers
	// in the sandbox, they must be forcibly terminated and removed.
	// This call is idempotent, and must not return an error if the sandbox has
	// already been removed.
	RemovePodSandbox(context.Context, *RemovePodSandboxRequest) (*RemovePodSandboxResponse, error)
	// PodSandboxStatus returns the status of the PodSandbox. If the PodSandbox is not
	// present, returns an error.
	PodSandboxStatus(context.Context, *PodSandboxStatusRequest) (*PodSandboxStatusResponse, error)
	// ListPodSandbox returns a list of PodSandboxes.
	ListPodSandbox(context.Context, *ListPodSandboxRequest) (*ListPodSandboxResponse, error)
	// CreateContainer creates a new container in specified PodSandbox
	CreateContainer(context.Context, *CreateContainerRequest) (*CreateContainerResponse, error)
	// StartContainer starts the container.
	StartContainer(context.Context, *StartContainerRequest) (*StartContainerResponse, error)
	// StopContainer stops a running container with a grace period (i.e., timeout).
	// This call is idempotent, and must not return an error if the container has
	// already been stopped.
	// TODO: what must the runtime do after the grace period is reached?
	StopContainer(context.Context, *StopContainerRequest) (*StopContainerResponse, error)
	// RemoveContainer removes the container. If the container is running, the
	// container must be forcibly removed.
	// This call is idempotent, and must not return an error if the container has
	// already been removed.
	RemoveContainer(context.Context, *RemoveContainerRequest) (*RemoveContainerResponse, error)
	// ListContainers lists all containers by filters.
	ListContainers(context.Context, *ListContainersRequest) (*ListContainersResponse, error)
	// ContainerStatus returns status of the container. If the container is not
	// present, returns an error.
	ContainerStatus(context.Context, *ContainerStatusRequest) (*ContainerStatusResponse, error)
	// UpdateContainerResources updates ContainerConfig of the container.
	UpdateContainerResources(context.Context, *UpdateContainerResourcesRequest) (*UpdateContainerResourcesResponse, error)
	// ReopenContainerLog asks runtime to reopen the stdout/stderr log file
	// for the container. This is often called after the log file has been
	// rotated. If the container is not running, container runtime can choose
	// to either create a new log file and return nil, or return an error.
	// Once it returns error, new container log file MUST NOT be created.
	ReopenContainerLog(context.Context, *ReopenContainerLogRequest) (*ReopenContainerLogResponse, error)
	// ExecSync runs a command in a container synchronously.
	ExecSync(context.Context, *ExecSyncRequest) (*ExecSyncResponse, error)
	// Exec prepares a streaming endpoint to execute a command in the container.
	Exec(context.Context, *ExecRequest) (*ExecResponse, error)
	// Attach prepares a streaming endpoint to attach to a running container.
	Attach(context.Context, *AttachRequest) (*AttachResponse, error)
	// PortForward prepares a streaming endpoint to forward ports from a PodSandbox.
	PortForward(context.Context, *PortForwardRequest) (*PortForwardResponse, error)
	// ContainerStats returns stats of the container. If the container does not
	// exist, the call returns an error.
	ContainerStats(context.Context, *ContainerStatsRequest) (*ContainerStatsResponse, error)
	// ListContainerStats returns stats of all running containers.
	ListContainerStats(context.Context, *ListContainerStatsRequest) (*ListContainerStatsResponse, error)
	// UpdateRuntimeConfig updates the runtime configuration based on the given request.
	UpdateRuntimeConfig(context.Context, *UpdateRuntimeConfigRequest) (*UpdateRuntimeConfigResponse, error)
	// Status returns the status of the runtime.
	Status(context.Context, *StatusRequest) (*StatusResponse, error)
}
```
- **ImageServiceServer**： 负责镜像的生命管理周期

1. 查询镜像列表
2. 拉取镜像到本地
3. 查询镜像状态
4. 删除本地镜像
5. 查询镜像占用空间


```go
// ImageServiceServer is the server API for ImageService service.
type ImageServiceServer interface {
	// ListImages lists existing images.
	ListImages(context.Context, *ListImagesRequest) (*ListImagesResponse, error)
	// ImageStatus returns the status of the image. If the image is not
	// present, returns a response with ImageStatusResponse.Image set to
	// nil.
	ImageStatus(context.Context, *ImageStatusRequest) (*ImageStatusResponse, error)
	// PullImage pulls an image with authentication config.
	PullImage(context.Context, *PullImageRequest) (*PullImageResponse, error)
	// RemoveImage removes the image.
	// This call is idempotent, and must not return an error if the image has
	// already been removed.
	RemoveImage(context.Context, *RemoveImageRequest) (*RemoveImageResponse, error)
	// ImageFSInfo returns information of the filesystem that is used to store images.
	ImageFsInfo(context.Context, *ImageFsInfoRequest) (*ImageFsInfoResponse, error)
}
```

## 创建PodSandbox

创建PodSandbox的入口为`RuntimeServiceServer`定义的`RunPodSandbox(context.Context, *RunPodSandboxRequest) (*RunPodSandboxResponse, error)`。

根据上文，containerd的cri插件被加载后，创建的`criService`对象实现了该接口：
```go
// RunPodSandbox creates and starts a pod-level sandbox. Runtimes should ensure
// the sandbox is in ready state.
func (c *criService) RunPodSandbox(ctx context.Context, r *runtime.RunPodSandboxRequest) (_ *runtime.RunPodSandboxResponse, retErr error) {
	//解析请求，生成sandbox基本信息
	config := r.GetConfig()
	id := util.GenerateID()
	metadata := config.GetMetadata()
	...
	name := makeSandboxName(metadata)
	...
	// Reserve the sandbox name to avoid concurrent `RunPodSandbox` request starting the
	// same sandbox.
	// 将sandbox的name/id存储在一个全局的并发安全map，以备查重，如果已存在则err
	if err := c.sandboxNameIndex.Reserve(name, id); err != nil {
		return nil, errors.Wrapf(err, "failed to reserve sandbox name %q", name)
	}
	defer func() {
		// Release the name if the function returns with an error.
		if retErr != nil {
			c.sandboxNameIndex.ReleaseByName(name)
		}
	}()

	// Create initial internal sandbox object.
	sandbox := sandboxstore.NewSandbox(
		sandboxstore.Metadata{
			ID:             id,
			Name:           name,
			Config:         config,
			RuntimeHandler: r.GetRuntimeHandler(),
		},
		sandboxstore.Status{
			State: sandboxstore.StateUnknown,
		},
	)

	// Ensure sandbox container image snapshot.
	// 确保image存在，不存在则pull
	image, err := c.ensureImageExists(ctx, c.config.SandboxImage, config)
	...
	//转化为containerd定义的容器镜像类型
	containerdImage, err := c.toContainerdImage(ctx, *image)
	...
	//获取sandbox的oci runtime
	//kubelet与containerd的交互通过cri标准接口
	//runtime的实际执行通过oci
	ociRuntime, err := c.getSandboxRuntime(config, r.GetRuntimeHandler())
	...
	//
	podNetwork := true
	// Pod network is always needed on windows.
	...
	if podNetwork {
		// If it is not in host network namespace then create a namespace and set the sandbox
		// handle. NetNSPath in sandbox metadata and NetNS is non empty only for non host network
		// namespaces. If the pod is in host network namespace then both are empty and should not
		// be used.
		// 创建Pod沙盒的网络命名空间，如果network为host模式，则无需创建。
		sandbox.NetNS, err = netns.NewNetNS()
		...
		sandbox.NetNSPath = sandbox.NetNS.GetPath()
		defer func() {
			if retErr != nil {
				//...清除命名空间
			}
		}()

		// Setup network for sandbox.
		// Certain VM based solutions like clear containers (Issue containerd/cri-containerd#524)
		// rely on the assumption that CRI shim will not be querying the network namespace to check the
		// network states such as IP.
		// In future runtime implementation should avoid relying on CRI shim implementation details.
		// In this case however caching the IP will add a subtle performance enhancement by avoiding
		// calls to network namespace of the pod to query the IP of the veth interface on every
		// SandboxStatus request.
		// 这里会调用CNI插件（例如：/opt/cni/bin/bridge)来给Pod沙盒的网络命名空间配置网络
		if err := c.setupPodNetwork(ctx, &sandbox); err != nil {
			return nil, errors.Wrapf(err, "failed to setup network for sandbox %q", id)
		}
	}

	// Create sandbox container.
	// NOTE: sandboxContainerSpec SHOULD NOT have side
	// effect, e.g. accessing/creating files, so that we can test
	// it safely.
	// 构造runtime spec
	spec, err := c.sandboxContainerSpec(id, config, &image.ImageSpec.Config, sandbox.NetNSPath, ociRuntime.PodAnnotations)
	//对spec个别属性进行设置，此处貌似都是空函数
	...
	sandbox.ProcessLabel = spec.Process.SelinuxLabel
	...
	// handle any KVM based runtime
	if err := modifyProcessLabel(ociRuntime.Type, spec); err != nil {
		return nil, err
	}

	if config.GetLinux().GetSecurityContext().GetPrivileged() {
		// If privileged don't set selinux label, but we still record the MCS label so that
		// the unused label can be freed later.
		spec.Process.SelinuxLabel = ""
	}
	// Generate spec options that will be applied to the spec later.
	specOpts, err := c.sandboxContainerSpecOpts(config, &image.ImageSpec.Config)
	...
	sandboxLabels := buildLabels(config.Labels, containerKindSandbox)
	runtimeOpts, err := generateRuntimeOptions(ociRuntime, c.config)
	...
	//
	snapshotterOpt := snapshots.WithLabels(snapshots.FilterInheritedLabels(config.Annotations))
	//opts为函数变量func(ctx context.Context, client *Client, c *containers.Container) error 
	//思路与前文的criServiceOpts相同，注册n个opts，在NewContainer时回填参数至containers.Container
	opts := []containerd.NewContainerOpts{
		containerd.WithSnapshotter(c.config.ContainerdConfig.Snapshotter),
		customopts.WithNewSnapshot(id, containerdImage, snapshotterOpt),
		containerd.WithSpec(spec, specOpts...),
		containerd.WithContainerLabels(sandboxLabels),
		containerd.WithContainerExtension(sandboxMetadataExtension, &sandbox.Metadata),
		containerd.WithRuntime(ociRuntime.Type, runtimeOpts)}
	//NewContainer的内部调用了containerStore的Create函数
	//此处与docker-containerd的笔记中创建容器调用了相同的函数，均为写db信息
	//sandbox对应于pod，此处的container即为pause容器
	container, err := c.client.NewContainer(ctx, id, opts...)
	//...if err, delete container
	...
	// Create sandbox container root directories.
	// 创建sandbox的root工作目录，将配置文件保存到sandbox根目录下，主要是hostname resolv.conf hosts文件
	sandboxRootDir := c.getSandboxRootDir(id)
	if err := c.os.MkdirAll(sandboxRootDir, 0755); err != nil {
		return nil, errors.Wrapf(err, "failed to create sandbox root directory %q",
			sandboxRootDir)
	}
	//...if err, delete root dir
	volatileSandboxRootDir := c.getVolatileSandboxRootDir(id)
	if err := c.os.MkdirAll(volatileSandboxRootDir, 0755); err != nil {
		return nil, errors.Wrapf(err, "failed to create volatile sandbox root directory %q",
			volatileSandboxRootDir)
	}
	//...if err, delete volatile dir
	
	// Setup files required for the sandbox.
	if err = c.setupSandboxFiles(id, config); err != nil {
		return nil, errors.Wrapf(err, "failed to setup sandbox files")
	}
	//...if err, delete sandbox file

	// Update sandbox created timestamp.
	info, err := container.Info(ctx)
	...

	// Create sandbox task in containerd.
	taskOpts := c.taskOpts(ociRuntime.Type)
	// We don't need stdio for sandbox container.
	// 创建任务，向containerd发送CreateTaskRequest来创建任务
	task, err := container.NewTask(ctx, containerdio.NullIO, taskOpts...)
	...if err, send delete task request

	// wait is a long running background request, no timeout needed.
	exitCh, err := task.Wait(ctrdutil.NamespacedContext())
	...

	nric, err := nri.New()
	...
	if nric != nil {
		nriSB := &nri.Sandbox{
			ID:     id,
			Labels: config.Labels,
		}
		if _, err := nric.InvokeWithSandbox(ctx, task, v1.Create, nriSB); err != nil {
			return nil, errors.Wrap(err, "nri invoke")
		}
	}
	// 向containerd发送StartTaskRequest来启动任务，效果就是运行pause容器
	if err := task.Start(ctx); err != nil {
		return nil, errors.Wrapf(err, "failed to start sandbox container task %q", id)
	}
	//更新db信息
	if err := sandbox.Status.Update(func(status sandboxstore.Status) (sandboxstore.Status, error) {
		// Set the pod sandbox as ready after successfully start sandbox container.
		status.Pid = task.Pid()
		status.State = sandboxstore.StateReady
		status.CreatedAt = info.CreatedAt
		return status, nil
	}); err != nil {
		return nil, errors.Wrap(err, "failed to update sandbox status")
	}

	// Add sandbox into sandbox store in INIT state.
	sandbox.Container = container

	if err := c.sandboxStore.Add(sandbox); err != nil {
		return nil, errors.Wrapf(err, "failed to add sandbox %+v into store", sandbox)
	}

	// start the monitor after adding sandbox into the store, this ensures
	// that sandbox is in the store, when event monitor receives the TaskExit event.
	//
	// TaskOOM from containerd may come before sandbox is added to store,
	// but we don't care about sandbox TaskOOM right now, so it is fine.
	c.eventMonitor.startExitMonitor(context.Background(), id, task.Pid(), exitCh)

	return &runtime.RunPodSandboxResponse{PodSandboxId: id}, nil
}
```

## 创建PodContainer

## 启动PodContainer

## 参考

https://blog.51cto.com/u_15072904/2615587