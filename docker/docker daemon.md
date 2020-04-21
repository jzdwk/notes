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

  进入runDaemon函数，通过创建一个daemonCli,调用了后者的start函数，这里面主要分为了以下几步：

  * 设置默认的opts项，opts.SetDefaultOptions(opts.flags)

  * loadDaemonCliConfig,并进行一些conf的检查，包括root相关权限的检查CreateDaemonRoot(cli.Config)

  * 加载apiserver,入口为loadListeners(cli, serverConfig)，其中serverConfig为cli中的服务相关配置。进入loadListener，可以看到主要做了：
``` golang 
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
   * 创建daemon核心进程，其函数入口为daemon.NewDaemon(ctx, cli.Config, pluginStore)。进入函数内部，主要工作包括了：

``` go
    //设置mtu
       setDefaultMtu(config)
    //registry Service
	registryService, err := registry.NewService(config.ServiceOptions)
	if err != nil {
		return nil, err
	}
    //各种配置和环境验证，包括了网桥、RemappedRoot、root权限验证、以及uid的remap映射，remap用于将容器内的root用户
	//映射为host的非root用户（安全问题）
	rootIDs := idMapping.RootPair()
	//docker userns-remap 设置
        tmp, err := prepareTempDir(config.Root, rootIDs)
	realTmp, err := fileutils.ReadSymlinkedDirectory(tmp)
	...
	//daemon的主要数据结构
	d := &Daemon{
		configStore: config,
		PluginStore: pluginStore,
		startupDone: make(chan struct{}),
	}
	
	if err := d.setGenericResources(config); err != nil {
		return nil, err
	}
	//根据rootID 创建各种临时目录，这些目录最后位于/var/lib/docker
	stackDumpDir := config.Root
	if execRoot := config.GetExecRoot(); execRoot != "" {
		stackDumpDir = execRoot
	}
	d.setupDumpStackTrap(stackDumpDir)

	if err := d.setupSeccompProfile(); err != nil {
		return nil, err
	}

	// Set the default isolation mode (only applicable on Windows)
	if err := d.setDefaultIsolation(); err != nil {
		return nil, fmt.Errorf("error setting default isolation mode: %v", err)
	}

	if err := configureMaxThreads(config); err != nil {
		logrus.Warnf("Failed to configure golang's threads limit: %v", err)
	}

	// ensureDefaultAppArmorProfile does nothing if apparmor is disabled
	if err := ensureDefaultAppArmorProfile(); err != nil {
		logrus.Errorf(err.Error())
	}

	daemonRepo := filepath.Join(config.Root, "containers")
	if err := idtools.MkdirAllAndChown(daemonRepo, 0700, rootIDs); err != nil {
		return nil, err
	}
    
	// Create the directory where we'll store the runtime scripts (i.e. in
	// order to support runtimeArgs)
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
    //从env读取GragphDriver
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
    
	d.RegistryService = registryService
	metricsSockPath, err := d.listenMetricsSock()
    //处理插件，包括metric，metric用于度量docker容器的cpu memory等 
	registerMetricsPluginCallback(d.PluginStore, metricsSockPath)
    //grpc初始化
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

	//插件管理 位于/run/docker/plugin
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

	// Configure and validate the kernels security support. Note this is a Linux/FreeBSD
	// operation only, so it is safe to pass *just* the runtime OS graphdriver.
	if err := configureKernelSecuritySupport(config, d.graphDrivers[runtime.GOOS]); err != nil {
		return nil, err
	}
    //docker的数据都存在于/var/lib/docker中，此处的config.Root即/var/lib/docker
	imageRoot := filepath.Join(config.Root, "image", d.graphDrivers[runtime.GOOS])
	//创建存储镜像的路径，imagedb/content imagedb/metadata,在image下，包括了imagedb和layerdb，注意其上层目录为graphdriver的名称（overlay2）
	ifs, err := image.NewFSStoreBackend(filepath.Join(imageRoot, "imagedb"))
    
	lgrMap := make(map[string]image.LayerGetReleaser)
	for os, ls := range layerStores {
		lgrMap[os] = ls
	}
	imageStore, err := image.NewImageStore(ifs, lgrMap)
	if err != nil {
		return nil, err
	}
	//docker volumes 服务
	d.volumes, err = volumesservice.NewVolumeService(config.Root, d.PluginStore, rootIDs, d)
	if err != nil {
		return nil, err
	}
    //trust key的路径创建
	trustKey, err := loadOrCreateTrustKey(config.TrustKeyPath)
	if err != nil {
		return nil, err
	}
	trustDir := filepath.Join(config.Root, "trust")
	if err := system.MkdirAll(trustDir, 0700); err != nil {
		return nil, err
	}

	// We have a single tag/reference store for the daemon globally. However, it's
	// stored under the graphdriver. On host platforms which only support a single
	// container OS, but multiple selectable graphdrivers, this means depending on which
	// graphdriver is chosen, the global reference store is under there. For
	// platforms which support multiple container operating systems, this is slightly
	// more problematic as where does the global ref store get located? Fortunately,
	// for Windows, which is currently the only daemon supporting multiple container
	// operating systems, the list of graphdrivers available isn't user configurable.
	// For backwards compatibility, we just put it under the windowsfilter
	// directory regardless.
	refStoreLocation := filepath.Join(imageRoot, `repositories.json`)
	rs, err := refstore.NewReferenceStore(refStoreLocation)
	if err != nil {
		return nil, fmt.Errorf("Couldn't create reference store repository: %s", err)
	}

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
    //好了，前期的一通New操作后，对daemon进行赋值
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