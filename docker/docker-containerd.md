# containerd

Containerd 是一个工业级的容器运行时，和docker的关系可以看为：`docker->containerd->shim/runC`。docker通过调用containerd的grpc client接口拉起容器。

它强调简单性、健壮性和可移植性。containerd 可以在宿主机中管理完整的容器生命周期，包括：

- 管理容器的生命周期(从创建容器到销毁容器)
- 拉取/推送容器镜像
- 存储管理(管理镜像及容器数据的存储)
- 调用 runC 运行容器(与 runC 等容器运行时交互)
- 管理容器网络接口及网络

架构如![图1](../images/docker/docker-containerd.jpg)

Containerd仍然采用标准的C/S架构，服务端通过GRPC协议提供稳定的API，客户端**ctr组件**通过调用服务端的API进行高级的操作。

为了解耦，Containerd将不同的职责划分给不同的组件，每个组件就相当于一个**子系统（subsystem）**。连接不同子系统的组件被称为模块。总体上 Containerd 被划分为两个子系统：

- **Bundle** : 在 Containerd 中，Bundle包含了配置、元数据和根文件系统数据，你可以理解为容器的文件系统。而Bundle 子系统允许用户从镜像中提取和打包 Bundles。

- **Runtime** : Runtime 子系统用来执行 Bundles，比如创建容器。

## plugins

其中，每一个子系统的行为都由一个或多个模块协作完成（架构图中的Core部分）。每一种类型的模块都以插件的形式集成到 Containerd 中，而且插件之间是相互依赖的。

在架构图中，每一个长虚线的方框都表示**一种类型的插件集合**，包括 Service Plugin、Metadata Plugin、GC Plugin、Runtime Plugin ，其中 Service Plugin又会依赖Metadata Plugin、GC Plugin和 Runtime Plugin。

每一个小方框都表示一个细分的插件，例如 Metadata Plugin 依赖Containers Plugin、Content Plugin 等。

常见插件有：

- **Content Plugin**:提供对镜像中可寻址内容的访问，所有不可变的内容都被存储在这里。

- **Snapshot Plugin**:用来管理容器镜像的文件系统快照。镜像中的每一个layer都会被解压成文件系统快照，类似于Docker中的 graphdriver。

- **Metrics**:暴露各个组件的监控指标。

Containerd被分为三个大块：Storage、Metadata和Runtime，可以将上面的架构图提炼一下：

![图2](../images/docker/docker-containerd-plugin.jpg)

[参考](https://blog.bwcxtech.com/posts/24a5cd7/)

## containerd & docker & k8s

- dockerd启动时会启动containerd子进程，dockerd与containerd通过rpc进行通信
- ctr是containerd的cli, containerd通过shim操作runc，runc真正控制容器生命周期
- 启动一个容器就会启动一个shim进程
- shim直接调用runc的包函数,shim与containerd之前通过rpc通信

因此存在以下路径：
```
 docker cli -> docker daemon -> containerd -> containerd-shim -> runC
```

由于containerd包含了拉起容器的所有功能，因此，在k8s中拉起pod内的容器时，存在以下路径：
```
1. k8s集成docker：k8s->kubelete->docker-shim->docker api->docker-daemon->containerd->containerd-shim->oci/runC
2. k8s绕过docker:  k8s->kubelete->containerd->containerd-shim->oci/runC
```
目前正朝路径2进行技术演进。containerd 被设计成嵌入到一个更大的系统中，而不是直接由开发人员或终端用户使用。

使用containerd API拉取镜像并创建redis容器，可[移步](https://containerd.io/docs/getting-started/)

containerd的namespaces、client options可[移步](https://github.com/containerd/containerd/blob/master/README.md)

## grpc service define

以下内容基于containerd [!v1.2](https://github.com/containerd/containerd/tree/release/1.2) 版本

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
相应的，生成的go文件`containers.pb.go`中，该服务被描述为`ContainersServer`接口。注册该服务的方法`RegisterContainersServer`在`/containerd/cmd/main.go`的`command.App()`中被调用
```go
func App() *cli.App {
...
server, err := server.New(ctx, config)
...
}

// New creates and initializes a new containerd server
func New(ctx context.Context, config *srvconfig.Config) (*Server, error) {
	...
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

## mian & plugin

main函数位于`cmd/containerd/main.go`
```go
func main() {
	//创建app对象
	app := command.App()
	if err := app.Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "containerd: %s\n", err)
		os.Exit(1)
	}
}

//
func App() *cli.App {
	app := cli.NewApp()
	app.Name = "containerd"
	app.Version = version.Version
	app.Usage = usage
	app.Description = \`****\`
	app.Flags = []cli.Flag{
		cli.StringFlag{
			Name:  "config,c",
			Usage: "path to the configuration file",
			Value: defaultConfigPath,
		},
		//各种flag设置
		...
	}
	app.Flags = append(app.Flags, serviceFlags()...)
	//三个子命令
	app.Commands = []cli.Command{
		//用于生成配置文件，默认文件路径在/etc/containerd/config.toml
		configCommand,
		publishCommand,
		ociHook,
	}
```
其中的config.toml内容默认为：
```
disabled_plugins = ["cri"]

#root = "/var/lib/containerd"
#state = "/run/containerd"
#subreaper = true
#oom_score = 0

#[grpc]
#  address = "/run/containerd/containerd.sock"
#  uid = 0
#  gid = 0

#[debug]
#  address = "/run/containerd/debug.sock"
#  uid = 0
#  gid = 0
#  level = "info"
```
继续看app的action设置：
```go
	//在mian函数的app.Run(os.Args)中被调用执行
	app.Action = func(context *cli.Context) error {
		var (
			start   = time.Now()
			signals = make(chan os.Signal, 2048)
			serverC = make(chan *server.Server, 1)
			ctx     = gocontext.Background()
			config  = defaultConfig()
		)
		//从指定路径（context.GlobalString("config")）加载containerd server的配置，返回config对象
		if err := srvconfig.LoadConfig(context.GlobalString("config"), config); err != nil && !os.IsNotExist(err) {
			return err
		}

		// Apply flags to the config，将指定的flag覆盖上一步的config对象相应字段
		if err := applyFlags(context, config); err != nil {
			return err
		}
		
		...
		// cleanup temp mounts
		...
		// config中的grpc
		address := config.GRPC.Address
		if address == "" {
			return errors.New("grpc address cannot be empty")
		}
		...
```
以上部分相当于对config内容的check和一些初始化操作，接下来创建containerd server对象，该对象代表了一个containerd daemon：
```go
	server, err := server.New(ctx, config)
	if err != nil {
		return err
	}
//进入New函数	
func New(ctx context.Context, config *srvconfig.Config) (*Server, error) {
	//config的route/state属性检查
	...
	//根据config描述，创建root/state目录
	...
	//加载plugins对象
	plugins, err := LoadPlugins(ctx, config)
```
这里重点关注`loadPlugins`函数，该函数
1. 首先从config的root目录茜load插件，load的插件以及方式为[golang 插件](https://draveness.me/golang/docs/part4-advanced/ch08-metaprogramming/golang-plugin/)。
2. 定义插件的Registration,其中包括了plugin类型/Id/初始化方法InitFn/个性化配置config。并向/plugin/plugin.go的全局变量register中注册插件，包括了content/metadata plugin等。
3. 返回Registration对象的数组，Registration对象数组用户后续的初始化工作。
```go
func LoadPlugins(ctx context.Context, config *srvconfig.Config) ([]*plugin.Registration, error) {
	// load all plugins into containerd
	// 从../root/plugins目录下load插件
	if err := plugin.Load(filepath.Join(config.Root, "plugins")); err != nil {
		return nil, err
	}
	// load additional plugins that don't automatically register themselves
	// 注册内置插件
	// 除了此处在main.go中执行的插件注册，在各个具体的业务包中也通过init()进行了插件注册
	// 比如/containerd/services/containers/local.go中的init()注册了插件"containers-service"
	plugin.Register(&plugin.Registration{
		Type: plugin.ContentPlugin,
		ID:   "content",
		//定义后续调用的init函数
		InitFn: func(ic *plugin.InitContext) (interface{}, error) {
			ic.Meta.Exports["root"] = ic.Root
			//在宿主机创建目录/var/lib/containerd/io.containerd.content.v1.content/ingest，其中io.containerd.content.v1.content为plugin type
			return local.NewStore(ic.Root)
		},
	})
	plugin.Register(&plugin.Registration{
		Type: plugin.MetadataPlugin,
		ID:   "bolt",
		//依赖插件
		Requires: []plugin.Type{
			plugin.ContentPlugin,
			plugin.SnapshotPlugin,
		},
		InitFn: func(ic *plugin.InitContext) (interface{}, error) {
			//首先从initContext获取依赖插
			//在目录/var/lib/containerd/io.containerd.metadata.v1.bolt创建meta.db文件
			//返回一个数组存储对象
			...
		},
	})
	//使用grpc进行通信的plugin注册
	clients := &proxyClients{}
	for name, pp := range config.ProxyPlugins {
		var (
			t plugin.Type
			f func(*grpc.ClientConn) interface{}

			address = pp.Address
		)
		switch pp.Type {
		case string(plugin.SnapshotPlugin), "snapshot":
			t = plugin.SnapshotPlugin
			ssname := name
			f = func(conn *grpc.ClientConn) interface{} {
				return ssproxy.NewSnapshotter(ssapi.NewSnapshotsClient(conn), ssname)
			}

		case string(plugin.ContentPlugin), "content":
			t = plugin.ContentPlugin
			f = func(conn *grpc.ClientConn) interface{} {
				return csproxy.NewContentStore(csapi.NewContentClient(conn))
			}
		default:
			log.G(ctx).WithField("type", pp.Type).Warn("unknown proxy plugin type")
		}

		plugin.Register(&plugin.Registration{
			Type: t,
			ID:   name,
			InitFn: func(ic *plugin.InitContext) (interface{}, error) {
				ic.Meta.Exports["address"] = address
				conn, err := clients.getClient(address)
				if err != nil {
					return nil, err
				}
				return f(conn), nil
			},
		})

	}

	// return the ordered graph for plugins
	// 返回的插件列表中剔除了config.DisabledPlugins中的配置项
	return plugin.Graph(config.DisabledPlugins), nil
}
```
继续回到server的New：
```go
	...
	//创建grpc服务
	serverOpts := []grpc.ServerOption{
		grpc.UnaryInterceptor(grpc_prometheus.UnaryServerInterceptor),
		grpc.StreamInterceptor(grpc_prometheus.StreamServerInterceptor),
	}
	...
	rpc := grpc.NewServer(serverOpts...)
	...
	//声明containerd server对象
	var (
		services []plugin.Service
		s        = &Server{
			rpc:    rpc,
			//事件处理
			events: exchange.NewExchange(),
			config: config,
		}
		//创建一个记录已加载的plugin的集合
		initialized = plugin.NewPluginSet()
	)
	//遍历刚才注册的所有plugins
	for _, p := range plugins {
		id := p.URI()
		...
		//初始化initContext，initContext表示在plugin初始化过程中需要用到的context，该对象作为plugin调用InitFn的入参
		initContext := plugin.NewContext(
			ctx,
			p,
			initialized,
			config.Root,
			config.State,
		)
		//每一个plugin共享同一个全局的事件处理s.events，具体events的最后后文介绍
		initContext.Events = s.events
		initContext.Address = config.GRPC.Address
		//load the plugin specific configuration if it is provided
		//load plugin的自定义config配置
		if p.Config != nil {
			pluginConfig, err := config.Decode(p.ID, p.Config)
			...
			initContext.Config = pluginConfig
		}
		//调用Registration的InitFn方法。在之前的代码中，每个注册的plugin都定义了该接口
		result := p.Init(initContext)
		//加入全局的已初始化plugin集合
		if err := initialized.Add(result); err != nil {
			return nil, errors.Wrapf(err, "could not add plugin result to plugin set")
		}
		instance, err := result.Instance()
		...
		//如果这个plugin实现了Service接口，说明提供了grpc服务，加入服务集合services，并在之后注册服务
		// check for grpc services that should be registered with the server
		if service, ok := instance.(plugin.Service); ok {
			services = append(services, service)
		}
		s.plugins = append(s.plugins, result)
	}
	// register services after all plugins have been initialized
	// 逐个注册grpc服务
	for _, service := range services {
		if err := service.Register(rpc); err != nil {
			return nil, err
		}
	}
	return s, nil
}
				
```
至此，server的创建工作完成，返回server对象并回到main.go的App()中:
```go
		...
		serverC <- server
		//debug地址配置，默认本地/run/containerd/debug.sock
		if config.Debug.Address != "" {
			var l net.Listener
			if filepath.IsAbs(config.Debug.Address) {
				if l, err = sys.GetLocalListener(config.Debug.Address, config.Debug.UID, config.Debug.GID); err != nil {
					return errors.Wrapf(err, "failed to get listener for debug endpoint")
				}
			} else {
				if l, err = net.Listen("tcp", config.Debug.Address); err != nil {
					return errors.Wrapf(err, "failed to get listener for debug endpoint")
				}
			}
			serve(ctx, l, server.ServeDebug)
		}
		//监控监听
		if config.Metrics.Address != "" {
			l, err := net.Listen("tcp", config.Metrics.Address)
			if err != nil {
				return errors.Wrapf(err, "failed to get listener for metrics endpoint")
			}
			serve(ctx, l, server.ServeMetrics)
		}
		//拉起服务，本地注册api
		//创建unix的sock文件，位于/run/containerd/containerd.sock
		l, err := sys.GetLocalListener(address, config.GRPC.UID, config.GRPC.GID)
		...
		//提供grpc服务的api
		serve(ctx, l, server.ServeGRPC)
		<-done
		return nil
	}
	return app
}
```
以上是main函数的大致过程，其中比较重要的是plugin的处理。

## plugin example

## container create

在[docker run](docker-run.md)的最后，docker daemon调用`/containerd.services.containers.v1.Containers/Create` Api，即`ContainersServer`接口的`Create`方法，其具体实现位于`/containerd/services/containers/service.go`中：

```go
type service struct {
	local api.ContainersClient
}

func (s *service) Create(ctx context.Context, req *api.CreateContainerRequest) (*api.CreateContainerResponse, error) {
	//local为grpc服务的客户端，实现了ContainersClient接口
	return s.local.Create(ctx, req)
}
```
具体实现如下，其调用过程为：
```go
func (l *local) Create(ctx context.Context, req *api.CreateContainerRequest, _ ...grpc.CallOption) (*api.CreateContainerResponse, error) {
	var resp api.CreateContainerResponse
	//定义核心的container处理逻辑，该逻辑作为函数变量最终被withStoreUpdate调用
	if err := l.withStoreUpdate(ctx, func(ctx context.Context) error {
		//接收请求，封装containerd自定义container对象
		container := containerFromProto(&req.Container)
		//创建
		created, err := l.Store.Create(ctx, container)
		if err != nil {
			return err
		}
		//返回
		resp.Container = containerToProto(&created)
		return nil
	}); err != nil {
		return &resp, errdefs.ToGRPC(err)
	}
	//发布
	if err := l.publisher.Publish(ctx, "/containers/create", &eventstypes.ContainerCreate{
		ID:    resp.Container.ID,
		Image: resp.Container.Image,
		Runtime: &eventstypes.ContainerCreate_Runtime{
			Name:    resp.Container.Runtime.Name,
			Options: resp.Container.Runtime.Options,
		},
	}); err != nil {
		return &resp, err
	}

	return &resp, nil
}
####################################################################################################
//实际的执行时机，调用db的update，起事务执行
func (l *local) withStoreUpdate(ctx context.Context, fn func(ctx context.Context, store containers.Store) error) error {
	return l.db.Update(l.withStore(ctx, fn))
}
func (m *DB) Update(fn func(*bolt.Tx) error) error {
	m.wlock.RLock()
	defer m.wlock.RUnlock()
	err := m.db.Update(fn)
	if err == nil {
		m.dirtyL.Lock()
		dirty := m.dirtyCS || len(m.dirtySS) > 0
		for _, fn := range m.mutationCallbacks {
			fn(dirty)
		}
		m.dirtyL.Unlock()
	}

	return err
}
####################################################################################################
//将事务封装进containerStore对象，并调用Create中定义的函数变量fn。同样的，这个调用过程也被定义为一个函数变量并返回
func (l *local) withStore(ctx context.Context, fn func(ctx context.Context, store containers.Store) error) func(tx *bolt.Tx) error {
	return func(tx *bolt.Tx) error { return fn(ctx, metadata.NewContainerStore(tx)) }
}
```
上面的调用本质上是开启一个事务，将事务对象封装至containerStore对象，最后调用指定对象的创建方法。具体顺序为：
```
在最外层Create调用withStoreUpdate->调用Update开启事务->调用withStore封装containerStore->调最外层withStoreUpdate的第函数变量参数执行最终的create
```
进入`containerStore`的Create函数内部：
```go
func (s *containerStore) Create(ctx context.Context, container containers.Container) (containers.Container, error) {
	namespace, err := namespaces.NamespaceRequired(ctx)
	...
	//check
	if err := validateContainer(&container); err != nil {
		return containers.Container{}, errors.Wrap(err, "create container failed validation")
	}
	//写db
	bkt, err := createContainersBucket(s.tx, namespace)
	if err != nil {
		return containers.Container{}, err
	}
	cbkt, err := bkt.CreateBucket([]byte(container.ID))
	...
	container.CreatedAt = time.Now().UTC()
	container.UpdatedAt = container.CreatedAt
	if err := writeContainer(cbkt, &container); err != nil {
		return containers.Container{}, errors.Wrapf(err, "failed to write container %q", container.ID)
	}
	return container, nil
}
```

## go-events
参考
1. [go-events](https://www.debug8.com/golang/t_59481.html) 
2. [go-events-git](https://github.com/docker/go-events)

go-event是一个在Docker项目中使用到的一个事件分发组件，实现了常规的广播，队列等事件分发模型。

### 核心接口

1. **Event**
```go
type Event interface{}

//定义一个event
msg := msg{Id:"1",Name:"jiao",Sex:"Male"}
```
Event被描述为一个空接口，接受任意类型。在go-events表示一个可以被执行的事件。比如定义了一个名为msg的event。

2. **Sink**
```go
type Sink interface {
	//事件的执行策略
    Write(event Event) error
	//sink关闭策略
    Close() error
}

//定义一个http的sink
type httpSink struct {
	url string
	client http.Client
}

func NewHttpSink(url string)event.Sink{
	return &httpSink{url:url,client:http.Client{}}
}
//write方法执行的是http请求的发送
func (h *httpSink) Write(event event.Event) error {
	p, err := json.Marshal(event)
	if err != nil {
		return err
	}
	body := bytes.NewReader(p)
	resp, err := h.client.Post(h.url, "application/json", body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return errors.New("unexpected status")
	}

	return nil
}
//close方法
func (h *httpSink) Close()error{
	return nil
}
```
Sink用来执行事件（Event），只要对象实现了这两个方法，就可以被当作一个Sink。

### retry & queue & broadcast

1. **retry**
retry顾名思义，即重试。其作用为在一定时间间隔(backoff)内，对sink执行N次(threshold)的尝试，直到成功为止。
```go
//breaker定义
type Breaker struct {
	threshold int			//重试阈值
	recent    int			//重试次数
	last      time.Time		//上一次write时间
	backoff   time.Duration // time after which we retry after failure.	时间间隔
	mu        sync.Mutex	
}
	//定义一个retry对象，其中event.NewBreaker(5, time.Second)返回了一个breaker对象
	//5表示重试的阈值，time.Second*5表示时间间隔5秒
	//因此，该breaker表示在5秒内尝试调用sink的write方法5次，如果都失败，下一轮5秒再尝试	
	retry := event.NewRetryingSink(sink,event.NewBreaker(5, time.Second*5))
	if err := retry.Write(msg);err!=nil{
		t.Error(err)
	}
```
可以看下retry的内部实现：
```
// Write attempts to flush the events to the downstream sink until it succeeds
// or the sink is closed.
func (rs *RetryingSink) Write(event Event) error {
//1. 判断retry是否关闭，关闭则退出
	...
retry:
	select {
	case <-rs.closed:
		return ErrSinkClosed
	default:
	}
	//2.proceed更新在时间段内的重试次数
	//	如果重试次数小于阈值，则次数+1，backoff = 0
	//	否则，说明在时间间隔内，已经尝试了N次，返回backoff = 上一次调write时间+时间间隔-当前时间
	//	backoff即距离下一次启动retry的时间差
	if backoff := rs.strategy.Proceed(event); backoff > 0 {
		select {
		//如果backoff大于0，说明离下一轮尝试还有backoff时间，因此after
		case <-time.After(backoff):
			// TODO(stevvooe): This branch holds up the next try. Before, we
			// would simply break to the "retry" label and then possibly wait
			// again. However, this requires all retry strategies to have a
			// large probability of probing the sync for success, rather than
			// just backing off and sending the request.
		case <-rs.closed:
			return ErrSinkClosed
		}
	}
	//3.执行sink的写
	if err := rs.sink.Write(event); err != nil {
		
		if err == ErrSinkClosed {
			// terminal!
			return err
		}
		//写入失败，则记日志，更新write调用时间，尝试次数+1
		logger := logger.WithError(err) // shadow!!
		if rs.strategy.Failure(event, err) {
			...
		}
		//返回步骤1
		...
		goto retry
	}
	//4.成功后，清空尝试次数，更新write调用时间，返回
	rs.strategy.Success(event)
	return nil
}
```

2. **queue**
queue返回一个队列，入参的sink对象会依次指定放入queue中的event：
```go
type Queue struct {
	dst    Sink			//sink执行
	events *list.List	//event双向链表，FILO
	cond   *sync.Cond	//条件锁，内部引用全局mutex lock
	mu     sync.Mutex	//全局mutex lock
	closed bool			
}

//在New函数中，直接执行一个run()，维护queue状态
// run is the main goroutine to flush events to the target sink.
func (eq *Queue) run() {
	for {
		//获取第一个event
		//如果链表为空，并且queue关闭，则broadcast条件锁，eq.cond.Broadcast()
		//否则，条件锁等待，eq.cond.Wait()，等待新的event入队
		event := eq.next()
		..
		//sink write event
		if err := eq.dst.Write(event); err != nil {
			// TODO(aaronl): Dropping events could be bad depending
			// on the application. We should have a way of
			// communicating this condition. However, logging
			// at a log level above debug may not be appropriate.
			// Eventually, go-events should not use logrus at all,
			// and should bubble up conditions like this through
			// error values.
			logrus.WithFields(logrus.Fields{
				"event": event,
				"sink":  eq.dst,
			}).WithError(err).Debug("eventqueue: dropped event")
		}
	}
}

// queue的Write操作即把event入链表
// Write accepts the events into the queue, only failing if the queue has
// been closed.
func (eq *Queue) Write(event Event) error {
	eq.mu.Lock()
	defer eq.mu.Unlock()
	
	if eq.closed {
		return ErrSinkClosed
	}
	//入链表尾
	eq.events.PushBack(event)
	//入队后，链表不为空，通知在等待的event执行write
	eq.cond.Signal() // signal waiters

	return nil
}
```

3. **broadcast**
广播消息，将接收到的event分发给所有注册的sink去执行。首先看broadcast定义以及New函数：
```go
//定义
// Broadcaster sends events to multiple, reliable Sinks. The goal of this
// component is to dispatch events to configured endpoints. Reliability can be
// provided by wrapping incoming sinks.
type Broadcaster struct {
	sinks   []Sink					//sink组，event将会给所有注册的sink去执行
	events  chan Event				//event队列
	adds    chan configureRequest	//同步channel，执行add和remove
	removes chan configureRequest

	shutdown chan struct{}			
	closed   chan struct{}
	once     sync.Once
}
//New函数中开启线程执行run
func NewBroadcaster(sinks ...Sink) *Broadcaster {
	b := Broadcaster{
		sinks:    sinks,
		events:   make(chan Event),
		adds:     make(chan configureRequest),
		removes:  make(chan configureRequest),
		shutdown: make(chan struct{}),
		closed:   make(chan struct{}),
	}

	// Start the broadcaster
	go b.run()

	return &b
}
// run is the main broadcast loop, started when the broadcaster is created.
// Under normal conditions, it waits for events on the event channel. After
// Close is called, this goroutine will exit.
func (b *Broadcaster) run() {
	defer close(b.closed)
	//封装remove，移除sink，注意，sink要实现comparable才能使用sink == target
	remove := func(target Sink) {
		for i, sink := range b.sinks {
			if sink == target {
				b.sinks = append(b.sinks[:i], b.sinks[i+1:]...)
				break
			}
		}
	}
	
	for {
		select {
		//有event到来，遍历sink消费
		case event := <-b.events:
			for _, sink := range b.sinks {
				if err := sink.Write(event); err != nil {
					if err == ErrSinkClosed {
						// remove closed sinks
						remove(sink)
						continue
					}
					logrus.WithField("event", event).WithField("events.sink", sink).WithError(err).
						Errorf("broadcaster: dropping event")
				}
			}
		//如果有新的sink加入
		case request := <-b.adds:
			//判断sink是否存在
			var found bool
			for _, sink := range b.sinks {
				if request.sink == sink {
					found = true
					break
				}
			}
			//加入sink列表
			if !found {
				b.sinks = append(b.sinks, request.sink)
			}
			//回写request的resp channel
			request.response <- nil
		//与上一个case同理
		case request := <-b.removes:
			remove(request.sink)
			request.response <- nil
		//如果broadcast关闭，通知所有sink的close
		case <-b.shutdown:
			// close all the underlying sinks
			for _, sink := range b.sinks {
				if err := sink.Close(); err != nil && err != ErrSinkClosed {
					logrus.WithField("events.sink", sink).WithError(err).
						Errorf("broadcaster: closing sink failed")
				}
			}
			return
		}
	}
}
```
4个case支撑了整个broadcast的业务场景，继续看boardcast的add操作：
```go
// Add the sink to the broadcaster.
// The provided sink must be comparable with equality. Typically, this just
// works with a regular pointer type.
// 增加执行sink
func (b *Broadcaster) Add(sink Sink) error {
	return b.configure(b.adds, sink)
}
func (b *Broadcaster) configure(ch chan configureRequest, sink Sink) error {
	response := make(chan error, 1)
	for {
		//向configRequest channel中写入sink以及一个容量为1的resp chan
		select {
		case ch <- configureRequest{
			sink:     sink,
			response: response}:
			ch = nil
		//当run()中configureRequest被读取并添加sink后，向response写入，执行此case
		case err := <-response:
			return err
		case <-b.closed:
			return ErrSinkClosed
		}
	}
}
```
再继续看write操作：
```go
// Write accepts an event to be dispatched to all sinks. This method will never
// fail and should never block (hopefully!). The caller cedes the memory to the
// broadcaster and should not modify it after calling write.
func (b *Broadcaster) Write(event Event) error {
	//向b.events channel写入event，剩下的在run()中进行
	select {
	case b.events <- event:
	case <-b.closed:
		return ErrSinkClosed
	}
	return nil
}
```

## create event handle

继续回到`service.go的Create`函数:
```go
func (s *service) Create(ctx context.Context, req *api.CreateContainerRequest) (*api.CreateContainerResponse, error) {
	//local为grpc服务的客户端，实现了ContainersClient接口
	return s.local.Create(ctx, req)
}

func (l *local) Create(ctx context.Context, req *api.CreateContainerRequest, _ ...grpc.CallOption) (*api.CreateContainerResponse, error) {
	var resp api.CreateContainerResponse
	//定义核心的container处理逻辑，该逻辑作为函数变量最终被withStoreUpdate调用
	...
	//发布
	if err := l.publisher.Publish(ctx, "/containers/create", &eventstypes.ContainerCreate{
		ID:    resp.Container.ID,
		Image: resp.Container.Image,
		Runtime: &eventstypes.ContainerCreate_Runtime{
			Name:    resp.Container.Runtime.Name,
			Options: resp.Container.Runtime.Options,
		},
	}); err != nil {
		return &resp, err
	}
	return &resp, nil
}
```
可以看到在执行了etcd的create container db操作后，调用service对象的publisher进行了一个发布调用，那么：
1. 这个publisher是如何定义的？
2. Publish操作到底做了什么？
首先看local中publisher的定义:
```go
//local
type local struct {
	db        *metadata.DB
	//events.Publisher接口
	publisher events.Publisher
}
//Publish接口
type Publisher interface {
	//create场景中，topic即/containers/create，event为封装的containerId/imageId等信息
	Publish(ctx context.Context, topic string, event Event) error
}
```
这个接口在`/containerd/services/containers/local.go`的`init()`中被初始化，这个函数注册了**container-service插件**：
```go
func init() {
	plugin.Register(&plugin.Registration{
		Type: plugin.ServicePlugin,
		ID:   services.ContainersService,
		Requires: []plugin.Type{
			plugin.MetadataPlugin,
		},
		InitFn: func(ic *plugin.InitContext) (interface{}, error) {
			m, err := ic.Get(plugin.MetadataPlugin)
			...
			return &local{
				db:        m.(*metadata.DB),
				//publisher的值为ic.Events，即initContext的events字段
				publisher: ic.Events,
			}, nil
		},
	})
}
```
可以看到具体对象来自initContext，回顾之前对main的分析。在main中，loadPlugin后，初始化了initContext，遍历每一个plugin，调用其initFunction：
```go
//创建server对象
var s    = &Server{
			rpc:    rpc,
			events: exchange.NewExchange(),
			config: config,
		}
...省略
//load后逐一init
for _, p := range plugins {
		...
		initContext := plugin.NewContext(
			ctx,
			p,
			initialized,
			config.Root,
			config.State,
		)
		initContext.Events = s.events
		initContext.Address = config.GRPC.Address
		...
		result := p.Init(initContext)
		...
	}
...
##############################################
type Exchange struct {
	//上一节中go-events的Broadcaster
	broadcaster *goevents.Broadcaster
}

```
最终可以看到`local.publisher`其实就是被Exchange封装了的boardcast。因此看Exchange的Publish函数：
```go
// Publish packages and sends an event. The caller will be considered the
// initial publisher of the event. This means the timestamp will be calculated
// at this point and this method may read from the calling context.
func (e *Exchange) Publish(ctx context.Context, topic string, event events.Event) (err error) {
	var (
		namespace string
		encoded   *types.Any
		envelope  events.Envelope
	)
	//namespace
	namespace, err = namespaces.NamespaceRequired(ctx)
	...
	//topic check
	if err := validateTopic(topic); err != nil {
		return errors.Wrapf(err, "envelope topic %q", topic)
	}
	//event编码
	encoded, err = typeurl.MarshalAny(event)
	...
	envelope.Timestamp = time.Now().UTC()
	envelope.Namespace = namespace
	envelope.Topic = topic
	envelope.Event = encoded
	defer ...
	//广播事件，根据上节，这个eventlope将会被e.broadcast中所有的sink执行
	return e.broadcaster.Write(&envelope)
}
```
那么，sink在何时被add进e.broadcast中的？
```go
// Subscribe to events on the exchange. Events are sent through the returned
// channel ch. If an error is encountered, it will be sent on channel errs and
// errs will be closed. To end the subscription, cancel the provided context.
//
// Zero or more filters may be provided as strings. Only events that match
// *any* of the provided filters will be sent on the channel. The filters use
// the standard containerd filters package syntax.
func (e *Exchange) Subscribe(ctx context.Context, fs ...string) (ch <-chan *events.Envelope, errs <-chan error) {
	var (
		evch                  = make(chan *events.Envelope)
		errq                  = make(chan error, 1)
		//go-events的NewChannel返回一个封装的chanel，并实现了sink接口（write即写入channel），0即channel容量，
		channel               = goevents.NewChannel(0)
		//queue见上文
		queue                 = goevents.NewQueue(channel)
		dst     goevents.Sink = queue
	)

	closeAll := func() {
		defer close(errq)
		defer e.broadcaster.Remove(dst)
		defer queue.Close()
		defer channel.Close()
	}
	//evch即为返回的channel
	ch = evch
	errs = errq
	//如果存在过滤，则只有满足条件的events可以入队
	if len(fs) > 0 {
		filter, err := filters.ParseAll(fs...)
		if err != nil {
			errq <- errors.Wrapf(err, "failed parsing subscription filters")
			closeAll()
			return
		}

		dst = goevents.NewFilter(queue, goevents.MatcherFunc(func(gev goevents.Event) bool {
			return filter.Match(adapt(gev))
		}))
	}
	//将sink加入broadcast
	e.broadcaster.Add(dst)
	//然后启动一个协程，去监听sink(channel)的write
	//因为sink的具体实现为channel
	go func() {
		defer closeAll()

		var err error
	loop:
		for {
			select {
			//如果封装的channel sink的write被调用，即向channel.C中写入
			case ev := <-channel.C:
				//读取event
				env, ok := ev.(*events.Envelope)
				if !ok {
					// TODO(stevvooe): For the most part, we are well protected
					// from this condition. Both Forward and Publish protect
					// from this.
					err = errors.Errorf("invalid envelope encountered %#v; please file a bug", ev)
					break
				}
				//把事件写入返回的channel中
				select {
				case evch <- env:
				case <-ctx.Done():
					break loop
				}
			case <-ctx.Done():
				break loop
			}
		}
		//如果err不为空，把err写入err channel
		if err == nil {
			if cerr := ctx.Err(); cerr != context.Canceled {
				err = cerr
			}
		}

		errq <- err
	}()

	return
}
```
事件订阅的总体逻辑就是，向broadcast中**添加**一个channel sink，如果参数中声明了过滤器，则封装channel sink，提供事件过滤功能。

每当发生广播，根据broadcast的机制，将调用添加的sink的write接口，即channel sink向channel.C中写events。此时，订阅函数中的协程将可以实时读取写入的事件，并将事件写入返回的event channel中，供函数调用者读取。
