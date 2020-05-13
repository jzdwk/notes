# kong ingress controller

这里尝试对kong ingress controller的实现进行分析，代码基于[0.8.x版本](https://github.com/Kong/kubernetes-ingress-controller/tree/0.8.x)

kong ingress controller的最主要作用就是在api server监听各种k8s资源对象，包括crd，当遇到策略下发时，通过kong sdk调用api admin去执行策略下发。

## main

kong ingress controller的入口位于cli/ingress-controller/main.go：

1. 首先，通过parseFlags参数，解析启动kong-ingress-controller时的入参以及配置参数，类似于kong-ingress-controller --XXX=XXX，在这个函数里使用了[viper](https://github.com/spf13/viper)

```
    color.Output = ioutil.Discard
	rand.Seed(time.Now().UnixNano())
	fmt.Println(version())
	cliConfig, err := parseFlags()
```

进入parseFlags内部，可以看到其获取了kong client与kong服务通信的基本配置，并将这些信息封装为cliConfig结构体：

```
flagSet := flagSet()

	// glog
	flag.Set("logtostderr", "true")

	flagSet.AddGoFlagSet(flag.CommandLine)
	flagSet.Parse(os.Args)

	flag.CommandLine.Parse([]string{})

	viper.SetEnvPrefix("CONTROLLER")
	viper.AutomaticEnv()
	viper.SetEnvKeyReplacer(strings.NewReplacer(".", "_", "-", "_"))
	viper.BindPFlags(flagSet)

	for key, value := range viper.AllSettings() {
		glog.V(2).Infof("FLAG: --%s=%q", key, value)
	}

	var config cliConfig
	...
	config.KongWorkspace = viper.GetString("kong-workspace")
	config.KongAdminConcurrency = viper.GetInt("kong-admin-concurrency")
	config.KongAdminFilterTags = viper.GetStringSlice("kong-admin-filter-tag")

	config.KongAdminHeaders = viper.GetStringSlice("admin-header")
	kongAdminHeaders := viper.GetStringSlice("kong-admin-header")
	...
	config.KongAdminTLSServerName = viper.GetString("admin-tls-server-name")
	kongAdminTLSServerName := viper.GetString("kong-admin-tls-server-name")
	if kongAdminTLSServerName != "" {
		config.KongAdminTLSServerName = kongAdminTLSServerName
	}
```
其中cliConfig的结构体如下：

```
type cliConfig struct {
	// Admission controller server properties
	AdmissionWebhookListen   string
	AdmissionWebhookCertPath string
	AdmissionWebhookKeyPath  string

	// Kong connection details
	KongAdminURL           string
	KongWorkspace          string
	KongAdminConcurrency   int
	KongAdminFilterTags    []string
	KongAdminHeaders       []string
	KongAdminTLSSkipVerify bool
	KongAdminTLSServerName string
	KongAdminCACertPath    string

	// Resource filtering
	WatchNamespace string
	IngressClass   string
	ElectionID     string

	// Ingress Status publish resource
	PublishService         string
	PublishStatusAddress   string
	UpdateStatus           bool
	UpdateStatusOnShutdown bool

	// Runtime behavior
	SyncPeriod        time.Duration
	SyncRateLimit     float32
	EnableReverseSync bool

	// k8s connection details
	APIServerHost      string
	KubeConfigFilePath string

	// Performance
	EnableProfiling bool

	// Misc
	ShowVersion      bool
	AnonymousReports bool
}
```

2. 在解析完client端的配置后，根据配置来创建两个client，一个是k8s的client，用于和k8s apiserver通信，另一个是kong client。首先，根据api server的APIServerHost和KubeConfigFilePath配置kubeClient，这里使用了[client-go](https://github.com/kubernetes/client-go):

```
    ...
	kubeCfg, kubeClient, err := createApiserverClient(cliConfig.APIServerHost,
		cliConfig.KubeConfigFilePath)
	...
	if cliConfig.PublishService != "" {
		svc := cliConfig.PublishService
		ns, name, err := utils.ParseNameNS(svc)
		...
		_, err = kubeClient.CoreV1().Services(ns).Get(name, metav1.GetOptions{})
		...
	}

	if cliConfig.WatchNamespace != "" {
		_, err = kubeClient.CoreV1().Namespaces().Get(cliConfig.WatchNamespace,
			metav1.GetOptions{})
		...
	}
```

注意上述代码除了kubeClient，额外处理了config中PublishService与WatchNamespace，当以上配置不为空，测试对应的k8s中是否设置。

3. 接下来创建kong client,首先，解析cliConfig内容并封装为controller.Configuration，后者包含了kongIngress需要的所有配置以及client。其结构如下：

```
	type Configuration struct {
	Kong //封装了kong各个组件的service

	KubeClient       clientset.Interface //kong client
	KongConfigClient configurationClientSet.Interface 
	KnativeClient    knativeClientSet.Interface

	ResyncPeriod      time.Duration
	SyncRateLimit     float32
	EnableReverseSync bool

	Namespace string

	IngressClass string

	// optional
	PublishService       string
	PublishStatusAddress string

	UpdateStatus           bool
	UpdateStatusOnShutdown bool
	ElectionID             string

	UseNetworkingV1beta1        bool
	EnableKnativeIngressSupport bool
}
```

根据配置信息创建kongClient，如果使用了TLS，则加载证书：
```
	controllerConfig.KubeClient = kubeClient
	defaultTransport := http.DefaultTransport.(*http.Transport)
	var tlsConfig tls.Config
	if cliConfig.KongAdminTLSSkipVerify {
		tlsConfig.InsecureSkipVerify = true
	}
	if cliConfig.KongAdminTLSServerName != "" {
		tlsConfig.ServerName = cliConfig.KongAdminTLSServerName
	}

	if cliConfig.KongAdminCACertPath != "" {
		certPath := cliConfig.KongAdminCACertPath
		certPool := x509.NewCertPool()
		cert, err := ioutil.ReadFile(certPath)
		...
		ok := certPool.AppendCertsFromPEM([]byte(cert))
		...
		tlsConfig.RootCAs = certPool
	}
	defaultTransport.TLSClientConfig = &tlsConfig
	c := http.DefaultClient
	c.Transport = &HeaderRoundTripper{
		headers: cliConfig.KongAdminHeaders,
		rt:      defaultTransport,
	}

	kongClient, err := kong.NewClient(kong.String(cliConfig.KongAdminURL), c)
	...
```

4. kongCient创建完成后，向kong admin api请求一些server端的配置信息并根据返回进行client的配置，首先请求api的根路径，api会返回kong server的所有配置信息：
```
	//其实就是请求 http://kong_admin_url:port/
	root, err := kongClient.Root(nil)
	//根据返回配置client
	v, err := getSemVerVer(root["version"].(string))
	kongConfiguration := root["configuration"].(map[string]interface{})
	controllerConfig.Kong.Version = v
	if strings.Contains(root["version"].(string), "enterprise") {
		controllerConfig.Kong.Enterprise = true
	}
	kongDB := kongConfiguration["database"].(string)
	glog.Infof("Kong datastore: %s", kongDB)
	if kongDB == "off" {
		controllerConfig.Kong.InMemory = true
	}
	//请求tag信息
	req, _ := http.NewRequest("GET",
		cliConfig.KongAdminURL+"/tags", nil)
	res, err := kongClient.Do(nil, req, nil)
	if err == nil && res.StatusCode == 200 {
		controllerConfig.Kong.HasTagSupport = true
	}
	
	// 如果客户端配置了workspace，则确认在server端存在该wp，不存在则创建
	if cliConfig.KongWorkspace != "" {
		err := ensureWorkspace(kongClient, cliConfig.KongWorkspace)
		...
		//根据wp的配置，更改kong client的base url，
		kongClient, err = kong.NewClient(kong.String(cliConfig.KongAdminURL+"/"+cliConfig.KongWorkspace), c)
		...
	}
	controllerConfig.Kong.Client = kongClient
```

5. 两个client初始化完毕后，将创建informer用于监听api server：

	

	err = discovery.ServerSupportsVersion(kubeClient.Discovery(), schema.GroupVersion{
		Group:   "networking.k8s.io",
		Version: "v1beta1",
	})
	if err == nil {
		controllerConfig.UseNetworkingV1beta1 = true
	}
	coreInformerFactory := informers.NewSharedInformerFactoryWithOptions(
		kubeClient,
		cliConfig.SyncPeriod,
		informers.WithNamespace(cliConfig.WatchNamespace),
	)
	confClient, _ := configurationclientv1.NewForConfig(kubeCfg)
	controllerConfig.KongConfigClient = confClient

	kongInformerFactory := configurationinformer.NewSharedInformerFactoryWithOptions(
		confClient,
		cliConfig.SyncPeriod,
		configurationinformer.WithNamespace(cliConfig.WatchNamespace),
	)

	knativeClient, _ := knativeclient.NewForConfig(kubeCfg)

	var knativeInformerFactory knativeinformer.SharedInformerFactory
	err = discovery.ServerSupportsVersion(knativeClient.Discovery(), schema.GroupVersion{
		Group:   "networking.internal.knative.dev",
		Version: "v1alpha1",
	})
	if err == nil {
		controllerConfig.EnableKnativeIngressSupport = true
		controllerConfig.KnativeClient = knativeClient
		knativeInformerFactory = knativeinformer.NewSharedInformerFactoryWithOptions(
			knativeClient,
			cliConfig.SyncPeriod,
			knativeinformer.WithNamespace(cliConfig.WatchNamespace),
		)
	}

	var synced []cache.InformerSynced
	updateChannel := channels.NewRingChannel(1024)
	reh := controller.ResourceEventHandler{
		UpdateCh:           updateChannel,
		IsValidIngresClass: annotations.IngressClassValidatorFunc(cliConfig.IngressClass),
	}
	var informers []cache.SharedIndexInformer
	var cacheStores store.CacheStores

	var ingInformer cache.SharedIndexInformer
	if controllerConfig.UseNetworkingV1beta1 {
		ingInformer = coreInformerFactory.Networking().V1beta1().Ingresses().Informer()
	} else {
		ingInformer = coreInformerFactory.Extensions().V1beta1().Ingresses().Informer()
	}

	ingInformer.AddEventHandler(reh)
	cacheStores.Ingress = ingInformer.GetStore()
	informers = append(informers, ingInformer)

	endpointsInformer := coreInformerFactory.Core().V1().Endpoints().Informer()
	endpointsInformer.AddEventHandler(controller.EndpointsEventHandler{
		UpdateCh: updateChannel,
	})
	cacheStores.Endpoint = endpointsInformer.GetStore()
	informers = append(informers, endpointsInformer)

	secretsInformer := coreInformerFactory.Core().V1().Secrets().Informer()
	secretsInformer.AddEventHandler(reh)
	cacheStores.Secret = secretsInformer.GetStore()
	informers = append(informers, secretsInformer)

	servicesInformer := coreInformerFactory.Core().V1().Services().Informer()
	servicesInformer.AddEventHandler(reh)
	cacheStores.Service = servicesInformer.GetStore()
	informers = append(informers, servicesInformer)

	tcpIngressInformer := kongInformerFactory.Configuration().V1beta1().TCPIngresses().Informer()
	tcpIngressInformer.AddEventHandler(reh)
	cacheStores.TCPIngress = tcpIngressInformer.GetStore()
	informers = append(informers, tcpIngressInformer)

	kongIngressInformer := kongInformerFactory.Configuration().V1().KongIngresses().Informer()
	kongIngressInformer.AddEventHandler(reh)
	cacheStores.Configuration = kongIngressInformer.GetStore()
	informers = append(informers, kongIngressInformer)

	kongPluginInformer := kongInformerFactory.Configuration().V1().KongPlugins().Informer()
	kongPluginInformer.AddEventHandler(reh)
	cacheStores.Plugin = kongPluginInformer.GetStore()
	informers = append(informers, kongPluginInformer)

	kongClusterPluginInformer := kongInformerFactory.Configuration().V1().KongClusterPlugins().Informer()
	kongClusterPluginInformer.AddEventHandler(reh)
	cacheStores.ClusterPlugin = kongClusterPluginInformer.GetStore()
	informers = append(informers, kongClusterPluginInformer)

	kongConsumerInformer := kongInformerFactory.Configuration().V1().KongConsumers().Informer()
	kongConsumerInformer.AddEventHandler(reh)
	cacheStores.Consumer = kongConsumerInformer.GetStore()
	informers = append(informers, kongConsumerInformer)

	kongCredentialInformer := kongInformerFactory.Configuration().V1().KongCredentials().Informer()
	kongCredentialInformer.AddEventHandler(reh)
	cacheStores.Credential = kongCredentialInformer.GetStore()
	informers = append(informers, kongCredentialInformer)

	if controllerConfig.EnableKnativeIngressSupport {
		knativeIngressInformer := knativeInformerFactory.Networking().V1alpha1().Ingresses().Informer()
		knativeIngressInformer.AddEventHandler(reh)
		cacheStores.KnativeIngress = knativeIngressInformer.GetStore()
		informers = append(informers, knativeIngressInformer)
	}

	stopCh := make(chan struct{})
	for _, informer := range informers {
		go informer.Run(stopCh)
		synced = append(synced, informer.HasSynced)
	}
	if !cache.WaitForCacheSync(stopCh, synced...) {
		runtime.HandleError(fmt.Errorf("Timed out waiting for caches to sync"))
	}

	store := store.New(cacheStores, cliConfig.IngressClass)
	kong, err := controller.NewKongController(&controllerConfig, updateChannel,
		store)
	if err != nil {
		glog.Fatal(err)
	}

	exitCh := make(chan int, 1)
	var wg sync.WaitGroup
	mux := http.NewServeMux()
	wg.Add(1)
	go func() {
		defer wg.Done()
		serveHTTP(cliConfig.EnableProfiling, 10254, mux, stopCh)
	}()
	go handleSigterm(kong, stopCh, exitCh)

	if cliConfig.AnonymousReports {
		hostname, err := os.Hostname()
		if err != nil {
			glog.Error(err)
		}
		uuid, err := uuid.GenerateUUID()
		if err != nil {
			glog.Error(err)
		}
		k8sVersion, err := kubeClient.Discovery().ServerVersion()
		if err != nil {
			glog.Error(err)
		}
		info := utils.Info{
			KongVersion:       root["version"].(string),
			KICVersion:        RELEASE,
			KubernetesVersion: fmt.Sprintf("%s", k8sVersion),
			Hostname:          hostname,
			ID:                uuid,
			KongDB:            kongDB,
		}
		reporter := utils.NewReporter(info)
		go reporter.Run(stopCh)
	}
	if cliConfig.AdmissionWebhookListen != "off" {
		admissionServer := admission.Server{
			Validator: admission.KongHTTPValidator{
				Client: kongClient,
			},
		}
		go func() {
			glog.Error("error running the admission controller server:",
				http.ListenAndServeTLS(
					cliConfig.AdmissionWebhookListen,
					cliConfig.AdmissionWebhookCertPath,
					cliConfig.AdmissionWebhookKeyPath,
					admissionServer,
				))
		}()
	}
	kong.Start()
	wg.Wait()
	os.Exit(<-exitCh)
```


