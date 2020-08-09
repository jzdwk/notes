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
func parseFlags() (cliConfig, error) {
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

2. 在解析完client端的配置后，根据配置来创建两个client，一个是k8s的client，用于和k8s apiserver通信，另一个是kong client。首先，根据api server的APIServerHost和KubeConfigFilePath配置kubeClient，这里使用了[client-go](https://github.com/kubernetes/client-go) :

```
func main(){
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
	...
}
```

注意上述代码除了kubeClient，额外处理了config中PublishService与WatchNamespace，当以上配置不为空，测试对应的k8s中是否设置。另外，createApiserverClient还返回了kubeCfg,这个kubeCfg结构体由client-go定义，主要存储了传递给kube client的信息，结构体如下：

```
type Config struct {
	// Host must be a host string
	Host string
	// APIPath is a sub-path that points to an API root.
	APIPath string
	// ContentConfig contains settings that affect how objects are transformed when
	// sent to the server.
	ContentConfig
	// Server requires Basic authentication
	Username string
	Password string
	// Server requires Bearer authentication. This client will not attempt to use
	// refresh tokens for an OAuth2 flow.
	// TODO: demonstrate an OAuth2 compatible client.
	BearerToken string

	// Path to a file containing a BearerToken.
	// If set, the contents are periodically read.
	// The last successfully read value takes precedence over BearerToken.
	BearerTokenFile string

	// Impersonate is the configuration that RESTClient will use for impersonation.
	Impersonate ImpersonationConfig

	// Server requires plugin-specified authentication.
	AuthProvider *clientcmdapi.AuthProviderConfig

	// Callback to persist config for AuthProvider.
	AuthConfigPersister AuthProviderConfigPersister

	// Exec-based authentication provider.
	ExecProvider *clientcmdapi.ExecConfig

	// TLSClientConfig contains settings to enable transport layer security
	TLSClientConfig

	// UserAgent is an optional field that specifies the caller of this request.
	UserAgent string

	// DisableCompression bypasses automatic GZip compression requests to the
	// server.
	DisableCompression bool

	// Transport may be used for custom HTTP behavior. This attribute may not
	// be specified with the TLS client certificate options. Use WrapTransport
	// to provide additional per-server middleware behavior.
	Transport http.RoundTripper
	// WrapTransport will be invoked for custom HTTP behavior after the underlying
	// transport is initialized (either the transport created from TLSClientConfig,
	// Transport, or http.DefaultTransport). The config may layer other RoundTrippers
	// on top of the returned RoundTripper.
	//
	// A future release will change this field to an array. Use config.Wrap()
	// instead of setting this value directly.
	WrapTransport transport.WrapperFunc

	// QPS indicates the maximum QPS to the master from this client.
	// If it's zero, the created RESTClient will use DefaultQPS: 5
	QPS float32

	// Maximum burst for throttle.
	// If it's zero, the created RESTClient will use DefaultBurst: 10.
	Burst int

	// Rate limiter for limiting connections to the master from this client. If present overwrites QPS/Burst
	RateLimiter flowcontrol.RateLimiter

	// The maximum length of time to wait before giving up on a server request. A value of zero means no timeout.
	Timeout time.Duration

	// Dial specifies the dial function for creating unencrypted TCP connections.
	Dial func(ctx context.Context, network, address string) (net.Conn, error)

	// Version forces a specific version to be used (if registered)
	// Do we need this?
	// Version string
}
```

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
func main(){
	...
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
}
```

4. kongCient创建完成后，向kong admin api请求一些server端的配置信息并根据返回进行client的配置，首先请求api的根路径，api会返回kong server的所有配置信息：
```
func main(){
	...
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
	...
}
```

5. 两个client初始化完毕后，将创建informer用于监听api server，首先根据之前的kubeClient创建一个coreInformerFactory，这个对象主要用于k8s自带的资源操作。

```
func main(){
	...
	coreInformerFactory := informers.NewSharedInformerFactoryWithOptions(
		kubeClient,
		cliConfig.SyncPeriod,
		informers.WithNamespace(cliConfig.WatchNamespace),
	)
	...
}
```

另外，由于在kong中定义了crd，同样需要对这些资源进行操作。所以，根据之前返回的kubeCfg，重新封装了一个ClientSet对象`confClient, _ := configurationclientv1.NewForConfig(kubeCfg)`，这个Clientset继承了client-go的client：
```
	type Clientset struct {
		*discovery.DiscoveryClient //client-go
		configurationV1      *configurationv1.ConfigurationV1Client //v1组client
		configurationV1beta1 *configurationv1beta1.ConfigurationV1beta1Client //v1beta1组client
	}		
```
然后，根据这个clientset创建kongInformerFactory：
```
func main(){
	...
	controllerConfig.KongConfigClient = confClient
	kongInformerFactory := configurationinformer.NewSharedInformerFactoryWithOptions(
		confClient,
		cliConfig.SyncPeriod,
		configurationinformer.WithNamespace(cliConfig.WatchNamespace),
	)
	...
}
```
然后是Knative的相关设置，Knative的[相关资料](https://knative.dev/docs/) 参考，内容待补充。
```
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
```

6. InformerFactory创建完毕后，注册各种资源对象**待补充**
```
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

## sync

kong-ingress-controller的整体步骤为：

1. 创建kong-ingress-controller的crd资源对象

2. k8s apiserver watch到以后，controller根据上文的handler创建资源对象

3. **crd创建好后，将crd定义的kong属性下发到kong服务，并创建相应的资源对象**

回忆nginx ingress controller，最终ingress的配置将在nginx中添加对应的location等。同样，kong的流程也是如此。因此，需要一种机制去保证在crd到kong配置的下发过程中，k8s kong crd和kong之间的配置一致性。这个机制的提供者是[kong deck](https://github.com/Kong/deck) 

首先进入main.go中最后的`kong.start()`：
```
func (n *KongController) Start() {
	...
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		<-n.stopCh
		cancel()
	}()
	var group errgroup.Group
	group.Go(func() error {
		n.elector.Run(ctx)
		return nil
	})
	//goroutine启动同步队列
	if n.syncStatus != nil {
		group.Go(func() error {
			n.syncStatus.Run()
			return nil
		})
	}
	//Run函数为处理逻辑
	group.Go(func() error {
		n.syncQueue.Run(time.Second, n.stopCh)
		return nil
	})
	n.syncQueue.Enqueue(&networking.Ingress{})
	...
	}
	//一个永真循环从update channel中读事件event，并入同步队列
	for {
		select {
		case event := <-n.updateCh.Out():
			if v := atomic.LoadUint32(&n.isShuttingDown); v != 0 {
				return
			}
			if evt, ok := event.(Event); ok {
				//
				n.syncQueue.Enqueue(evt.Obj)
				...
			} else {
				...
			}
		case <-n.stopCh:
			return
		}
	}
}
```
看到和同步相关的操作时通过一个同步队列完成，将接收的crd事件放入同步队列，另一个goroutine去处理，处理逻辑位于`n.syncQueue.Run(time.Second, n.stopCh)`.进入函数是一个period任务，处理逻辑位于`t.worker`：
```
func (t *Queue) worker() {
	for {
		//从同步队列取出event
		key, quit := t.queue.Get()
		...
		ts := time.Now().UnixNano()

		item := key.(Element)
		//跳过最近同步的
		...
		//核心逻辑，t.sync(key)
		if err := t.sync(key); err != nil {
			t.queue.AddRateLimited(Element{
				Key:       item.Key,
				Timestamp: time.Now().UnixNano(),
			})
		} else {
			t.queue.Forget(key)
			t.lastSync = ts
		}
		t.queue.Done(key)
	}
}
```
可以看到，核心逻辑为`t.sync(key)`，这个sync方法是Queue结构体的一个函数变量，而Queue又是kongController结构体的一个字段，因此sync的注册位于main函数的`kong, err := controller.NewKongController(&controllerConfig, updateChannel,store)`，直接进入可以看到`	n.syncQueue = task.NewTaskQueue(n.syncIngress)`:
```
func NewTaskQueue(syncFn func(interface{}) error) *Queue {
	return NewCustomTaskQueue(syncFn, nil)
}

// NewCustomTaskQueue ...
func NewCustomTaskQueue(syncFn func(interface{}) error, fn func(interface{}) (interface{}, error)) *Queue {
	q := &Queue{
		queue:      workqueue.NewRateLimitingQueue(workqueue.DefaultControllerRateLimiter()),
		sync:       syncFn,
		workerDone: make(chan bool),
		fn:         fn,
	}
	if fn == nil {
		q.fn = q.defaultKeyFunc
	}
	return q
}
```
因此，`n.syncIngress`就是sync方法的具体实现:
```
func (n *KongController) syncIngress(interface{}) error {
	n.syncRateLimiter.Accept()
	...
	// If in-memory mode, each Kong instance runs with it's own controller
	if !n.cfg.Kong.InMemory &&
		!n.elector.IsLeader() {
		return nil
	}
	// Sort ingress rules using the ResourceVersion field
	ings := n.store.ListIngresses()
	sort.SliceStable(ings, func(i, j int) bool {
		ir := ings[i].ResourceVersion
		jr := ings[j].ResourceVersion
		return ir < jr
	})
	//重要函数，读取crd描述的kong配置
	state, err := n.parser.Build()
	...
	//重要函数，执行同步
	err = n.OnUpdate(state)
	...
	return nil
}
```
上述代码的逻辑比较清晰，首先是拉取crd描述的kong配置，那么这个配置信息是从哪里来的？通过Build函数可知从`n.parse.store`中得到，因此回到`kongController`，可以看到store的创建位于:
```
func main(){
	···
	store := store.New(cacheStores, cliConfig.IngressClass)
	kong, err := controller.NewKongController(&controllerConfig, updateChannel,
		store)
	···
}
```
而这个cacheStores就是上面定义的各个crd时注册的：
```
func main(){
	...
	endpointsInformer := coreInformerFactory.Core().V1().Endpoints().Informer()
	endpointsInformer.AddEventHandler(controller.EndpointsEventHandler{
		UpdateCh: updateChannel,
	})
	cacheStores.Endpoint = endpointsInformer.GetStore()
	informers = append(informers, endpointsInformer)
	...
}
```

继续回到sync逻辑。接下来调用`n.OnUpdate(state)`执行同步:
```
func (n *KongController) OnUpdate(state *parser.KongState) error {
	targetContent, err := n.toDeckContent(state)
	...
	var shaSum []byte
	// disable optimization if reverse sync is enabled
	if !n.cfg.EnableReverseSync {
		shaSum, err = generateSHA(targetContent)
		if err != nil {
			return err
		}
		//哈希比较diff
		if reflect.DeepEqual(n.runningConfigHash, shaSum) {
			return nil
		}
	}
	if n.cfg.InMemory {
		err = n.onUpdateInMemoryMode(targetContent)
	} else {
		//DB模式的更新
		err = n.onUpdateDBMode(targetContent)
	}
	...
	n.runningConfigHash = shaSum
	return nil
}
```
以DB模式为例：
```
func (n *KongController) onUpdateDBMode(targetContent *file.Content) error {
	client := n.cfg.Kong.Client
	//调用go-kong获取当前kong的所有资源对象信息，返回的结构体为KongRawState
	rawState, err := dump.Get(client, dump.Config{
		SelectorTags: n.getIngressControllerTags(),
	})
	...
	//返回KongState的封装
	currentState, err := state.Get(rawState)
	...
	//读取目标配置，并封装为KongState
	rawState, err = file.Get(targetContent, file.RenderConfig{
		CurrentState: currentState,
		KongVersion:  n.cfg.Kong.Version,
	})
	...
	targetState, err := state.Get(rawState)
	...
	//syncer主要维护2类对象，一类是描述kong状态的current和target，另一类的goroutine协作的chan
	syncer, err := diff.NewSyncer(currentState, targetState)
	...
	syncer.SilenceWarnings = true
	//client.SetDebugMode(true)
	//调用同步器进行同步
	_, errs := solver.Solve(nil, syncer, client, n.cfg.Kong.Concurrency, false)
	...
	return nil
}
```
diff.NewSyncer返回了一个syncer对象，同时向registry注册了所有资源的同步需要的`Action接口`。最终同步的实现为`Solve方法`：
```
// Solve generates a diff and walks the graph.
func Solve(doneCh chan struct{}, syncer *diff.Syncer,
	client *kong.Client, parallelism int, dry bool) (Stats, []error) {
	//普通CRUD封装
	var r *crud.Registry
	r = buildRegistry(client)

	var stats Stats
	recordOp := func(op crud.Op) {
		switch op {
		case crud.Create:
			stats.CreateOps = stats.CreateOps + 1
		case crud.Update:
			stats.UpdateOps = stats.UpdateOps + 1
		case crud.Delete:
			stats.DeleteOps = stats.DeleteOps + 1
		}
	}
	//同步逻辑，这个Run函数为并行执行，并通过wait group去同步
	errs := syncer.Run(doneCh, parallelism, func(e diff.Event) (crud.Arg, error) {
		var err error
		var result crud.Arg
		
		c := e.Obj.(state.ConsoleString)
		switch e.Op {
		case crud.Create:
			print.CreatePrintln("creating", e.Kind, c.Console())
		case crud.Update:
			diffString, err := getDiff(e.OldObj, e.Obj)
			if err != nil {
				return nil, err
			}
			print.UpdatePrintln("updating", e.Kind, c.Console(), diffString)
		case crud.Delete:
			print.DeletePrintln("deleting", e.Kind, c.Console())
		default:
			panic("unknown operation " + e.Op.String())
		}

		if !dry {
			// sync mode
			// fire the request to Kong
			result, err = r.Do(e.Kind, e.Op, e)
			if err != nil {
				return nil, err
			}
		} else {
			// diff mode
			// return the new obj as is
			result = e.Obj
		}
		// record operation in both: diff and sync commands
		recordOp(e.Op)

		return result, nil
	})
	return stats, errs
}
```

总的来说，sync的实现依托了go-client去获取全量的current kong state以及cache stores去获取target kong state。然后对两者进行比较，并同步。
