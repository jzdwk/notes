# docker run 

## client

当执行`docker run`命令，会执行`.../docker-ce/components/cli/cli/command/container/run.go`中的`func NewRunCommand(dockerCli command.Cli)`,主要看`runRun`函数:
```go
//docker run 后携带的命令主要分为了runOptinos和containerOptions
func runRun(dockerCli command.Cli, flags *pflag.FlagSet, ropts *runOptions, copts *containerOptions) error {
	//解析从终端输入的config options，这里面的config主要有
	//config ：独立于宿主机的配置信息，其内容如果用户没有指定，将默认来自于../docker/image/overlay2/imagedb/content/sha256/{iamgeID}中的config段落。比如hostname，user;默认omitempty设置，如果为空置则忽略字段。
    //hostConfig ： 与主机相关的配置，即容器与主键之间的端口映射、日志、volume等等
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
以上逻辑也只是进行了config的check处理，继续看`daemon.create(opts)`:
```go
// Create creates a new container from the given configuration with a given name.
func (daemon *Daemon) create(opts createOpts) (retC *container.Container, retErr error) {
	var (
		container *container.Container
		img       *image.Image
		imgID     image.ID
		err       error
	)

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
	//创建container
	if container, err = daemon.newContainer(opts.params.Name, os, opts.params.Config, opts.params.HostConfig, imgID, opts.managed); err != nil {
		return nil, err
	}
	defer func() {
		if retErr != nil {
			if err := daemon.cleanupContainer(container, true, true); err != nil {
				logrus.Errorf("failed to cleanup container on create error: %v", err)
			}
		}
	}()

	if err := daemon.setSecurityOptions(container, opts.params.HostConfig); err != nil {
		return nil, err
	}

	container.HostConfig.StorageOpt = opts.params.HostConfig.StorageOpt

	// Fixes: https://github.com/moby/moby/issues/34074 and
	// https://github.com/docker/for-win/issues/999.
	// Merge the daemon's storage options if they aren't already present. We only
	// do this on Windows as there's no effective sandbox size limit other than
	// physical on Linux.
	if runtime.GOOS == "windows" {
		if container.HostConfig.StorageOpt == nil {
			container.HostConfig.StorageOpt = make(map[string]string)
		}
		for _, v := range daemon.configStore.GraphOptions {
			opt := strings.SplitN(v, "=", 2)
			if _, ok := container.HostConfig.StorageOpt[opt[0]]; !ok {
				container.HostConfig.StorageOpt[opt[0]] = opt[1]
			}
		}
	}

	// Set RWLayer for container after mount labels have been set
	rwLayer, err := daemon.imageService.CreateLayer(container, setupInitLayer(daemon.idMapping))
	if err != nil {
		return nil, errdefs.System(err)
	}
	container.RWLayer = rwLayer

	rootIDs := daemon.idMapping.RootPair()

	if err := idtools.MkdirAndChown(container.Root, 0700, rootIDs); err != nil {
		return nil, err
	}
	if err := idtools.MkdirAndChown(container.CheckpointDir(), 0700, rootIDs); err != nil {
		return nil, err
	}

	if err := daemon.setHostConfig(container, opts.params.HostConfig); err != nil {
		return nil, err
	}

	if err := daemon.createContainerOSSpecificSettings(container, opts.params.Config, opts.params.HostConfig); err != nil {
		return nil, err
	}

	var endpointsConfigs map[string]*networktypes.EndpointSettings
	if opts.params.NetworkingConfig != nil {
		endpointsConfigs = opts.params.NetworkingConfig.EndpointsConfig
	}
	// Make sure NetworkMode has an acceptable value. We do this to ensure
	// backwards API compatibility.
	runconfig.SetDefaultNetModeIfBlank(container.HostConfig)

	daemon.updateContainerNetworkSettings(container, endpointsConfigs)
	if err := daemon.Register(container); err != nil {
		return nil, err
	}
	stateCtr.set(container.ID, "stopped")
	daemon.LogContainerEvent(container, "create")
	return container, nil
}
```





