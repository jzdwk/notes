# docker run 

## client

当执行`docker run`命令，会执行`.../docker-ce/components/cli/cli/command/container/run.go`中的`func NewRunCommand(dockerCli command.Cli)`,主要看`runRun`函数:
```go
//docker run 后携带的命令主要分为了runOptinos和containerOptions
func runRun(dockerCli command.Cli, flags *pflag.FlagSet, ropts *runOptions, copts *containerOptions) error {
	//解析从终端输入的config options，这里面的config主要有
	//config ：独立于宿主机的配置信息，其内容如果用户没有指定，将默认来自于/var/lib/docker/image/overlay2/imagedb/content/sha256{iamgeID}中的config段落。比如hostname，user;默认omitempty设置，如果为空置则忽略字段。
    //hostConfig ： 与主机相关的配置，即容器与主机之间的端口映射、日志、volume等等
    //networkingConfig ：容器网络相关的配置。
	containerConfig, err := parse(flags, copts, dockerCli.ServerInfo().OSType)
	...
	//验证api
	if err = validateAPIVersion(containerConfig, dockerCli.Client().ClientVersion()); err != nil {
		...
	}
	return runContainer(dockerCli, ropts, copts, containerConfig)
}
```
上述代码中的opt解析细节暂时不关注，继续:
```go
// nolint: gocyclo
func runContainer(dockerCli command.Cli, opts *runOptions, copts *containerOptions, containerConfig *containerConfig) error {
	...
	createResponse, err := createContainer(ctx, dockerCli, containerConfig, &opts.createOptions)
	...
	// start the container
	if err := client.ContainerStart(ctx, createResponse.ID, types.ContainerStartOptions{}); err != nil {
		...
	}
	... 
	return nil
}
```
这里最关键的就是`createContainer`和`ContainerStart`，也就是说，docker run将分为**create**和**start**两个阶段去做。首先看create的过程：
```go
func createContainer(ctx context.Context, dockerCli command.Cli, containerConfig *containerConfig, opts *createOptions) (*container.ContainerCreateCreatedBody, error) {
	...
	//通过创建一个containerID的文件，检测该containerID是否在运行,这个id即来自前文的config
	containerIDFile, err := newCIDFile(hostConfig.ContainerIDFile)
	...
	ref, err := reference.ParseAnyReference(config.Image)
	...
	//docker trust相关的image验签，详细的docker trust可以参考文档https://docs.docker.com/engine/security/trust/content_trust/
	if named, ok := ref.(reference.Named); ok {
		namedRef = reference.TagNameOnly(named)
		if taggedRef, ok := namedRef.(reference.NamedTagged); ok && !opts.untrusted {
			var err error
			trustedRef, err = image.TrustedReference(ctx, dockerCli, taggedRef, nil)
			...
			config.Image = reference.FamiliarString(trustedRef)
		}
	}
	//定义image pull，如果本地没有run指定的image，则先pull，再create
	pullAndTagImage := func() error {
		if err := pullImage(ctx, dockerCli, config.Image, opts.platform, stderr); err != nil {
			return err
		}
		if taggedRef, ok := namedRef.(reference.NamedTagged); ok && trustedRef != nil {
			return image.TagTrusted(ctx, dockerCli, trustedRef, taggedRef)
		}
		return nil
	}
	//always pull
	if opts.pull == PullImageAlways {
		if err := pullAndTagImage(); err != nil {
			return nil, err
		}
	}
	//创建容器
	response, err := dockerCli.Client().ContainerCreate(ctx, config, hostConfig, networkingConfig, opts.name)
	if err != nil {
		// Pull image if it does not exist locally and we have the PullImageMissing option. Default behavior.
		if apiclient.IsErrNotFound(err) && namedRef != nil && opts.pull == PullImageMissing {
			// we don't want to write to stdout anything apart from container.ID
			fmt.Fprintf(stderr, "Unable to find image '%s' locally\n", reference.FamiliarString(namedRef))
			if err := pullAndTagImage(); err != nil {
				return nil, err
			}
			var retryErr error
			//pull完了，create container
			response, retryErr = dockerCli.Client().ContainerCreate(ctx, config, hostConfig, networkingConfig, opts.name)
			...
		}...
	}
	...
	err = containerIDFile.Write(response.ID)
	return &response, err
}
```
在client端大致的过程就是先pull，再create。ContainerCreate在client端的实际工作就是向daemon发送一个path为`"/containers/create`的Post请求：
```go
func (cli *Client) ContainerCreate(ctx context.Context, config *container.Config, hostConfig *container.HostConfig, networkingConfig *network.NetworkingConfig, containerName string) (container.ContainerCreateCreatedBody, error) {
	var response container.ContainerCreateCreatedBody
	...
	query := url.Values{}
	if containerName != "" {
		query.Set("name", containerName)
	}
	//http body
	body := configWrapper{
		Config:           config,
		HostConfig:       hostConfig,
		NetworkingConfig: networkingConfig,
	}
	//do post
	serverResp, err := cli.post(ctx, "/containers/create", query, body, nil)
	defer ensureReaderClosed(serverResp)
	...
	err = json.NewDecoder(serverResp.body).Decode(&response)
	return response, err
}
```
daemon端的处理随后分析。ContainerCreate的返回中包含了Container的ID，因此，对于下一过程ContainerStart，其主要是向Daemon发送：
```go
	
	body := configWrapper{
		Config:           config,  //image config
		HostConfig:       hostConfig, //host config, 描述主机的端口、volume等数据
		NetworkingConfig: networkingConfig, //network 配置
	}
	serverResp, err := cli.post(ctx, "/containers/create", query, body, nil)
	defer ensureReaderClosed(serverResp)
	...
	return response, err
}
```
当container创建成功后，返回了`ContainerCreateCreatedBody`数据，其中最主要的就是container id,回到`runContainer`函数
```go
func runContainer(dockerCli command.Cli, opts *runOptions, copts *containerOptions, containerConfig *containerConfig) error {
    ...
	createResponse, err := createContainer(ctx, dockerCli, containerConfig, &opts.createOptions)
	...
	...
	if err := client.ContainerStart(ctx, createResponse.ID, types.ContainerStartOptions{}); err != nil {
		...
	}

	...
}
```
暂且不关系std相关的设置，进入`ContainerStart`函数，可以看到该函数发送了一个post请求，其中的containerID即刚才创建的container：
```go
// ContainerStart sends a request to the docker daemon to start a container.
func (cli *Client) ContainerStart(ctx context.Context, containerID string, options types.ContainerStartOptions) error {
	query := url.Values{}
	if len(options.CheckpointID) != 0 {
		query.Set("checkpoint", options.CheckpointID)
	}
	if len(options.CheckpointDir) != 0 {
		query.Set("checkpoint-dir", options.CheckpointDir)
	}
	resp, err := cli.post(ctx, "/containers/"+containerID+"/start", query, nil, nil)
	ensureReaderClosed(resp)
	return err
}
```

## daemon

daemon端的两个主要工作就是`createContainer`以及`ContainerStart`。和container相关的api操作定义如下,位于`/moby/api/server/router/container/container.go`：
```go
// initRoutes initializes the routes in container router
func (r *containerRouter) initRoutes() {
	r.routes = []router.Route{
		// HEAD
		router.NewHeadRoute("/containers/{name:.*}/archive", r.headContainersArchive),
		// GET
		router.NewGetRoute("/containers/json", r.getContainersJSON),
		router.NewGetRoute("/containers/{name:.*}/export", r.getContainersExport),
		router.NewGetRoute("/containers/{name:.*}/changes", r.getContainersChanges),
		router.NewGetRoute("/containers/{name:.*}/json", r.getContainersByName),
		router.NewGetRoute("/containers/{name:.*}/top", r.getContainersTop),
		router.NewGetRoute("/containers/{name:.*}/logs", r.getContainersLogs),
		router.NewGetRoute("/containers/{name:.*}/stats", r.getContainersStats),
		router.NewGetRoute("/containers/{name:.*}/attach/ws", r.wsContainersAttach),
		router.NewGetRoute("/exec/{id:.*}/json", r.getExecByID),
		router.NewGetRoute("/containers/{name:.*}/archive", r.getContainersArchive),
		// POST
		router.NewPostRoute("/containers/create", r.postContainersCreate),
		router.NewPostRoute("/containers/{name:.*}/kill", r.postContainersKill),
		router.NewPostRoute("/containers/{name:.*}/pause", r.postContainersPause),
		router.NewPostRoute("/containers/{name:.*}/unpause", r.postContainersUnpause),
		router.NewPostRoute("/containers/{name:.*}/restart", r.postContainersRestart),
		router.NewPostRoute("/containers/{name:.*}/start", r.postContainersStart),
		router.NewPostRoute("/containers/{name:.*}/stop", r.postContainersStop),
		router.NewPostRoute("/containers/{name:.*}/wait", r.postContainersWait),
		router.NewPostRoute("/containers/{name:.*}/resize", r.postContainersResize),
		router.NewPostRoute("/containers/{name:.*}/attach", r.postContainersAttach),
		router.NewPostRoute("/containers/{name:.*}/copy", r.postContainersCopy), // Deprecated since 1.8, Errors out since 1.12
		router.NewPostRoute("/containers/{name:.*}/exec", r.postContainerExecCreate),
		router.NewPostRoute("/exec/{name:.*}/start", r.postContainerExecStart),
		router.NewPostRoute("/exec/{name:.*}/resize", r.postContainerExecResize),
		router.NewPostRoute("/containers/{name:.*}/rename", r.postContainerRename),
		router.NewPostRoute("/containers/{name:.*}/update", r.postContainerUpdate),
		router.NewPostRoute("/containers/prune", r.postContainersPrune),
		router.NewPostRoute("/commit", r.postCommit),
		// PUT
		router.NewPutRoute("/containers/{name:.*}/archive", r.putContainersArchive),
		// DELETE
		router.NewDeleteRoute("/containers/{name:.*}", r.deleteContainers),
	}
}
```

### ContainerCreate

ContainerCreate的过程从本质上来说，就是将下载的只读的image和一个创建的读写的container layer进行union mount，从而构造容器的工作空间。

根据api定位执行函数`postContainersCreate`，该函数只是做了一些http参数的接收解析以及校验工作，之后调用了backend接口的:
```go
func (s *containerRouter) postContainersCreate(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	...
	//container name
	name := r.Form.Get("name")
    //container config
	config, hostConfig, networkingConfig, err := s.decoder.DecodeConfig(r.Body)
	...version check &&  config check
	ccr, err := s.backend.ContainerCreate(types.ContainerCreateConfig{
		Name:             name,  
		Config:           config,
		HostConfig:       hostConfig,
		NetworkingConfig: networkingConfig,
		AdjustCPUShares:  adjustCPUShares, //小于1.19版本支持
	})
	if err != nil {
		return err
	}
	return httputils.WriteJSON(w, http.StatusCreated, ccr)
}
```
其中`ContainerCreate`由`stateBackend`接口定义,并由`Daemon`结构实现(该结构体实现了所有的`Backend`接口，除了`stateBackend`,还有`execBackend/copyBackend/stateBackend/monitorBackend/attachBackend/systemBackend`,要提供一个标准的容器需实现以上接口)：
```go
// 位于/moby/api/server/router/container/backend.go
// Backend is all the methods that need to be implemented to provide container specific functionality.
type Backend interface {
	commitBackend
	execBackend
	copyBackend
	stateBackend
	monitorBackend
	attachBackend
	systemBackend
}
```
继续看`ContainerCreate`的实现：
```go
// ContainerCreate creates a regular container
//params即解析的post的各种配置
func (daemon *Daemon) ContainerCreate(params types.ContainerCreateConfig) (containertypes.ContainerCreateCreatedBody, error) {
	//进行一次封装，managed和ignoreImagesArgsEscaped置false
	return daemon.containerCreate(createOpts{
		params:                  params,
		managed:                 false,
		ignoreImagesArgsEscaped: false})
}

func (daemon *Daemon) containerCreate(opts createOpts) (containertypes.ContainerCreateCreatedBody, error) {
	start := time.Now()
	...config check
	os := runtime.GOOS
	if opts.params.Config.Image != "" {
		img, err := daemon.imageService.GetImage(opts.params.Config.Image)
		if err == nil {
			os = img.OS
		}
	} else {
		...
	}
	//验证config、host config配置
	warnings, err := daemon.verifyContainerSettings(os, opts.params.HostConfig, opts.params.Config, false)
	...
	//验证nerwork配置
	err = verifyNetworkingConfig(opts.params.NetworkingConfig)
	...
	if opts.params.HostConfig == nil {
		opts.params.HostConfig = &containertypes.HostConfig{}
	}
	// 调整一些配置，例如CPU如果超量了，就设置成系统允许的最大的。
	err = daemon.adaptContainerSettings(opts.params.HostConfig, opts.params.AdjustCPUShares)
	...
    //创建容器
	container, err := daemon.create(opts)
	containerActions.WithValues("create").UpdateSince(start)
	return containertypes.ContainerCreateCreatedBody{ID: container.ID, Warnings: warnings}, nil
}
```
以上逻辑也只是进行了config的check处理，继续看`daemon.create(opts)`，**该函数是实现创建容器的核心逻辑**:
```go
func (daemon *Daemon) create(opts createOpts) (retC *container.Container, retErr error){
	...
}
```

1. **config处理**，首先将container相关的config进行合并处理: 

```go
	os := runtime.GOOS
	//又get一遍image
	if opts.params.Config.Image != "" {
		img, err = daemon.imageService.GetImage(opts.params.Config.Image)
		...
	} ...
	
	// On WCOW, if are not being invoked by the builder to create this container (where
	// ignoreImagesArgEscaped will be true) - if the image already has its arguments escaped,
	// ensure that this is replicated across to the created container to avoid double-escaping
	// of the arguments/command line when the runtime attempts to run the container.
	if os == "windows" && !opts.ignoreImagesArgsEscaped && img != nil && img.RunConfig().ArgsEscaped {
		opts.params.Config.ArgsEscaped = true
	}
	//img中定义了默认的config配置，位于../docker/image/overlay2/imagedb/content/sha256/{iamgeID}中的config段落。将用户的自定义配置和默认配置合并
	if err := daemon.mergeAndVerifyConfig(opts.params.Config, img); err != nil {
		return nil, errdefs.InvalidParameter(err)
	}
    //同上，合并hostconfig的logconfig
	if err := daemon.mergeAndVerifyLogConfig(&opts.params.HostConfig.LogConfig); err != nil {
		return nil, errdefs.InvalidParameter(err)
	}
	...
```
2. **初始化container对象**
```go
	//newContainer只是进行了参数的封装，返回一个container对象
	if container, err = daemon.newContainer(opts.params.Name, os, opts.params.Config, opts.params.HostConfig, imgID, opts.managed); err != nil {
		return nil, err
	}
	...
	if err := daemon.setSecurityOptions(container, opts.params.HostConfig); err != nil {
		return nil, err
	}
	container.HostConfig.StorageOpt = opts.params.HostConfig.StorageOpt
```
以busybox容器运行后的hostconfig为例，文件位于/var/lib/docker/containers/{containers_id}/hostconfig.json，其内容为：
```json
{
  "Binds": [
    "/root/mnt:/home/mnt"   //因为run时指定了一个挂载，故在此Binds项中
  ],
  "ContainerIDFile": "",
  "LogConfig": {
    "Type": "json-file",
    "Config": {}
  },
  "NetworkMode": "default",
  "PortBindings": {},
  "RestartPolicy": {
    "Name": "no",
    "MaximumRetryCount": 0
  },
  "AutoRemove": false,
  "VolumeDriver": "",
  "VolumesFrom": null,
  ...
  "BlkioWeightDevice": [],
  "BlkioDeviceReadBps": null,
  "BlkioDeviceWriteBps": null,
  "BlkioDeviceReadIOps": null,
  "BlkioDeviceWriteIOps": null,
  "CpuPeriod": 0,
  "CpuQuota": 0,
  "CpuRealtimePeriod": 0,
  "CpuRealtimeRuntime": 0,
  "CpusetCpus": "",
  "CpusetMems": "",
  "Devices": [],
  "DeviceCgroupRules": null,
  "DiskQuota": 0,
  "KernelMemory": 0,
  "MemoryReservation": 0,
  "MemorySwap": 0,
  "MemorySwappiness": null,
  "OomKillDisable": false,
  "PidsLimit": 0,
  "Ulimits": null,
  "CpuCount": 0,
  "CpuPercent": 0,
  "IOMaximumIOps": 0,
  "IOMaximumBandwidth": 0,
  "MaskedPaths": [
    "/proc/asound",
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/proc/scsi",
    "/sys/firmware"
  ],
  "ReadonlyPaths": [
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger"
  ]
}
```
上述内容同样可以通过`docker inspect {containerId}`查看。继续进入`newContainer`函数可以看到，其首先是创建一个container对象，
```go
func (daemon *Daemon) newContainer(name string, operatingSystem string, config *containertypes.Config, hostConfig *containertypes.HostConfig, imgID image.ID, managed bool) (*container.Container, error) {
	var (
		id             string
		err            error
		noExplicitName = name == ""
	)
	id, name, err = daemon.generateIDAndName(name)
	...

	if hostConfig.NetworkMode.IsHost() {
		if config.Hostname == "" {
			config.Hostname, err = os.Hostname()
			if err != nil {
				return nil, errdefs.System(err)
			}
		}
	} else {
		daemon.generateHostname(id, config)
	}
	entrypoint, args := daemon.getEntrypointAndArgs(config.Entrypoint, config.Cmd)

	base := daemon.newBaseContainer(id)
	//注意，容器内使用的UTC时间
	base.Created = time.Now().UTC()
	base.Managed = managed
	base.Path = entrypoint
	base.Args = args //FIXME: de-duplicate from config
	base.Config = config
	base.HostConfig = &containertypes.HostConfig{}
	base.ImageID = imgID
	base.NetworkSettings = &network.Settings{IsAnonymousEndpoint: noExplicitName}
	base.Name = name
	base.Driver = daemon.imageService.GraphDriverForOS(operatingSystem)
	base.OS = operatingSystem
	return base, err
}
```
3. **在**`/var/lib/docker/{fsdriver}`**目录中，创建容器读写层rwLayer**，19.03版本为`/var/lib/docker/overlay2/`：
```go
	...
	//windows fix
	...
	//这一步比较关键，创建容器的读写层
	//创建的过程将调用具体的文件驱动，比如overlay2，读写层的父层即容器的image layer
	//读写层的基本原理为在docker创建的对应的容器的工作目录下new一个读写目录，然后image layer的只读层做union mount
	// Set RWLayer for container after mount labels have been set
	rwLayer, err := daemon.imageService.CreateLayer(container, setupInitLayer(daemon.idMapping))
```

进入函数`CreateLayer(container *container.Container, initFunc layer.MountInit) (layer.RWLayer, error)`,根据注释可以看到，创建读写层是给容器创建了一个独立的文件系统，目录位于`/var/lib/docker/{FsDriver}/`，注意，**该目录已经存储了image layer的各层信息。创建容器后容器的读写层同样位于该目录**，image layer的存储详细内容[参考](docker-layer-store.md):

```go
// CreateLayer creates a filesystem layer for a container.
// called from create.go
func (i *ImageService) CreateLayer(container *container.Container, initFunc layer.MountInit) (layer.RWLayer, error) {
	var layerID layer.ChainID
	//获取父镜像的最上层只读layerId
	if container.ImageID != "" {
		img, err := i.imageStore.Get(container.ImageID)
		if err != nil {
			return nil, err
		}
		layerID = img.RootFS.ChainID()
	}
	//封装配置
	rwLayerOpts := &layer.CreateRWLayerOpts{
		MountLabel: container.MountLabel,
		InitFunc:   initFunc,
		StorageOpt: container.HostConfig.StorageOpt,
	}

	// Indexing by OS is safe here as validation of OS has already been performed in create() (the only
	// caller), and guaranteed non-nil
	//根据OS调用CreateLayer
	return i.layerStores[container.OS].CreateRWLayer(container.ID, layerID, rwLayerOpts)
}
```
继续进入`CreateRWLayer(name string, parent ChainID, opts *CreateRWLayerOpts) (_ RWLayer, err error)`，其中name为containerID, parent为imager只读层的ID，opts为配置内容:
```go
func (ls *layerStore) CreateRWLayer(name string, parent ChainID, opts *CreateRWLayerOpts) (_ RWLayer, err error) {
	...
	if opts != nil {
		mountLabel = opts.MountLabel
		storageOpt = opts.StorageOpt
		initFunc = opts.InitFunc
	}

	ls.locker.Lock(name)
	defer ls.locker.Unlock(name)
	
	ls.mountL.Lock()
	_, ok := ls.mounts[name]
	ls.mountL.Unlock()
	if ok {
		return nil, ErrMountNameConflict
	}

	var pid string
	var p *roLayer
	//获取parent image的只读layer
	if string(parent) != "" {
		p = ls.get(parent)
		...
		pid = p.cacheID
		// Release parent chain if error
		defer func() {
			if err != nil {
				ls.layerL.Lock()
				ls.releaseLayer(p)
				ls.layerL.Unlock()
			}
		}()
	}
	//封装即将需要mount的layer
	m := &mountedLayer{
		name:       name,
		parent:     p,
		//随机一个MountID,即/var/lib/docker/{fsdriver}/{mountID}中的mountId
		mountID:    ls.mountID(name),
		layerStore: ls,
		references: map[RWLayer]*referencedRWLayer{},
	}
	//底层调用ProtoDriver接口的CreateReadWrite方法
	//创建/var/lib/docker/{fsdriver}/{mountID}-init目录，以及目录下的/diff, /work, /lower等目录，同时在/var/lib/docker/overlay2/l中创建symlink连接到{mountID}-init下的diff
	//接口的实现包括了overlay/overlay2/aufs等，创建完成后再获取挂载点以及释放资源(这点不太明白)
	//那么，这个init目录的作用是啥呢？
	if initFunc != nil {
		pid, err = ls.initMount(m.mountID, pid, mountLabel, initFunc, storageOpt)
		if err != nil {
			return
		}
		m.initID = pid
	}

	createOpts := &graphdriver.CreateOpts{
		StorageOpt: storageOpt,
	}
	//和initMount相同，调用ProtoDriver接口的CreateReadWrite方法，创建/var/lib/docker/{fsdriver}/{mountID}目录，以及目录下的/diff, /work, /lower等目录
	//同时在/var/lib/docker/overlay2/l中创建symlink连接到{mountID}下的diff
	if err = ls.driver.CreateReadWrite(m.mountID, pid, createOpts); err != nil {
		return
	}
	if err = ls.saveMount(m); err != nil {
		return
	}
	
	return m.getReference(), nil
}
```

4. **创建容器配置存储目录**`/var/lib/docker/containers/{containerId}`：

回到`create`函数，将读写层对象赋给container对象，然后创建container相关的目录
```go
	...
	container.RWLayer = rwLayer
	rootIDs := daemon.idMapping.RootPair()
	//目录位于/var/lib/docker/containers/{container_id}
	if err := idtools.MkdirAndChown(container.Root, 0700, rootIDs); err != nil {
		return nil, err
	}
	//目录位于/var/lib/docker/containers/{container_id}/checkpoints
	if err := idtools.MkdirAndChown(container.CheckpointDir(), 0700, rootIDs); err != nil {
		return nil, err
	}
	//根据hostconfig的配置，将配置信息应用于容器，主要是处理挂载点，将挂载点的信息返回至container对象
	if err := daemon.setHostConfig(container, opts.params.HostConfig); err != nil {
		return nil, err
	}
```
具体内容，进入setHostConfig(container, opts.params.HostConfig),可以看到：
```go
func (daemon *Daemon) setHostConfig(container *container.Container, hostConfig *containertypes.HostConfig) error {
	// Do not lock while creating volumes since this could be calling out to external plugins
	// Don't want to block other actions, like `docker ps` because we're waiting on an external plugin
	//注册挂载点，包括了
	//1. 容器对象自身的挂载点
	//2. –volumes-form声明的父容器的挂载
	//3. --volume声明的挂载，来自hostconfig的Binds项
	//3. --mount声明的挂载，具体见https://docs.docker.com/storage/bind-mounts/
	//将最终的挂载点以[destination]point的map形式写入container
	if err := daemon.registerMountPoints(container, hostConfig); err != nil {
		return err
	}

	container.Lock()
	defer container.Unlock()
	//注册hostConfig中的Links，即--link选项，https://docs.docker.com/network/links/ 注，此项已不推荐使用
	// Register any links from the host config before starting the container
	if err := daemon.registerLinks(container, hostConfig); err != nil {
		return err
	}
	//hostconfig网络模型设置
	runconfig.SetDefaultNetModeIfBlank(hostConfig)
	container.HostConfig = hostConfig
	return container.CheckpointTo(daemon.containersReplica)
}
```

5. **执行具体OS的容器创建工作，包括了尝试执行实际的文件挂载**

回到`create`函数，上述注册完挂载点后，调用`createContainerOSSpecificSettings`进行容器具体的创建工作，即对读写层的实际创建和mount，此部分的工作都在目录`/var/lib/docker/{fsdriver}`中完成,比如`/var/lib/docker/overlay2`：
```go
	...
	//
	if err := daemon.createContainerOSSpecificSettings(container, opts.params.Config, opts.params.HostConfig); err != nil {
		return nil, err
	}
	...
```
进入`createContainerOSSpecificSettings(container, opts.params.Config, opts.params.HostConfig)`实现：
```go
	// createContainerOSSpecificSettings performs host-OS specific container create functionality
	func (daemon *Daemon) createContainerOSSpecificSettings(container *container.Container, config *containertypes.Config, hostConfig *containertypes.HostConfig) error {
	//根据container中配置的挂载点信息，执行具体的mount操作， 可以通过 mount -l 查看系统的挂载点信息
	if err := daemon.Mount(container); err != nil {
		return err
	}
	//注意挂载执行后再卸载掉，此处猜测是进行挂载尝试？
	defer daemon.Unmount(container)

	rootIDs := daemon.idMapping.RootPair()
	//设置workDir，目录位于/var/lib/docker/overlay2/{mountID}/work 可通过docker inspect --format '{{.GraphDriver.Data}}' {containerID}查看
	if err := container.SetupWorkingDirectory(rootIDs); err != nil {
		return err
	}

	// Set the default masked and readonly paths with regard to the host config options if they are not set.
	if hostConfig.MaskedPaths == nil && !hostConfig.Privileged {
		hostConfig.MaskedPaths = oci.DefaultSpec().Linux.MaskedPaths // Set it to the default if nil
		container.HostConfig.MaskedPaths = hostConfig.MaskedPaths
	}
	if hostConfig.ReadonlyPaths == nil && !hostConfig.Privileged {
		hostConfig.ReadonlyPaths = oci.DefaultSpec().Linux.ReadonlyPaths // Set it to the default if nil
		container.HostConfig.ReadonlyPaths = hostConfig.ReadonlyPaths
	}
	//挂载卷处理
	for spec := range config.Volumes {
		name := stringid.GenerateRandomID()
		destination := filepath.Clean(spec)

		// Skip volumes for which we already have something mounted on that
		// destination because of a --volume-from.
		if container.HasMountFor(destination) {
			logrus.WithField("container", container.ID).WithField("destination", spec).Debug("mountpoint already exists, skipping anonymous volume")
			// Not an error, this could easily have come from the image config.
			continue
		}
		path, err := container.GetResourcePath(destination)
		if err != nil {
			return err
		}

		stat, err := os.Stat(path)
		if err == nil && !stat.IsDir() {
			return fmt.Errorf("cannot mount volume over existing file, file exists %s", path)
		}

		v, err := daemon.volumes.Create(context.TODO(), name, hostConfig.VolumeDriver, volumeopts.WithCreateReference(container.ID))
		if err != nil {
			return err
		}

		if err := label.Relabel(v.Mountpoint, container.MountLabel, true); err != nil {
			return err
		}

		container.AddMountPointWithVolume(destination, &volumeWrapper{v: v, s: daemon.volumes}, true)
	}
	return daemon.populateVolumes(container)
}
```
6. **容器网络配置**

返回`create`, 进行容器网络设置：
```go
	...
	//如果没有设置网络，将网络模式设置为 default
	var endpointsConfigs map[string]*networktypes.EndpointSettings
	if opts.params.NetworkingConfig != nil {
		endpointsConfigs = opts.params.NetworkingConfig.EndpointsConfig
	}
	// Make sure NetworkMode has an acceptable value. We do this to ensure
	// backwards API compatibility.
	runconfig.SetDefaultNetModeIfBlank(container.HostConfig)
	//更新网络设置
	daemon.updateContainerNetworkSettings(container, endpointsConfigs)
	...
}
```
7. **保存该container对象**
```
	...
	//在Daemon中注册新建的container对象，底层为一个map[string]*Container，key为容器id
	if err := daemon.Register(container); err != nil {
		return nil, err
	}
	//状态首先设置为stopped
	stateCtr.set(container.ID, "stopped")
	daemon.LogContainerEvent(container, "create")
	return container, nil
	...
```

至此，container对象创建完毕，对象中维护了容器运行时的所有配置，包括了存储、网络和文件目录等，容器在运行时需要的物理文件目录也mount完毕。

### ContainerStart

接下来将启动容器，入口函数位于`api/server/router/container/container_routes.go`的方法`func (s *containerRouter) postContainersStart(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error`

进行版本校验后，进入backend的ContainerStart方法，具体实现为:
```go
// ContainerStart starts a container.
func (daemon *Daemon) ContainerStart(name string, hostConfig *containertypes.HostConfig, checkpoint string, checkpointDir string) error {
	...
	//根据container名称，从daemon的缓存中读取container对象
	container, err := daemon.GetContainer(name)
	...
	//状态检查
	validateState := func() error {
		container.Lock()
		defer container.Unlock()

		if container.Paused {
			return errdefs.Conflict(errors.New("cannot start a paused container, try unpause instead"))
		}

		if container.Running {
			return containerNotModifiedError{running: true}
		}

		if container.RemovalInProgress || container.Dead {
			return errdefs.Conflict(errors.New("container is marked for removal and cannot be started"))
		}
		return nil
	}
	if err := validateState(); err != nil {
		return err
	}
	
	//处理container启动时，daemon缓存的hostConfig配置与api接口接收的配置不一致问题，1.12版本后已废弃
	if runtime.GOOS != "windows" {
		// This is kept for backward compatibility - hostconfig should be passed when
		// creating a container, not during start.
		//hostconfig为api接口接收的配置信息
		if hostConfig != nil {
			logrus.Warn("DEPRECATED: Setting host configuration options when the container starts is deprecated and has been removed in Docker 1.12")
			//container容器缓存的配置信息
			oldNetworkMode := container.HostConfig.NetworkMode
			if err := daemon.setSecurityOptions(container, hostConfig); err != nil {
				return errdefs.InvalidParameter(err)
			}
			if err := daemon.mergeAndVerifyLogConfig(&hostConfig.LogConfig); err != nil {
				return errdefs.InvalidParameter(err)
			}
			if err := daemon.setHostConfig(container, hostConfig); err != nil {
				return errdefs.InvalidParameter(err)
			}
			newNetworkMode := container.HostConfig.NetworkMode
			if string(oldNetworkMode) != string(newNetworkMode) {
				// if user has change the network mode on starting, clean up the
				// old networks. It is a deprecated feature and has been removed in Docker 1.12
				container.NetworkSettings.Networks = nil
				if err := container.CheckpointTo(daemon.containersReplica); err != nil {
					return errdefs.System(err)
				}
			}
			container.InitDNSHostConfig()
		}
	} else {
		if hostConfig != nil {
			return errdefs.InvalidParameter(errors.New("Supplying a hostconfig on start is not supported. It should be supplied on create"))
		}
	}
	
	// check if hostConfig is in line with the current system settings.
	// It may happen cgroups are umounted or the like.
	//检查container的各项配置，主要是语法检查
	//包括了：
	//  - config配置：    1. workdir路径是否为绝对路径 2.环境变量语法是否正确 3.healthCheck配置参数合法性
	//  - hostConfig配置: 1. mount配置 2.extraHost配置 3.port映射 4.restartPolicy 5.capabilites配置
	if _, err = daemon.verifyContainerSettings(container.OS, container.HostConfig, nil, false); err != nil {
		return errdefs.InvalidParameter(err)
	}
	...
	return daemon.containerStart(container, checkpoint, checkpointDir, true)
}
```
上述代码完成了hostConfig和config的配置校验，继续进入`daemon.containerStart(container, checkpoint, checkpointDir, true)`:
```go
// containerStart prepares the container to run by setting up everything the
// container needs, such as storage and networking, as well as links
// between containers. The container is left waiting for a signal to
// begin running.
func (daemon *Daemon) containerStart(container *container.Container, checkpoint string, checkpointDir string, resetRestartManager bool) (err error) {
	start := time.Now()
	container.Lock()
	defer container.Unlock()
	...//状态检查
	...//以下函数分为了几大步
```
1. **挂载congtainer中Mount字段描述的文件，同【创建容器】的步骤【6】**
```go
	//内部调用daemon.Mount(container)方法，同【创建容器】的步骤【6】，最终根据实际驱动mount config中配置
	if err := daemon.conditionalMountOnStart(container); err != nil {
		return err
	}
```

2. **初始化容器网络**
```go 
	if err := daemon.initializeNetworking(container); err != nil {
		return err
	}	
```	
进入函数内部：
```go
//根据docker网络的类型container/bridge/host分别处理
func (daemon *Daemon) initializeNetworking(container *container.Container) error {
	var err error
	//1. container类型：获取要连接的container,将后者中的hostname等配置赋值给要启动的container
	if container.HostConfig.NetworkMode.IsContainer() {
		// we need to get the hosts files from the container to join
		nc, err := daemon.getNetworkedContainer(container.ID, container.HostConfig.NetworkMode.ConnectedContainer())
		...
		err = daemon.initializeNetworkingPaths(container, nc)
		...
		container.Config.Hostname = nc.Config.Hostname
		container.Config.Domainname = nc.Config.Domainname
		return nil
	}
	//2. host类型：将宿主的hostname赋值给container
	if container.HostConfig.NetworkMode.IsHost() {
		if container.Config.Hostname == "" {
			container.Config.Hostname, err = os.Hostname()
			...
		}
	}
	//3. default(bridge)类型的处理
	if err := daemon.allocateNetwork(container); err != nil {
		return err
	}
	return container.BuildHostnameFile()
}
```
对于docker默认的bridge类型，调用`daemon.allocateNetwork(container)`,继续进入函数：
```go
func (daemon *Daemon) allocateNetwork(container *container.Container) error {
	start := time.Now()
	controller := daemon.netController
	...
	// Cleanup any stale sandbox left over due to ungraceful daemon shutdown
	if err := controller.SandboxDestroy(container.ID); err != nil {
		logrus.Errorf("failed to cleanup up stale network sandbox for container %s", container.ID)
	}
	...
	updateSettings := false
	//如果没有配置network，将container中的属性至空，返回
	if len(container.NetworkSettings.Networks) == 0 {
		daemon.updateContainerNetworkSettings(container, nil)
		updateSettings = true
	}
	// always connect default network first since only default
	// network mode support link and we need do some setting
	// on sandbox initialize for link, but the sandbox only be initialized
	// on first network connecting.
	defaultNetName := runconfig.DefaultDaemonNetworkMode().NetworkName()
	//设置default network, bridge模式
	if nConf, ok := container.NetworkSettings.Networks[defaultNetName]; ok {
		//清除network相关的所有配置
		cleanOperationalData(nConf)
		//连接到指定网络，具体操作为创建/获取sandbox, 将config中的endPoint接入sandbox.
		//endpoint对应于Veth设备，sandbox为Linux network namespace， 这里的network即为linux bridge
		//详细参考 https://developer.51cto.com/art/202010/629789.htm
		if err := daemon.connectToNetwork(container, defaultNetName, nConf.EndpointSettings, updateSettings); err != nil {
			return err
		}

	}

	// the intermediate map is necessary because "connectToNetwork" modifies "container.NetworkSettings.Networks"
	networks := make(map[string]*network.EndpointSettings)
	for n, epConf := range container.NetworkSettings.Networks {
		if n == defaultNetName {
			continue
		}
		networks[n] = epConf
	}
	//非默认network，遍历run时声明连接的网络
	for netName, epConf := range networks {
		//和default network处理相同
		cleanOperationalData(epConf)
		if err := daemon.connectToNetwork(container, netName, epConf.EndpointSettings, updateSettings); err != nil {
			return err
		}
	}

	// If the container is not to be connected to any network,
	// create its network sandbox now if not present
	//如果没有配置网络，即为none，且没有创建none的sandbox，创建之
	if len(networks) == 0 {
		if nil == daemon.getNetworkSandbox(container) {
			options, err := daemon.buildSandboxOptions(container)
			if err != nil {
				return err
			}
			sb, err := daemon.netController.NewSandbox(container.ID, options...)
			if err != nil {
				return err
			}
			updateSandboxNetworkSettings(container, sb)
			defer func() {
				if err != nil {
					sb.Delete()
				}
			}()
		}

	}
	
	if _, err := container.WriteHostConfig(); err != nil {
		return err
	}
	networkActions.WithValues("allocate").UpdateSince(start)
	return nil
}
```
3. **创建oci标准的spec**

```go
	spec, err := daemon.createSpec(container)
	...
```
其中，oci的spec位于[oci标准的runtime-spec定义](https://github.com/opencontainers/runtime-spec/blob/master/specs-go/config.go)
```go
// Spec is the base configuration for the container.
type Spec struct {
	// Version of the Open Container Initiative Runtime Specification with which the bundle complies.
	Version string `json:"ociVersion"`
	// Process configures the container process.
	Process *Process `json:"process,omitempty"`
	// Root configures the container's root filesystem.
	Root *Root `json:"root,omitempty"`
	// Hostname configures the container's hostname.
	Hostname string `json:"hostname,omitempty"`
	// Mounts configures additional mounts (on top of Root).
	Mounts []Mount `json:"mounts,omitempty"`
	// Hooks configures callbacks for container lifecycle events.
	Hooks *Hooks `json:"hooks,omitempty" platform:"linux,solaris"`
	// Annotations contains arbitrary metadata for the container.
	Annotations map[string]string `json:"annotations,omitempty"`

	// Linux is platform-specific configuration for Linux based containers.
	Linux *Linux `json:"linux,omitempty" platform:"linux"`
	// Solaris is platform-specific configuration for Solaris based containers.
	Solaris *Solaris `json:"solaris,omitempty" platform:"solaris"`
	// Windows is platform-specific configuration for Windows based containers.
	Windows *Windows `json:"windows,omitempty" platform:"windows"`
	// VM specifies configuration for virtual-machine-based containers.
	VM *VM `json:"vm,omitempty" platform:"vm"`
}
```
进入`createSpec`函数内部：
```go
func (daemon *Daemon) createSpec(c *container.Container) (retSpec *specs.Spec, err error) {
	var (
		//opts为一个函数数组，这个函数用于将container、client、context的信息注入oci的规范spec
		// SpecOpts sets spec specific information to a newly generated OCI spec
		//type SpecOpts func(context.Context, Client, *containers.Container, *Spec) error
		opts []coci.SpecOpts
		//初始化oci规范的默认spec
		s    = oci.DefaultSpec()
	)
	//定义不同种类的opt函数
	opts = append(opts,
		WithCommonOptions(daemon, c),
		WithCgroups(daemon, c),
		WithResources(c),
		WithSysctls(c),
		WithDevices(daemon, c),
		WithUser(c),
		WithRlimits(daemon, c),
		WithNamespaces(daemon, c),
		WithCapabilities(c),
		WithSeccomp(daemon, c),
		WithMounts(daemon, c),
		WithLibnetwork(daemon, c),
		WithApparmor(c),
		WithSelinux(c),
		WithOOMScore(&c.HostConfig.OomScoreAdj),
	)
	if c.NoNewPrivileges {
		opts = append(opts, coci.WithNoNewPrivileges)
	}
	
	// Set the masked and readonly paths with regard to the host config options if they are set.
	if c.HostConfig.MaskedPaths != nil {
		opts = append(opts, coci.WithMaskedPaths(c.HostConfig.MaskedPaths))
	}
	if c.HostConfig.ReadonlyPaths != nil {
		opts = append(opts, coci.WithReadonlyPaths(c.HostConfig.ReadonlyPaths))
	}
	if daemon.configStore.Rootless {
		opts = append(opts, WithRootless)
	}
	//执行各项opt函数，将container、client、context的信息注入spec，并返回spec
	return &s, coci.ApplyOpts(context.Background(), nil, &containers.Container{
		ID: c.ID,
	}, &s, opts...)
}
```
比如以第一个`opt`函数``为例:
```go
// WithCommonOptions sets common docker options
func WithCommonOptions(daemon *Daemon, c *container.Container) coci.SpecOpts {
	//返回一个基于基本的docker run设置的oci spec
	return func(ctx context.Context, _ coci.Client, _ *containers.Container, s *coci.Spec) error {
		...//检查BaseFS
		//环境变量
		linkedEnv, err := daemon.setupLinkedContainers(c)
		...
		s.Root = &specs.Root{
			Path:     c.BaseFS.Path(),
			Readonly: c.HostConfig.ReadonlyRootfs,
		}
		//work dir
		if err := c.SetupWorkingDirectory(daemon.idMapping.RootPair()); err != nil {
			return err
		}
		cwd := c.Config.WorkingDir
		if len(cwd) == 0 {
			cwd = "/"
		}
		//执行命令的args
		s.Process.Args = append([]string{c.Path}, c.Args...)

		// only add the custom init if it is specified and the container is running in its
		// own private pid namespace.  It does not make sense to add if it is running in the
		// host namespace or another container's pid namespace where we already have an init
		if c.HostConfig.PidMode.IsPrivate() {
			if (c.HostConfig.Init != nil && *c.HostConfig.Init) ||
				(c.HostConfig.Init == nil && daemon.configStore.Init) {
				s.Process.Args = append([]string{inContainerInitPath, "--", c.Path}, c.Args...)
				path := daemon.configStore.InitPath
				if path == "" {
					path, err = exec.LookPath(daemonconfig.DefaultInitBinary)
					if err != nil {
						return err
					}
				}
				s.Mounts = append(s.Mounts, specs.Mount{
					Destination: inContainerInitPath,
					Type:        "bind",
					Source:      path,
					Options:     []string{"bind", "ro"},
				})
			}
		}
		//将container里解析的配置进spec
		s.Process.Cwd = cwd
		s.Process.Env = c.CreateDaemonEnvironment(c.Config.Tty, linkedEnv)
		s.Process.Terminal = c.Config.Tty
		s.Hostname = c.Config.Hostname
		setLinuxDomainname(c, s)
		return nil
	}
}
```
4. **创建containerd定义的container容器**
```go
	if resetRestartManager {
		container.ResetRestartManager(true)
		container.HasBeenManuallyStopped = false
	}
	//AppArmor(Application Armor)设置， 详细内容参考 https://docs.docker.com/engine/security/apparmor/
	if err := daemon.saveApparmorConfig(container); err != nil {
		return err
	}
	//check point
	if checkpoint != "" {
		checkpointDir, err = getCheckpointDir(checkpointDir, checkpoint, container.Name, container.ID, container.CheckpointDir(), false)
	}
	//runC的配置
	createOptions, err := daemon.getLibcontainerdCreateOptions(container)
	...
	//调用containerd的接口
	err = daemon.containerd.Create(ctx, container.ID, spec, createOptions)
	...
```
进入`create函数`：
```go
func (c *client) Create(ctx context.Context, id string, ociSpec *specs.Spec, runtimeOptions interface{}, opts ...containerd.NewContainerOpts) error {
	bdir := c.bundleDir(id)
	//创建newOpts函数数组，函数NewContainerOpts的作用为：允许调用者在创建容器时设置额外的选项
	newOpts := []containerd.NewContainerOpts{
		//withSpec返回的NewContainerOpts函数内部逻辑为：循环调用SpecOpts的函数，因为参数中没有opts，因此其主要作用为将spec赋值给container的Spec字段,即c.Spec, err = typeurl.MarshalAny(s)
		containerd.WithSpec(ociSpec),
		//withRuntime返回的NewContainerOpts函数内部逻辑为：向container写入runtime信息
		containerd.WithRuntime(runtimeName, runtimeOptions),
		////withBundle返回的NewContainerOpts函数内部逻辑为：向container的label中写入containers bundle path信息，key为com.docker/engine.bundle.path
		WithBundle(bdir, ociSpec),
	}
	opts = append(opts, newOpts...)

	_, err := c.client.NewContainer(ctx, id, opts...)
	...
	return nil
}
```
继续看`NewContainer`函数，此函数的作用为重新创建一个container对象，**注意，此处的container对象已经不是docker中定义的container了(github.com/docker/docker/container/container.go), 而是containerd包中定义的container对象（github.com/containerd/containerd/containers/containers.go）**， 并将之前的spec/runtime/bundle path赋值给此对象。
```
// NewContainer will create a new container in container with the provided id
// the id must be unique within the namespace
func (c *Client) NewContainer(ctx context.Context, id string, opts ...NewContainerOpts) (Container, error) {
	//向ctx中设置lease 类似ttl
	ctx, done, err := c.WithLease(ctx)
	...
	//封装一个containerd定义的container对象
	container := containers.Container{
		ID: id,
		Runtime: containers.RuntimeInfo{
			Name: c.runtime,
		},
	}
	//执行NewContainerOpts数组，向container中赋值spec,runtime，bundle path
	for _, o := range opts {
		if err := o(ctx, c, &container); err != nil {
			return nil, err
		}
	}
	r, err := c.ContainerService().Create(ctx, container)
	...
	return containerFromRecord(c, r), nil
}
```
至此，我们能够看到docker架构演进的痕迹，docker daemon首先根据run的内容创建一个container对象，并根据oci的spec约束，将container对象中的各个信息赋值给新创建的spec，然后再将这个spec赋值给containerd的container，调用containerd的接口。
即`docker daemon->containerd->runtime`.

5. **使用grpc调用containerd**

docker daemon调用containerd使用了grpc，进入上一步的`c.ContainerService().Create(ctx, container)`:
```go
func (c *containersClient) Create(ctx context.Context, in *CreateContainerRequest, opts ...grpc.CallOption) (*CreateContainerResponse, error) {
	out := new(CreateContainerResponse)
	err := c.cc.Invoke(ctx, "/containerd.services.containers.v1.Containers/Create", in, out, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}
```

接下来的工作将由[containerd服务](docker-containerd.md)来完成

