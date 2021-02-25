# containerd

Containerd 是一个工业级的容器运行时，和docker的关系可以看为：`docker->containerd->shim/runC`。docker通过调用containerd的grpc client接口拉起容器。

它强调简单性、健壮性和可移植性。containerd 可以在宿主机中管理完整的容器生命周期，包括：

- 管理容器的生命周期(从创建容器到销毁容器)
- 拉取/推送容器镜像
- 存储管理(管理镜像及容器数据的存储)
- 调用 runC 运行容器(与 runC 等容器运行时交互)
- 管理容器网络接口及网络

架构如![图](../images/docker/docker-containerd.png)

由于containerd包含了拉起容器的所有功能，因此，在k8s中拉起pod内的容器时，存在以下路径：
```
1. k8s集成docker：k8s->kubelete->docker-shim->docker api->docker-daemon->containerd->containerd-shim->oci/runC
2. k8s绕过docker:  k8s->kubelete->containerd->containerd-shim->oci/runC
```
目前正朝路径2进行技术演进。containerd 被设计成嵌入到一个更大的系统中，而不是直接由开发人员或终端用户使用。

使用containerd API拉取镜像并创建redis容器，可[移步](https://containerd.io/docs/getting-started/)

containerd的namespaces、client options可[移步](https://github.com/containerd/containerd/blob/master/README.md)

## service define

containerd的grpc服务定义位于`/containerd/api/services/containers/v1/containers.proto`，可以看到对容器crud的定义:
```
service Containers {
	rpc Get(GetContainerRequest) returns (GetContainerResponse);
	rpc List(ListContainersRequest) returns (ListContainersResponse);
	rpc ListStream(ListContainersRequest) returns (stream ListContainerMessage);
	rpc Create(CreateContainerRequest) returns (CreateContainerResponse);
	rpc Update(UpdateContainerRequest) returns (UpdateContainerResponse);
	rpc Delete(DeleteContainerRequest) returns (google.protobuf.Empty);
}
//...具体结构体定义省略
```
相应的，生成的go文件`containers.pb.go`中，该服务被描述为`ContainersServer`接口。注册该服务的方法`RegisterContainersServer`在`main.go`的New中被调用
```go
...
server, err := server.New(ctx, config)
...

// New creates and initializes a new containerd server
func New(ctx context.Context, config *srvconfig.Config) (*Server, error) {
	...
	serverOpts := []grpc.ServerOption{
		grpc.UnaryInterceptor(grpc_prometheus.UnaryServerInterceptor),
		grpc.StreamInterceptor(grpc_prometheus.StreamServerInterceptor),
	}
	if config.GRPC.MaxRecvMsgSize > 0 {
		serverOpts = append(serverOpts, grpc.MaxRecvMsgSize(config.GRPC.MaxRecvMsgSize))
	}
	if config.GRPC.MaxSendMsgSize > 0 {
		serverOpts = append(serverOpts, grpc.MaxSendMsgSize(config.GRPC.MaxSendMsgSize))
	}
	rpc := grpc.NewServer(serverOpts...)
	var (
		services []plugin.Service
		s        = &Server{
			rpc:    rpc,
			events: exchange.NewExchange(),
			config: config,
		}
		initialized = plugin.NewPluginSet()
	)
	//插件配置
	for _, p := range plugins {
		id := p.URI()
		log.G(ctx).WithField("type", p.Type).Infof("loading plugin %q...", id)

		initContext := plugin.NewContext(
			ctx,
			p,
			initialized,
			config.Root,
			config.State,
		)
		initContext.Events = s.events
		initContext.Address = config.GRPC.Address

		// load the plugin specific configuration if it is provided
		if p.Config != nil {
			pluginConfig, err := config.Decode(p.ID, p.Config)
			if err != nil {
				return nil, err
			}
			initContext.Config = pluginConfig
		}
		result := p.Init(initContext)
		if err := initialized.Add(result); err != nil {
			return nil, errors.Wrapf(err, "could not add plugin result to plugin set")
		}

		instance, err := result.Instance()
		if err != nil {
			if plugin.IsSkipPlugin(err) {
				log.G(ctx).WithField("type", p.Type).Infof("skip loading plugin %q...", id)
			} else {
				log.G(ctx).WithError(err).Warnf("failed to load plugin %s", id)
			}
			continue
		}
		// check for grpc services that should be registered with the server
		if service, ok := instance.(plugin.Service); ok {
			services = append(services, service)
		}
		s.plugins = append(s.plugins, result)
	}
	// 执行各个组件的grpc服务注册，比如containers组件，调用RegisterContainersServer函数
	// register services after all plugins have been initialized
	for _, service := range services {
		if err := service.Register(rpc); err != nil {
			return nil, err
		}
	}
	return s, nil
}
```

## container create

在[docker run](docker-run.md)的最后，docker daemon调用`/containerd.services.containers.v1.Containers/Create` Api，即`ContainersServer`接口的`Create`方法，其具体实现位于`/containerd/services/containers/service.go`中：

```go
type service struct {
	local api.ContainersClient
}

func (s *service) Create(ctx context.Context, req *api.CreateContainerRequest) (*api.CreateContainerResponse, error) {
	//local为grpc服务的客户端
	return s.local.Create(ctx, req)
}
```