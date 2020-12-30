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
3. **在**`/var/lib/docker/{fsdriver}`**目录中，创建容器读写层rwLayer**：
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

5. **执行具体OS的容器创建工作，包括了执行实际的文件挂载

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
	//在Daemon中注册新建的container对象，底层为一个map[string]*Container，key为容器id
	if err := daemon.Register(container); err != nil {
		return nil, err
	}
	//状态首先设置为stopped
	stateCtr.set(container.ID, "stopped")
	daemon.LogContainerEvent(container, "create")
	return container, nil
}
```

至此，container对象创建完毕，对象中维护了容器运行时的所有配置，包括了存储、网络和文件目录等，容器在运行时需要的物理文件目录也mount完毕。

### ContainerStart

接下来将启动容器，入口函数位于
