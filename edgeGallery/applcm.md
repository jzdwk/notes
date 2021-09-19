# applcm
applcm主要执行包的实例化工作。在业务流程中，该组件会在“沙箱部署”与“边缘节点（mecHost）部署”场景下被调用。

applcm位于mepm侧(注意，eg的mepm位于偏边缘侧，mepm的注册位于边缘节点管理处)，具体由**k8splugin和lcmcontroller**组成.

lcmcontroller接收appo或developer的http请求，通过accessToken认证鉴权，解析csar包获取要部署的mecHost，通过adapter使用grpc(作为grpc客户端)调用adapter具体实现（目前为k8splugin）k8splugin作为server接收后实例化。

## lcmcontroller

主要用于定义lcm涉及的接口，做认证鉴权和参数解析。下面以实例化app接口为入口，解析其实现，代码位于`lcmcontroller/controllers/lcm.go。`
```go
// @Title Instantiate application
// @Description Instantiate application
// @Param   hostIp          body 	string	true   "hostIp"
// @Param   appName         body 	string	true   "appName"
// @Param   packageId       body 	string	true   "packageId"
// @Param   tenantId        path 	string	true   "tenantId"
// @Param   appInstanceId   path 	string	true   "appInstanceId"
// @Param   access_token    header      string  true   "access token"
// @Success 200 ok
// @Failure 400 bad request
// @router /tenants/:tenantId/app_instances/:appInstanceId/instantiate [post]
func (c *LcmController) Instantiate() {
    //...request ip check
	...
	accessToken := c.Ctx.Request.Header.Get(util.AccessToken)
    //...parse request
	var req models.InstantiateRequest
	err = json.Unmarshal(c.Ctx.Input.RequestBody, &req)
	//...err handler
	...
	bKey := *(*[]byte)(unsafe.Pointer(&accessToken))
   //验证token，得到实例化所需的参数
	appInsId, tenantId, hostIp, packageId, appName, err := c.validateToken(accessToken, req, clientIp)
	...
	originVar, err := util.ValidateName(req.Origin, util.NameRegex)
	...
   //因为在实例化接口被调用之前，csar包的上传接口已经被提前调用(见developer-be的沙箱部署),因此DB中已有记录，在此做验证
	appPkgHostRecord := &models.AppPackageHostRecord{
		PkgHostKey: packageId + tenantId + hostIp,
	}
	readErr := c.Db.ReadData(appPkgHostRecord, util.PkgHostKey)
	//...empty & status check，如果包状态不是“Distributed”，抛错
	...
	appInfoRecord := &models.AppInfoRecord{
		AppInstanceId: appInsId,
	}
    //根据appInstId读取DB中存的appInfo记录，如果已存在，说明被实例化过，抛错
	readErr = c.Db.ReadData(appInfoRecord, util.AppInsId)
	if readErr == nil {
		c.HandleLoggingForError(clientIp, util.BadRequest,
			"App instance info record already exists")
		util.ClearByteArray(bKey)
		return
	}
    //根据hostIp，从DB中获取mecHost的记录，判断其IaaS类型，k8s 还是 vm
	vim, err := c.getVim(clientIp, hostIp)
	...
   //从环境变量，获取plugin地址addr:port
	pluginInfo := util.GetPluginInfo(vim)
 	//创建plugin的grpc客户端
   client, err := pluginAdapter.GetClient(pluginInfo)
	//...生成ak sk
	err, acm := processAkSkConfig(appInsId, appName, &req, clientIp, tenantId)
	...
```

具体看一下AkSk的处理：
```go
// Process Ak Sk configuration
func processAkSkConfig(appInsId, appName string, req *models.InstantiateRequest, clientIp string,
	tenantId string) (error, config.AppConfigAdapter) {
	var applicationConfig config.ApplicationConfig
    //初始化一个appAuthConfig，如果实例化请求中如果没有携带ak sk，则lcm生成后赋值
	appAuthConfig := config.NewAppAuthCfg(appInsId)
	if req.Parameters["ak"] == "" || req.Parameters["sk"] == "" {
		err := appAuthConfig.GenerateAkSK()
		...
		req.Parameters["ak"] = appAuthConfig.Ak
		req.Parameters["sk"] = appAuthConfig.Sk
		req.AkSkLcmGen = true
	} else {
		appAuthConfig.Ak = req.Parameters["ak"]
		appAuthConfig.Sk = req.Parameters["sk"]
		req.AkSkLcmGen = false
	}
   //解析csar包，获取appConfigFile
	appConfigFile, err := getApplicationConfigFile(tenantId, req.PackageId)
	...
	configYaml, err := os.Open(PackageFolderPath + tenantId + "/" + req.PackageId + "/APPD/" + appConfigFile)
	...
	data, err := yaml.YAMLToJSON(mfFileBytes)
	...
	err = json.Unmarshal(data, &applicationConfig)
	...
    //封装appConfigAdapter,包括了auth信息和基本信息
   // type AppConfigAdapter struct {
    	//AppAuthCfg AppAuthConfig
    	//AppInfo    AppInfo
    //}
    //其中的auth信息包括了ak sk，用于在服务被部署后，生成访问mep边缘能力的token使用
	acm := config.NewAppConfigMgr(appInsId, appName, appAuthConfig, applicationConfig)
   //从环境变量读取 APIGW_ADDR，调用apigw的PUT /mep/appMng/v1/applications/{appInstanceId}/confs 配置app的Auth信息
	err = acm.PostAppAuthConfig(clientIp)
	...
	return nil, acm
}
```
继续回到上层，执行db记录和调用plugin执行实例化：
```go
    //更新该租户的记录条目信息
    err = c.insertOrUpdateTenantRecord(clientIp, tenantId)
	...
	var appInfoParams models.AppInfoRecord
	appInfoParams.AppInstanceId = appInsId
	appInfoParams.MecHost = hostIp

	appInfoParams.TenantId = tenantId
	appInfoParams.AppPackageId = packageId
	appInfoParams.AppName = appName
	appInfoParams.Origin = req.Origin
    //添加DB记录
	err = c.insertOrUpdateAppInfoRecord(clientIp, appInfoParams)
	...
    //grpc调用plugin，执行实例部署
	adapter := pluginAdapter.NewPluginAdapter(pluginInfo, client)
   //内部具体调用 status, err := c.client.Instantiate(ctx, tenantId, accessToken, appInsId, req)
    err, status := adapter.Instantiate(tenantId, accessToken, appInsId, req)
	util.ClearByteArray(bKey)
	...
	c.handleLoggingForSuccess(clientIp, "Application instantiated successfully")
	c.ServeJSON()
}
```
## k8splugin

k8splugin作为实例化应用的服务端， 提供grpc接口，负责对k8s平台的应用进行部署编排。
接口定义

grpc接口proto定义`k8splugin/internal/lcmservice/lcmservice.proto`：
```go
service AppLCM {
  rpc instantiate (InstantiateRequest) returns (InstantiateResponse) {}
  rpc terminate (TerminateRequest) returns (TerminateResponse) {}
  rpc query (QueryRequest) returns (QueryResponse) {}
  rpc uploadConfig (stream UploadCfgRequest) returns (UploadCfgResponse) {}
  rpc removeConfig (RemoveCfgRequest) returns (RemoveCfgResponse) {}
  rpc workloadEvents (WorkloadEventsRequest) returns (WorkloadEventsResponse) {}
  rpc uploadPackage (stream UploadPackageRequest) returns (UploadPackageResponse) {}
  rpc deletePackage (DeletePackageRequest) returns (DeletePackageResponse) {}
}

service VmImage {
  rpc createVmImage(CreateVmImageRequest) returns (CreateVmImageResponse) {}
  rpc queryVmImage(QueryVmImageRequest) returns (QueryVmImageResponse) {}
  rpc deleteVmImage(DeleteVmImageRequest) returns (DeleteVmImageResponse) {}
  rpc downloadVmImage(DownloadVmImageRequest) returns (stream DownloadVmImageResponse) {}
}
```
### 服务注册
grpc服务注册位于main.go中的Linsten函数：
```go
// Start GRPC server and start listening on the port
func (s *ServerGRPC) Listen() (err error) {
	// Listen announces on the network address
	listener, err = net.Listen("tcp", s.address+":"+s.port)
    ...
	if !s.serverConfig.SslNotEnabled {
		tlsConfig, err := util.GetTLSConfig(s.serverConfig, s.certificate, s.key)
		...
		// Create the TLS credentials
		creds := credentials.NewTLS(tlsConfig)
		// Create server with TLS credentials
		s.server = grpc.NewServer(grpc.Creds(creds), grpc.InTapHandle(NewRateLimit().Handler))
	} else {
		// Create server without TLS credentials
		s.server = grpc.NewServer(grpc.InTapHandle(NewRateLimit().Handler))
	}
   //将ServerGRPC注册为grpc服务接口的实现
	lcmservice.RegisterAppLCMServer(s.server, s)
	// Server start serving
	err = s.server.Serve(listener)
	...
	return
}
```
### 实例化实现
k8splugin的服务端接口实现位于`k8splugin/pkg/server/grpcserver.go`，初始化函数为：
```go
// GRPC server
type ServerGRPC struct {
	server       *grpc.Server
	port         string
	address      string
	certificate  string
	key          string
	db           pgdb.Database
	serverConfig *conf.ServerConfigurations
}
// Constructor to GRPC server
func NewServerGRPC(cfg ServerGRPCConfig) (s ServerGRPC) {
	s.port = cfg.Port
	s.address = cfg.Address
	s.certificate = cfg.ServerConfig.CertFilePath
	s.key = cfg.ServerConfig.KeyFilePath
	s.serverConfig = cfg.ServerConfig
	dbAdapter, err := pgdb.GetDbAdapter(cfg.ServerConfig)
	...
	s.db = dbAdapter
	return
}
```
#### 1. DB操作
以实例化函数入口实现为例：
```go
func (s *ServerGRPC) Instantiate(ctx context.Context,
	req *lcmservice.InstantiateRequest) (resp *lcmservice.InstantiateResponse, err error) {
    //init 返回数据，打印clientIP等信息，解析请求参数
	...
    err = s.displayReceivedMsg(ctx, util.Instantiate)
	...
    tenantId, packageId, hostIp, appInsId, ak, sk, err := s.validateInputParamsForInstantiate(req)
	...
	appPkgRecord := &models.AppPackage{
		AppPkgId: packageId + tenantId + hostIp,
	}
    //读取csar包记录
	readErr := s.db.ReadData(appPkgRecord, util.AppPkgId)
	...
	// 返回一个封装的HelmClient，其定义为：
   // type HelmClient struct {
	//   HostIP     string
	//   Kubeconfig string
   //}
	client, err := adapter.GetClient(util.DeployType, hostIp)
   //执行deploy
	releaseName, namespace, err := client.Deploy(appPkgRecord, appInsId, ak, sk, s.db)
   //...
	err = s.insertOrUpdateAppInsRecord(appInsId, hostIp, releaseName, namespace)
	resp.Status = util.Success
	s.handleLoggingForSuccess(ctx, util.Instantiate, "Application instantiated successfully")
	return resp, nil
}
```
#### 2. Helm Deploy

进入Deploy函数，其实现即调用helm的sdk去部署chart包：
```go
// Install a given helm chart
func (hc *HelmClient) Deploy(appPkgRecord *models.AppPackage, appInsId, ak, sk string, db pgdb.Database) (string, string, error) {
    //解析csar包的helm chart包
	helmChart, err := hc.getHelmChart(appPkgRecord.TenantId, appPkgRecord.HostIp, appPkgRecord.PackageId)
	tarFile, err := os.Open(helmChart)
    ...
    //封装一个appAuthConfig对象，该对象实现了将ak sk信息填写入chart包的values.yaml
    //这个chart包中包含了服务间认证需要的secret资源，此处即将ak sk写入secret，之后mep-agent会读取该值，用于调用mep边缘能力
	appAuthCfg := config.NewBuildAppAuthConfig(appInsId, ak, sk)
	//解析chart包，将sk sk赋值给chart的values.yaml
   dirName, namespace, err := appAuthCfg.AddValues(tarFile)
	//...log 
	// load chart包至一个chart结构体
	chart, err := loader.Load(dirName + ".tar.gz")
	...
   //如果ns不是default，首先使用client-go创建ns
	if namespace != util.Default {
    	// uses the current context in kubeconfig
		kubeConfig, err := clientcmd.BuildConfigFromFlags("", hc.Kubeconfig)
		clientSet, err := kubernetes.NewForConfig(kubeConfig)
		nsName := &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: namespace,
			},
		}
           ...
		_, err = clientSet.CoreV1().Namespaces().Create(context.Background(), nsName, metav1.CreateOptions{})
	}

	// Release name will be taken from the name in chart's metadata
	relName := chart.Metadata.Name
	...//check db， 在db中检查appName是否已存在，存在说明已被初始化，报错
   ...
	// Initialize action config，调用helm sdk
	actionConfig := new(action.Configuration)
	if err := actionConfig.Init(kube.GetConfig(hc.Kubeconfig, "", namespace), namespace,
		util.HelmDriver, func(format string, v ...interface{}) {
			//log func define...
		});...
	}

	// Prepare chart install action and install chart
	installer := action.NewInstall(actionConfig)
	installer.Namespace = namespace 
   // so if we want to deploy helm charts via k8splugin.. 
   //first namespace should be created or exist then we can deploy helm charts in that namespace
	installer.ReleaseName = relName
   //直接调用helm sdk的run
	rel, err := installer.Run(chart, nil)
	//... if err, uninstall app
	//return  appName, namespace
	return rel.Name, namespace, err
}
```
