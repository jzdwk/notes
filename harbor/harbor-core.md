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

9. 初始化api模块，

	password, err := config.InitialAdminPassword()
	if err != nil {
		log.Fatalf("failed to get admin's initial password: %v", err)
	}
	if err := updateInitPassword(adminUserID, password); err != nil {
		log.Error(err)
	}

	// Init API handler
	if err := api.Init(); err != nil {
		log.Fatalf("Failed to initialize API handlers with error: %s", err.Error())
	}

	if config.WithClair() {
		clairDB, err := config.ClairDB()
		if err != nil {
			log.Fatalf("failed to load clair database information: %v", err)
		}
		if err := dao.InitClairDB(clairDB); err != nil {
			log.Fatalf("failed to initialize clair database: %v", err)
		}

		reg := &scanner.Registration{
			Name:            "Clair",
			Description:     "The clair scanner adapter",
			URL:             config.ClairAdapterEndpoint(),
			UseInternalAddr: true,
			Immutable:       true,
		}

		if err := scan.EnsureScanner(reg, true); err != nil {
			log.Fatalf("failed to initialize clair scanner: %v", err)
		}
	} else {
		if err := scan.RemoveImmutableScanners(); err != nil {
			log.Warningf("failed to remove immutable scanners: %v", err)
		}
	}

	closing := make(chan struct{})
	done := make(chan struct{})
	go gracefulShutdown(closing, done)
	if err := replication.Init(closing, done); err != nil {
		log.Fatalf("failed to init for replication: %v", err)
	}

	log.Info("initializing notification...")
	notification.Init()
	// Initialize the event handlers for handling artifact cascade deletion
	event.Init()

	filter.Init()
	beego.InsertFilter("/api/*", beego.BeforeStatic, filter.SessionCheck)
	beego.InsertFilter("/*", beego.BeforeRouter, filter.SecurityFilter)
	beego.InsertFilter("/*", beego.BeforeRouter, filter.ReadonlyFilter)

	initRouters()

	syncRegistry := os.Getenv("SYNC_REGISTRY")
	sync, err := strconv.ParseBool(syncRegistry)
	if err != nil {
		log.Errorf("Failed to parse SYNC_REGISTRY: %v", err)
		// if err set it default to false
		sync = false
	}
	if sync {
		if err := api.SyncRegistry(config.GlobalProjectMgr); err != nil {
			log.Error(err)
		}
	} else {
		log.Infof("Because SYNC_REGISTRY set false , no need to sync registry \n")
	}

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

}
```