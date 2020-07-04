# harbor core

core组件是harbor的核心组件，用于对外（包括自身的portal实现）提供各个功能模块的rest api。自身主要完成了基本的erp系统的rbac控制、各个资源对象的db操作等。

## main

来看main函数中完成的工作，代码位于`src/core/main.go`，下面分段来看.

1. 首先是beego的[session设置](https://beego.me/docs/mvc/controller/session.md) ：
```go
	beego.BConfig.WebConfig.Session.SessionOn = true
	beego.BConfig.WebConfig.Session.SessionName = config.SessionCookieName

	redisURL := os.Getenv("_REDIS_URL")
	//使用redis的provider
	if len(redisURL) > 0 {
		gob.Register(models.User{})
		beego.BConfig.WebConfig.Session.SessionProvider = "redis"
		beego.BConfig.WebConfig.Session.SessionProviderConfig = redisURL
	}
```
2. 接下来是配置的初始化，调用为`config.Init()`,进入函数内部：
```go
func Init() error {
	// 初始化keyProvider，这个providet中封装了一个key_path，默认路径是/etc/core/key
	initKeyProvider()
	//config manager的配置，它在内部维护了一个sync.map，用于存储默认/从环境变量读取的配置
	cfgMgr = comcfg.NewDBCfgManager()
	// 从环境变量JOBSERVICE_SECRET读取一个secret，用于和job-service交互
	initSecretStore()
	// project的初始化只是init了config包下声明的project manager的默认实现
	// init project manager based on deploy mode
	if err := initProjectManager(); err != nil {
		...
	}
	return nil
}
```
总体来说，Init完成了以上4部分的初始化，其中业务较多的是`comcfg.NewDBCfgManager()`，内部主要逻辑为从一个预先配置好的`[]Item`切片中读取配置，并根据配置的不同属性（scope/default）加载值，其中Item的配置如下：
```go
ConfigList = []Item{
		{Name: common.AdminInitialPassword, Scope: SystemScope, Group: BasicGroup, EnvKey: "HARBOR_ADMIN_PASSWORD", DefaultValue: "", ItemType: &PasswordType{}, Editable: true},
		{Name: common.AdmiralEndpoint, Scope: SystemScope, Group: BasicGroup, EnvKey: "ADMIRAL_URL", DefaultValue: "", ItemType: &StringType{}, Editable: false}
		...
	}
```
其中注意对于值的读取，harbor是通过`ConfigureValue`以及其绑定的方法来完成类型检查和转换。另外，这里**只init了默认配置**。

3. 创建token的creator，相应的调用函数为`token.InitCreators()`。 这里也是进行一些封装的struct的初始化，主要为接口accessFilter的两个实现repo/registryFilter，并返回一个creatorMap，map的key主要有[Notary](https://docs.docker.com/notary/getting_started/) 和Registry：
```go
func InitCreators() {
	creatorMap = make(map[string]Creator)
	//两种资源的具体filter实现，用于根据用户信息执行过滤操作
	registryFilterMap = map[string]accessFilter{
		"repository": &repositoryFilter{
			//basicParser实现了imageParser接口，用于解析image名称
			parser: &basicParser{},
		},
		"registry": &registryFilter{},
	}
	ext, err := config.ExtURL()
	if err != nil {
		log.Warningf("Failed to get ext url, err: %v, the token service will not be functional with notary requests", err)
	} else {
		notaryFilterMap = map[string]accessFilter{
			"repository": &repositoryFilter{
				parser: &endpointParser{
					endpoint: ext,
				},
			},
		}
		creatorMap[Notary] = &generalCreator{
			service:   Notary,
			filterMap: notaryFilterMap,
		}
	}
	creatorMap[Registry] = &generalCreator{
		service:   Registry,
		filterMap: registryFilterMap,
	}
}
```

4. database的初始化，首先是db的配置加载，入口为`database, err := config.Database()`，这里从上文的配置中取出database相关的信息，并封装至`model.database`中：
```go
func Database() (*models.Database, error) {
	database := &models.Database{}
	database.Type = cfgMgr.Get(common.DatabaseType).GetString()
	postgresql := &models.PostGreSQL{
		Host:         cfgMgr.Get(common.PostGreSQLHOST).GetString(),
		Port:         cfgMgr.Get(common.PostGreSQLPort).GetInt(),
		Username:     cfgMgr.Get(common.PostGreSQLUsername).GetString(),
		Password:     cfgMgr.Get(common.PostGreSQLPassword).GetString(),
		Database:     cfgMgr.Get(common.PostGreSQLDatabase).GetString(),
		SSLMode:      cfgMgr.Get(common.PostGreSQLSSLMode).GetString(),
		MaxIdleConns: cfgMgr.Get(common.PostGreSQLMaxIdleConns).GetInt(),
		MaxOpenConns: cfgMgr.Get(common.PostGreSQLMaxOpenConns).GetInt(),
	}
	database.PostGreSQL = postgresql

	return database, nil
}
```
然后是db的初始化操作，入口为`if err := dao.InitAndUpgradeDatabase(database)`,是dao层封装的公开方法：
```go
func InitAndUpgradeDatabase(database *models.Database) error {
	//首先orm.RegisterDriver注册DB驱动
	if err := InitDatabase(database); err != nil {
		return err
	}
	//执行migrate脚本
	if err := UpgradeSchema(database); err != nil {
		return err
	}
	//从db中读取配置，检查版本
	if err := CheckSchemaVersion(); err != nil {
		return err
	}
	return nil
}
```
首先是InitDatabase，这里返回了Database接口类型的实现，具体的实现有mysql/pgsql和sqlite。每个实现的Database的struct中封装了register需要的信息，并最终调用`orm.RegisterDriver`。然后UpgradeSchema其实是执行脚本来初始化数据，这里使用了插件[go-lang/migrate](https://github.com/golang-migrate/migrate) 。最后从初始化好的db表中读取配置，检查版本。

5. config信息在上文init后，执行load操作。CfgManager中保存了实现ConfigStore接口的database struct,即从database中读取配置信息，并返回一个map:
```go
func (c *ConfigStore) Load() error {
	...
	//调用database的load实现，从propterties表中读取配置，并在前文加载的cfgMap中得到对应key的itemMetadata（里面只有默认value）
	//根据表内容，返回实际的配置value
	cfgs, err := c.cfgDriver.Load()
	...
	//重新将值store至cfgMap中
	for key, value := range cfgs {
		cfgValue := metadata.ConfigureValue{}
		strValue := fmt.Sprintf("%v", value)
		err = cfgValue.Set(key, strValue)
		...
		c.cfgValues.Store(key, cfgValue)
	}
	return nil
}
```
具体的Load由db完成，注意这里只load了scope为用户级的配置信息。

6. 然后是初始化一个和job-service通信的Client，入口为`job.Init`,具体实现：
```go
//endpoint为job service的地址，secret用于core和job service通信
func NewDefaultClient(endpoint, secret string) *DefaultClient {
	var c *commonhttp.Client
	if len(secret) > 0 {
		//SecretAuthorizer实现了http的Modifer接口
		c = commonhttp.NewClient(nil, auth.NewSecretAuthorizer(secret))
	} else {
		c = commonhttp.NewClient(nil)
	}
	e := strings.TrimRight(endpoint, "/")
	return &DefaultClient{
		endpoint: e,
		client:   c,
	}
}
```

7. scheduler.Init则同样完成了scheduler的Manager封装：
```go
func New(internalCoreURL string) Scheduler {
	return &scheduler{
		//core的地址
		internalCoreURL:  internalCoreURL,
		//第6步的job client
		jobserviceClient: job.GlobalClient,
		//ClobalManager为全局变量，封装了ScheduleDao
		manager:          GlobalManager,
	}
}
```

8. 从配置中读取admin的pwd，并更新到db中，代码不再展示。

9. 初始化api模块，调用`api.Init()`，这函数完成了以下几个组件的初始化：

- health check: 首先是初始化health check,实现位于`registerHealthCheckers()`内，主要工作是init了一个全局map `HealthCheckerRegistry = map[string]health.Checker{}`，其中map的value是一个Checker接口，**各个组件定义的check函数变量**实现了Checker接口，以jobservice为例：
```go
	//定义
	HealthCheckerRegistry["jobservice"] = jobserviceHealthChecker()
//具体实现，返回一个Checker实现
func jobserviceHealthChecker() health.Checker {
	url := config.InternalJobServiceURL() + "/api/v1/stats"
	timeout := 60 * time.Second
	period := 10 * time.Second
	//此处返回了一个实现了Checker接口的函数变量
	checker := HTTPStatusCodeHealthChecker(http.MethodGet, url, nil, timeout, http.StatusOK)
	return PeriodicHealthChecker(checker, period)
}
//定义一个定时器，调用Checker的check方法，check即执行上一步定义的func变量
func PeriodicHealthChecker(checker health.Checker, period time.Duration) health.Checker {
	u := &updater{
		// init the "status" as "unknown status" error to avoid returning nil error(which means healthy)
		// before the first health check request finished
		status: errors.New("unknown status"),
	}

	go func() {
		ticker := time.NewTicker(period)
		for {
			u.update(checker.Check())
			<-ticker.C
		}
	}()

	return u
}
```
以上三步完成了一个通过`time.NewTicker`定时调用http请求去检测指定组件url的功能。从代码结构上，定义了一个`Checker接口`，并通过定义各个组件的check func函数变量实现了这个接口，最后定义具体的执行策略，比如PeriodicHealthChecker，并将Checker作为入参。这里，将health check的定义和执行进行了解耦。

- init chart controller: 初始化创建chart的controller，这里引入了一个处理http req的chain插件[alice](https://github.com/justinas/alice) 

- init manager：初始化各个core内部模块的manager，这些manager的内部根据模块需求持有其他功能模块的引用，比如repoManager中包括了projectMgr和chartController，*这里的manager有点像spring应用中的service层* ：
```go
//project manager
func initProjectManager() {
	projectMgr = project.New()
}
//repo manager中，持有chartController、projectMgr的引用
func initRepositoryManager() {
	repositoryMgr = repository.New(projectMgr, chartController)
}
```
- 定时器模块相关的组件初始化，首先是初始化一个全局scheduler：
```go
//初始化一个全局唯一的GlobalScheduler，这个globalScheduler是一个可用于所有组件的默认的定时器，
func initRetentionScheduler() {
	retentionScheduler = scheduler.GlobalScheduler
}
//GlobalScheduler的初始化如下，其中GlobalManager封装了scheduler的dao
func New(internalCoreURL string) Scheduler {
	return &scheduler{
		internalCoreURL:  internalCoreURL,
		jobserviceClient: job.GlobalClient,
		manager:          GlobalManager,
	}
}
```
接下来是创建retentionManager/launcher/controller这些组件：
```go
	//manager为retention包下的DefaultManager，实现了manager接口
	retentionMgr = retention.NewManager()
	//返回lancher接口在retention包下的实现，lancher接口的作用为根据提供的policy内容，异步启动一个job去执行
	retentionLauncher = retention.NewLauncher(projectMgr, repositoryMgr, retentionMgr)
	//controller	
	retentionController = retention.NewAPIController(retentionMgr, projectMgr, repositoryMgr, retentionScheduler, retentionLauncher)
```
最后定义callBack函数，callBack作用为接收policy后，生成Execution保存，然后触发launch：
```go
	//定义callBack
	callbackFun := func(p interface{}) error {
		str, ok := p.(string)
		if !ok {
			return fmt.Errorf("the type of param %v isn't string", p)
		}
		param := &retention.TriggerParam{}
		if err := json.Unmarshal([]byte(str), param); err != nil {
			return fmt.Errorf("failed to unmarshal the param: %v", err)
		}
		//创建Execution，并调用lanuch
		_, err := retentionController.TriggerRetentionExec(param.PolicyID, param.Trigger, false)
		return err
	}
	//将callback注册进scheduler
	err := scheduler.Register(retention.SchedulerCallback, callbackFun)
```
callbackFun最终被注册进scheduler的map中。key为`SchedulerCallback`,并被定期调用。

10. 定义shutdown：通过两个无缓冲chan closing和done，执行程序退出操作：
```go
//closing表示从各个输入捕获
func gracefulShutdown(closing, done chan struct{}) {
	//捕获关闭信号的chan
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)
	//从signal中读取，如果没有关闭信号，则阻塞
	log.Infof("capture system signal %s, to close \"closing\" channel", <-signals)
	//捕获关闭后，直接close closing
	close(closing)
	//从done中读取，done的写入会在各组件，在此用于判断组件工作是否完成
	select {
	case <-done:
		log.Infof("Goroutines exited normally")
	//就等3秒？
	case <-time.After(time.Second * 3):
		log.Infof("Timeout waiting goroutines to exit")
	}
	os.Exit(0)
}
```

11. replication的初始化，入口为` replication.Init(closing, done)` :
```go
func Init(closing, done chan struct{}) error {
	// init config
	secretKey, err := cfg.SecretKey()
	...
	//初始化replication组件需要的配置信息
	config.Config = &config.Configuration{
		CoreURL:          cfg.InternalCoreURL(),
		TokenServiceURL:  cfg.InternalTokenServiceEndpoint(),
		JobserviceURL:    cfg.InternalJobServiceURL(),
		SecretKey:        secretKey,
		CoreSecret:       cfg.CoreSecret(),
		JobserviceSecret: cfg.JobserviceSecret(),
	}
	// jobservice的默认client创建，封装了http.Client以及modifiers
	js := job.NewDefaultClient(config.Config.JobserviceURL, config.Config.CoreSecret)
	// init registry manager，实现了replication/registry的Manager接口，该接口用于对registry进行CRUD等
	RegistryMgr = registry.NewDefaultManager()
	// init policy controller，这个controller中包含了匿名接口字段policy.Controller以及字段scheduler.
	// 并将policy的DefaultManager（实现了policy.Controller），和实现Scheduler接口的scheduler封装进controller。
	PolicyCtl = controller.NewController(js)
	// init operation controller，这个controller实现了operation接口，该接口定义了和replication相关的操作，如start,stop等
	OperationCtl = operation.NewController(js)
	// init event handler
	EventHandler = event.NewHandler(PolicyCtl, RegistryMgr, OperationCtl)
	log.Debug("the replication initialization completed")
	
	//通过goroutine new后直接run，注意传入的参数closing和done
	go registry.NewHealthChecker(time.Minute*5, closing, done).Run()
	return nil
}
```
上述代码初始化了replication相关的组件，这里可以看到，**包外可见函数`Init`内执行了左右相关manager/controller的创建**，并且创建的过程**面向接口**编程。具体的依赖关系在`NewXXXX`内部完成，并将返回值最终以**包外可见**的全局变量对外暴露。然后看一下`registry.NewHealthChecker(time.Minute*5, closing, done).Run()`:
```go
// Run performs health check for all registries regularly
func (c *HealthChecker) Run() {
	interval := c.interval
	if c.interval < MinInterval {
		interval = MinInterval
	}

	// Wait some random time before starting health checking. If Harbor is deployed in HA mode
	// with multiple instances, this will avoid instances check health in the same time.
	<-time.After(time.Duration(rand.Int63n(int64(interval))))

	ticker := time.NewTicker(interval)
	log.Infof("Start regular health check for registries with interval %v", interval)
	for {
		select {
		case <-ticker.C:
			if err := c.manager.HealthCheck(); err != nil {
				log.Errorf("Health check error: %v", err)
				continue
			}
			log.Debug("Health Check succeeded")
		case <-c.closing:
			log.Info("Stop health checker")
			// No cleanup works to do, signal done directly
			close(c.done)
			return
		}
	}
}
```
可以看到healthy check是一个永真循环，通过ticker去定期调用各个需要同步相关的registry（可能是第三方）组件的adapter执行具体的health check。

12. notification的初始化，入口为` notification.Init()` :
```go
// Init ...
func Init() {
	// init notification policy manager
	PolicyMgr = manager.NewDefaultManger()
	// init hook manager
	HookManager = hook.NewHookManager()
	// init notification job manager
	JobMgr = jobMgr.NewDefaultManager()

	SupportedEventTypes = make(map[string]struct{})
	SupportedNotifyTypes = make(map[string]struct{})
	initSupportedEventType(
		model.EventTypePushImage, model.EventTypePullImage, model.EventTypeDeleteImage,
		model.EventTypeUploadChart, model.EventTypeDeleteChart, model.EventTypeDownloadChart,
		model.EventTypeScanningCompleted, model.EventTypeScanningFailed, model.EventTypeProjectQuota,
	)
	initSupportedNotifyType(model.NotifyTypeHTTP)
	log.Info("notification initialization completed")
}
```
[notification组件](harbor-registry-notification.md) 的主要作用就是在执行docker push等过程时，通知harbor执行如db持久化等逻辑。和replication一样，**组件内的耦合关系都在New函数中完成**。

13. event的初始化，入口为`event.Init()`:
```go
// Init the events for scan
func Init() {
	log.Debugf("Subscribe topic %s for cascade deletion of scan reports", model.DeleteImageTopic)

	err := notifier.Subscribe(model.DeleteImageTopic, NewOnDelImageHandler())
	if err != nil {
		log.Error(errors.Wrap(err, "register on delete image handler: init: scan"))
	}
}
```
event的作用为根据topic，执行注册的handler，使用场景可以参考[notification组件](harbor-registry-notification.md)

14. api相关的初始化，包括了filter和routers:
```go
	...
	filter.Init()
	beego.InsertFilter("/api/*", beego.BeforeStatic, filter.SessionCheck)
	beego.InsertFilter("/*", beego.BeforeRouter, filter.SecurityFilter)
	beego.InsertFilter("/*", beego.BeforeRouter, filter.ReadonlyFilter)
	initRouters()
	....
```
首先`filter.Init`中，创建了一个类型为`ReqCtxModifier`的数组，用于在http requset中修改上下文，并填充了各个认证模式的具体实现。然后注册了3个过滤器，最后的initRoutes则是beego的api定义。

15. 同步harbor中的资源，这里的同步逻辑是按照harbor registry的实际存储校对（校对只进行repo级，project默认无误），当db中的数据出现偏差，则执行db的delete/add等操作：
```go
func SyncRegistry(pm promgr.ProjectManager) error {

	log.Infof("Start syncing repositories from registry to DB... ")
	reposInRegistry, err := Catalog()
	...
	var repoRecordsInDB []*models.RepoRecord
	repoRecordsInDB, err = dao.GetRepositories()
	...
	var reposInDB []string
	for _, repoRecordInDB := range repoRecordsInDB {
		reposInDB = append(reposInDB, repoRecordInDB.Name)
	}

	var reposToAdd []string
	var reposToDel []string
	//获取difference
	reposToAdd, reposToDel, err = diffRepos(reposInRegistry, reposInDB, pm)
	...
	if len(reposToAdd) > 0 {
		log.Debugf("Start adding repositories into DB... ")
		for _, repoToAdd := range reposToAdd {
			project, _ := utils.ParseRepository(repoToAdd)
			pullCount, err := dao.CountPull(repoToAdd)
			...
			//如果project不存在，直接error
			pro, err := pm.Get(project)
			...
			repoRecord := models.RepoRecord{
				Name:      repoToAdd,
				ProjectID: pro.ProjectID,
				PullCount: pullCount,
			}

			if err := dao.AddRepository(repoRecord); err != nil {
				log.Errorf("Error happens when adding the missing repository: %v", err)
			} else {
				log.Debugf("Add repository: %s success.", repoToAdd)
			}
		}
	}
	if len(reposToDel) > 0 {
		log.Debugf("Start deleting repositories from DB... ")
		for _, repoToDel := range reposToDel {
			if err := dao.DeleteRepository(repoToDel); err != nil {
				log.Errorf("Error happens when deleting the repository: %v", err)
			} else {
				log.Debugf("Delete repository: %s success.", repoToDel)
			}
		}
	}

	log.Infof("Sync repositories from registry to DB is done.")
	return nil
}
```

log.Info("Init proxy")
	if err := middlewares.Init(); err != nil {
		log.Fatalf("init proxy error, %v", err)
	}

	syncQuota := os.Getenv("SYNC_QUOTA")
	doSyncQuota, err := strconv.ParseBool(syncQuota)
	if err != nil {
		log.Errorf("Failed to parse SYNC_QUOTA: %v", err)
		doSyncQuota = true
	}
	if doSyncQuota {
		if err := quotaSync(); err != nil {
			log.Fatalf("quota migration error, %v", err)
		}
	} else {
		log.Infof("Because SYNC_QUOTA set false , no need to sync quota \n")
	}

	log.Infof("Version: %s, Git commit: %s", version.ReleaseVersion, version.GitCommit)
	beego.Run()
