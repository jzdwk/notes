# docker daemon启动

## daemon command

docker daemon的入口函数位于moby/cmd/dockerd/docker.go的main函数。其核心代码为newDaemonCommand函数。注意任何以new开头的函数都是一个工厂函数，返回一个封装好的工厂产品。
进入函数内，可以看到使用了[cobra库](https://github.com/spf13/cobra)进行命令行的封装。
  
```go
	opts := newDaemonOptions(config.New())

	cmd := &cobra.Command{
		Use:           "dockerd [OPTIONS]",
		Short:         "A self-sufficient runtime for containers.",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cli.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.flags = cmd.Flags()
			return runDaemon(opts)
		},
		DisableFlagsInUseLine: true,
		Version:               fmt.Sprintf("%s, build %s", dockerversion.Version, dockerversion.GitCommit),
	}
```

其中opts是docker命令后的参数封装，类型为ademonOptions，包括了flag/param/配置文件等等，daemon的真正启动位于runDaemon函数的实现内。

## run daemon

进入runDaemon函数，通过创建一个daemonCli,调用了后者的start函数，这里面主要分为了以下几步

- 设置默认的opts项,opts.SetDefaultOptions(opts.flags)  
	
- loadDaemonCliConfig,并进行一些conf的检查，包括root相关权限的检查CreateDaemonRoot(cli.Config)
	
- 加载apiserver,入口为loadListeners(cli, serverConfig)，其中serverConfig为cli中的服务相关配置。进入loadListener，可以看到主要做了：

```golang 
    for i := 0; i < len(cli.Config.Hosts); i++ {
		...
		seen[cli.Config.Hosts[i]] = struct{}{}
		protoAddr := cli.Config.Hosts[i]
		protoAddrParts := strings.SplitN(protoAddr, "://", 2)
                ...
		proto := protoAddrParts[0]
		addr := protoAddrParts[1]
                ...
		ls, err := listeners.Init(proto, addr, serverConfig.SocketGroup, serverConfig.TLSConfig)
		...
		if proto == "tcp" {
			if err := allocateDaemonPort(addr); err != nil {
				return nil, err
			}
		}
		...
		hosts = append(hosts, protoAddrParts[1])
		cli.api.Accept(addr, ls...)
	}
```
   
即根据docker conf的host配置，创建不同Listener，最终调用cli.api.Accept函数，加入apiServer的HttpServer列表。
   
- 创建daemon,加载[docker daemon的配置](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon)，其函数入口为daemon.NewDaemon(ctx, cli.Config, pluginStore)。进入函数内部，主要工作包括了：
	
1. 设置MTU,这个mtu和docker的网络相关,对应mtu配置项。
``` go
    setDefaultMtu(config)
```
2. 创建registryService对象，这个registry即docker的镜像仓库相关服务，我们在配置docker的http时，在daemon.json填写过相关内容。这里根据serviceOptions的配置，封装了serviceConfig对象，并做了3个Load操作，分别对应了daemon.json中的allow-nondistributable-artifacts(目前还不知道)、镜像加速器mirror(比如aliyun)以及insucre-registry(http配置)。
```go
	registryService, err := registry.NewService(config.ServiceOptions)
	...
	if err := config.LoadAllowNondistributableArtifacts(options.AllowNondistributableArtifacts)
	if err := config.LoadMirrors(options.Mirrors)
	if err := config.LoadInsecureRegistries(options.InsecureRegistries)
	...
```
3. 验证rootkey/daemon的配置/网桥/创建dns配置, 需要注意的是，这些方法都是空实现，用以docker扩展？
```go
	if err := ModifyRootKeyLimit()
	if err := verifyDaemonSettings(config)
	config.DisableBridge = isBridgeNetworkDisabled(config)
	setupResolvConf(config)
```
4. 验证docker的宿主os环境验证
```go
	if err := checkSystem(); err != nil {
		return nil, err
	}
```
5. 创建docker的remap，并根据config配置的uid/gid创建临时目录，并将路径写入环境变量。docker的[ns-remap](https://docs-stage.docker.com/engine/security/userns-remap/)原因在于，容器内操作以root进行，并且直接对应宿主机的root(比如挂在文件后，容器内操作文件同样会以root在宿主同步)这对于宿主机的安全性是一个威胁，所以使用remap，将容器内的root映射为宿主机上的一个非root用户。
```go
	idMapping, err := setupRemappedRoot(config)
	rootIDs := idMapping.RootPair()
	err := setupDaemonProcess(config)
	tmp, err := prepareTempDir(config.Root, rootIDs)
	realTmp, err := fileutils.ReadSymlinkedDirectory(tmp)
	if isWindows {
		...
		os.Setenv("TEMP", realTmp)
		os.Setenv("TMP", realTmp)
	} else {
		os.Setenv("TMPDIR", realTmp)
	}
```
6. 创建daemon核心数据结构，这个数据结构封装了config内容，以及核心的服务对象
```go
	d := &Daemon{
		configStore: config,
		PluginStore: pluginStore,
		startupDone: make(chan struct{}),
	}
```
7. 对应docker的 --node-generic-resources配置项，用于通知在docker swarm cluster中用户自定义的资源，这里只是将config里配置的资源列表封装为GenericResource对象，并赋值给daemon的field。
```go
	if err := d.setGenericResources(config); err != nil {
		return nil, err
	}
```
8. 设置调用栈dump
```go
	d.setupDumpStackTrap(stackDumpDir)
```go
9. 待研究
```go
	if err := d.setupSeccompProfile(); err != nil {
		return nil, err
	}
	// Set the default isolation mode (only applicable on Windows)
	if err := d.setDefaultIsolation(); err != nil {
		return nil, fmt.Errorf("error setting default isolation mode: %v", err)
	}
```
10. 根据宿主机配置，设置Go runtime max threads
```go
	if err := configureMaxThreads(config); err != nil {
		logrus.Warnf("Failed to configure golang's threads limit: %v", err)
	}
```
11. [apparmor策略](https://docs-stage.docker.com/engine/security/apparmor/)
```go	
	// ensureDefaultAppArmorProfile does nothing if apparmor is disabled
	if err := ensureDefaultAppArmorProfile(); err != nil {
		logrus.Errorf(err.Error())
	}
```
12. 创建各种目录，如containers，默认在/var/lib/docker
```go	
	daemonRepo := filepath.Join(config.Root, "containers")
	daemonRuntimes := filepath.Join(config.Root, "runtimes")
	if err := system.MkdirAll(daemonRuntimes, 0700); err != nil {
		return nil, err
	}
	if err := d.loadRuntimes(); err != nil {
		return nil, err
	}

	if isWindows {
		if err := system.MkdirAll(filepath.Join(config.Root, "credentialspecs"), 0); err != nil {
			return nil, err
		}
	}
```
13. 从env读取GraphDriver，如果没有读到，则从conf中读。graph Driver主要用于管理和维护镜像，包括把镜像从仓库下载下来，到运行时把镜像挂载起来可以被容器访问等。

```go
	d.graphDrivers = make(map[string]string)
	layerStores := make(map[string]layer.Store)
	if isWindows {
		d.graphDrivers[runtime.GOOS] = "windowsfilter"
		if system.LCOWSupported() {
			d.graphDrivers["linux"] = "lcow"
		}
	} else {
		driverName := os.Getenv("DOCKER_DRIVER")
		if driverName == "" {
			driverName = config.GraphDriver
		} else {
			logrus.Infof("Setting the storage driver from the $DOCKER_DRIVER environment variable (%s)", driverName)
		}
		d.graphDrivers[runtime.GOOS] = driverName // May still be empty. Layerstore init determines instead.
	}
```

14. 处理插件，包括metric，metric用于度量docker容器的cpu
 
```go
	d.RegistryService = registryService
	metricsSockPath, err := d.listenMetricsSock()
    //处理插件，包括metric，metric用于度量docker容器的cpu memory等 
	registerMetricsPluginCallback(d.PluginStore, metricsSockPath)
```

15. containerd的客户端初始化，该客户端用于和contarinerd进行grpc连接。containerd是容器技术标准化之后的产物，为了能够兼容[OCI标准](https://www.opencontainers.org/)，将容器运行时及其管理功能从docker daemon剥离,containerd主要职责是镜像管理（镜像、元信息等）、容器执行（调用最终运行时组件执行）。containerd向上为docker daemon提供了gRPC接口，使得docker daemon屏蔽下面的结构变化，确保原有接口向下兼容。向下通过containerd-shim结合runC，使得引擎可以独立升级，避免之前docker daemon升级会导致所有容器不可用的问题。

```go
	gopts := []grpc.DialOption{
		grpc.WithInsecure(),
		grpc.WithBackoffMaxDelay(3 * time.Second),
		grpc.WithContextDialer(dialer.ContextDialer),

		// TODO(stevvooe): We may need to allow configuration of this on the client.
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(defaults.DefaultMaxRecvMsgSize)),
		grpc.WithDefaultCallOptions(grpc.MaxCallSendMsgSize(defaults.DefaultMaxSendMsgSize)),
	}

	if config.ContainerdAddr != "" {
		d.containerdCli, err = containerd.New(config.ContainerdAddr, containerd.WithDefaultNamespace(config.ContainerdNamespace), containerd.WithDialOpts(gopts), containerd.WithTimeout(60*time.Second))
		if err != nil {
			return nil, errors.Wrapf(err, "failed to dial %q", config.ContainerdAddr)
		}
	}
```

17. 初始化[docker plugin](https://docs.docker.com/engine/extend/)对象，插件位于/run/docker/plugin目录。docker支持多种plugin，如访问控制类、network类、volume类等，通过docker plugin install 命令进行安装。实现上首先初始化了一个exec对象，主要用于创建一个containerd客户端，原因在于plugin也需要从docker hub or registry上拉取。

```go
	createPluginExec := func(m *plugin.Manager) (plugin.Executor, error) {
		var pluginCli *containerd.Client

		// Windows is not currently using containerd, keep the
		// client as nil
		if config.ContainerdAddr != "" {
			pluginCli, err = containerd.New(config.ContainerdAddr, containerd.WithDefaultNamespace(config.ContainerdPluginNamespace), containerd.WithDialOpts(gopts), containerd.WithTimeout(60*time.Second))
			if err != nil {
				return nil, errors.Wrapf(err, "failed to dial %q", config.ContainerdAddr)
			}
		}

		return pluginexec.New(ctx, getPluginExecRoot(config.Root), pluginCli, config.ContainerdPluginNamespace, m)
	}

	
	// Plugin system initialization should happen before restore. Do not change order.
	d.pluginManager, err = plugin.NewManager(plugin.ManagerConfig{
		Root:               filepath.Join(config.Root, "plugins"),
		ExecRoot:           getPluginExecRoot(config.Root),
		Store:              d.PluginStore,
		CreateExecutor:     createPluginExec,
		RegistryService:    registryService,
		LiveRestoreEnabled: config.LiveRestoreEnabled,
		LogPluginEvent:     d.LogPluginEvent, // todo: make private
		AuthzMiddleware:    config.AuthzMiddleware,
	})
```
18. 这一步对应于第13步，在从环境变量or config中读取graph driver后，遍历graph driver，使用layerStores进行封装。docker daemon在初始化过程中，会初始化一个layerStore用来存储layer，docker镜像的一层称为一个layer。

```go
	//配置image存储
	for operatingSystem, gd := range d.graphDrivers {
		layerStores[operatingSystem], err = layer.NewStoreFromOptions(layer.StoreOptions{
			Root:                      config.Root,
			MetadataStorePathTemplate: filepath.Join(config.Root, "image", "%s", "layerdb"),
			GraphDriver:               gd,
			GraphDriverOptions:        config.GraphOptions,
			IDMapping:                 idMapping,
			PluginGetter:              d.PluginStore,
			ExperimentalEnabled:       config.Experimental,
			OS:                        operatingSystem,
		})
		if err != nil {
			return nil, err
		}

		// As layerstore initialization may set the driver
		d.graphDrivers[operatingSystem] = layerStores[operatingSystem].DriverName()
	}
```

layerStore相关的内容，请参考[docker image]的分析。并参考了[这篇文章](https://blog.csdn.net/xuguokun1986/article/details/79516233)

19.  创建imageStore，存储的目录位于/var/lib/docker/image/{driver}/imagedb，该目录下主要包含content和metadata两个目录。

- content目录：content下面的sha256目录下存放了每个docker  image的元数据文件，除了制定了这个image由那些roLayer构成，还包含了部分配置信息，如volume、port、workdir等，这部分信息就存放在这个目录下面，docker启动时会读取镜像配置信息，反序列化出image对象

- metadata目录：metadata目录存放了docker image的parent信息。 

docker的数据都存在于/var/lib/docker中，此处的config.Root即/var/lib/docker。在newImageStore函数中，调用了restore，这个restore加载了当前docker的image层、配置并建立层级关系：
 
```go   
	imageRoot := filepath.Join(config.Root, "image", d.graphDrivers[runtime.GOOS])
	ifs, err := image.NewFSStoreBackend(filepath.Join(imageRoot, "imagedb"))
	lgrMap := make(map[string]image.LayerGetReleaser)
	for os, ls := range layerStores {
		lgrMap[os] = ls
	}
	imageStore, err := image.NewImageStore(ifs, lgrMap)
```

20. volume服务初始化，在NewVolumeService中，对已经声明了个volume进行了挂载：

```go
	d.volumes, err = volumesservice.NewVolumeService(config.Root, d.PluginStore, rootIDs, d)
	if err != nil {
		return nil, err
	}
```

21. 创建[trust key](https://docs.docker.com/engine/security/trust/trust_key_mng/)

```go
    //trust key的路径创建
	trustKey, err := loadOrCreateTrustKey(config.TrustKeyPath)
	trustDir := filepath.Join(config.Root, "trust")
	if err := system.MkdirAll(trustDir, 0700); err != nil {
		return nil, err
	}
```
22. image的image/tag相关信息，以一个ubunu镜像为例，ubuntu镜像的名字就叫ubuntu，一个完成的镜像还包括tag，于是就有了ubuntu:latest、ubuntu:14.04等。这部分信息保存在/var/lib/docker/image/{driver}/repositories.json这个文件中，即refStoreLocation

```go
	refStoreLocation := filepath.Join(imageRoot, `repositories.json`)
	rs, err := refstore.NewReferenceStore(refStoreLocation)
	if err != nil {
		return nil, fmt.Errorf("Couldn't create reference store repository: %s", err)
	}
```

23. 这部分感觉像是docker cluster要做的工作，去发现其他节点？

```go
	distributionMetadataStore, err := dmetadata.NewFSMetadataStore(filepath.Join(imageRoot, "distribution"))
	if err != nil {
		return nil, err
	}
    //docker discovery & advertise 暂时还不知道什么鸟用
	// Discovery is only enabled when the daemon is launched with an address to advertise.  When
	// initialized, the daemon is registered and we can store the discovery backend as it's read-only
	if err := d.initDiscovery(config); err != nil {
		return nil, err
	}

	sysInfo := sysinfo.New(false)
	// Check if Devices cgroup is mounted, it is hard requirement for container security,
	// on Linux.
	if runtime.GOOS == "linux" && !sysInfo.CgroupDevicesEnabled {
		return nil, errors.New("Devices cgroup isn't mounted")
	}
```

23. 好了，前期的一通New操作后，对daemon进行赋值，New操作中，通过New对象的函数，进行了一些服务的初始化、dir的创建，并将最终的配置信息返回New后的Service对象，并将这些对象封装进daemon中，这个解耦技巧值得学习。

```go
	d.ID = trustKey.PublicKey().KeyID()
	d.repository = daemonRepo
	d.containers = container.NewMemoryStore()
	if d.containersReplica, err = container.NewViewDB(); err != nil {
		return nil, err
	}
	d.execCommands = exec.NewStore()
	d.idIndex = truncindex.NewTruncIndex([]string{})
	d.statsCollector = d.newStatsCollector(1 * time.Second)

	d.EventsService = events.New()
	d.root = config.Root
	d.idMapping = idMapping
	d.seccompEnabled = sysInfo.Seccomp
	d.apparmorEnabled = sysInfo.AppArmor

	d.linkIndex = newLinkIndex()

	// TODO: imageStore, distributionMetadataStore, and ReferenceStore are only
	// used above to run migration. They could be initialized in ImageService
	// if migration is called from daemon/images. layerStore might move as well.
	d.imageService = images.NewImageService(images.ImageServiceConfig{
		ContainerStore:            d.containers,
		DistributionMetadataStore: distributionMetadataStore,
		EventsService:             d.EventsService,
		ImageStore:                imageStore,
		LayerStores:               layerStores,
		MaxConcurrentDownloads:    *config.MaxConcurrentDownloads,
		MaxConcurrentUploads:      *config.MaxConcurrentUploads,
		MaxDownloadAttempts:       *config.MaxDownloadAttempts,
		ReferenceStore:            rs,
		RegistryService:           registryService,
		TrustKey:                  trustKey,
	})

	go d.execCommandGC()
    //containerd 客户端，用于容器的管理
	d.containerd, err = libcontainerd.NewClient(ctx, d.containerdCli, filepath.Join(config.ExecRoot, "containerd"), config.ContainerdNamespace, d)
	if err != nil {
		return nil, err
	}
    //restore函数，扫描/var/lib/docker中的container数量，并用groupwait来依次拉起
	if err := d.restore(); err != nil {
		return nil, err
	}
	close(d.startupDone)

	// FIXME: this method never returns an error
	info, _ := d.SystemInfo()

	engineInfo.WithValues(
		dockerversion.Version,
		dockerversion.GitCommit,
		info.Architecture,
		info.Driver,
		info.KernelVersion,
		info.OperatingSystem,
		info.OSType,
		info.OSVersion,
		info.ID,
	).Set(1)
	engineCpus.Set(float64(info.NCPU))
	engineMemory.Set(float64(info.MemTotal))

	gd := ""
	for os, driver := range d.graphDrivers {
		if len(gd) > 0 {
			gd += ", "
		}
		gd += driver
		if len(d.graphDrivers) > 1 {
			gd = fmt.Sprintf("%s (%s)", gd, os)
		}
	}
	logrus.WithFields(logrus.Fields{
		"version":        dockerversion.Version,
		"commit":         dockerversion.GitCommit,
		"graphdriver(s)": gd,
	}).Info("Docker daemon")

	return d, nil
```

总的来说，newDaemon里面两个重要的数据结构，一个是conf，另一个就是daemon，前者维护了docker启动时的参数/配置，后者的field里保存了daemon的各个模块struct，在代码中，执行init/new去初始化配置后，返回一个对象给field中。