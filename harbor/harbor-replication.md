# harbor replication

harbor的执行镜像同步需要以下3步：

1. 创建需要同步的目标registry，只需要提供目标registry地址和认证信息

2. 创建同步策略policy，策略中主要描述了同步方式（pull/push），需要同步的资源范围（project/image/tag）以及上一步注册的registry地址

3. 根据policy执行同步策略。

详细操作可以参考[harbor replication doc](https://goharbor.io/docs/1.10/administration/configuring-replication/)

## registry create

registry的创建只是在db中记录信息，不再赘述。代码位于`core`中rest api的Post方法:
```go
	beego.Router("/api/registries", &api.RegistryAPI{}, "get:List;post:Post")
```
相应的model定义如下：
```go
type Registry struct {
	ID          int64        `json:"id"`
	//registry名称
	Name        string       `json:"name"`
	Description string       `json:"description"`
	//registry类型，harbor,docker-hub等
	Type        RegistryType `json:"type"`
	//地址
	URL         string       `json:"url"`
	//用于防止将本地的harbor请求转发至外部
	TokenServiceURL string      `json:"token_service_url"`
	//认证信息
	Credential      *Credential `json:"credential"`
	Insecure        bool        `json:"insecure"`
	Status          string      `json:"status"`
	CreationTime    time.Time   `json:"creation_time"`
	UpdateTime      time.Time   `json:"update_time"`
}
```
harbor的replication。Registry模块中，将业务操作通过manager接口向外暴露，即使用了**门面模式**。这类似于传统java ERP项目中的service层,并通过controller调用`id, err := t.manager.Add(r)`。而managet接口的初始化在`replication/replication.go`的init函数中完成，并通过prepare函数赋值给`RegistryAPI`，类比于java中service bean的注入：
```go
//1. init default manager
var (
	...
	RegistryMgr registry.Manager
	...
)
func Init(closing, done chan struct{}) error {
	...
	RegistryMgr = registry.NewDefaultManager()
	...
}

//2. 
func (t *RegistryAPI) Prepare() {
	...
	t.manager = replication.RegistryMgr
	...
}
```

## policy create

policy的创建类似于registry，位于`beego.Router("/api/replication/policies", &api.ReplicationPolicyAPI{}, "get:List;post:Create")`中的Create函数。其中policy的定义如下：
```go
type Policy struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Creator     string `json:"creator"`
	//源registry pull方式使用
	SrcRegistry *Registry `json:"src_registry"`
	//目标registry push使用
	DestRegistry *Registry `json:"dest_registry"`
	//目标的project push使用
	DestNamespace string `json:"dest_namespace"`
	//过滤器 pull使用
	Filters []*Filter `json:"filters"`
	//触发模式，手动，定时，事件驱动(image push/pull时)
	Trigger *Trigger `json:"trigger"`
	
	Deletion bool `json:"deletion"`
	//资源覆盖
	Override bool `json:"override"`
	//启用
	Enabled      bool      `json:"enabled"`
	CreationTime time.Time `json:"creation_time"`
	UpdateTime   time.Time `json:"update_time"`
}
```
此处注意harbor的编码风格，对于本模块的调用，都使用前文提到的`manager`，而对于registry调用的其他模块，比如policy，则使用controller对其封装：
```go
//1.创建policy的controller
func NewController(js job.Client) policy.Controller {
	mgr := manager.NewDefaultManager()
	scheduler := scheduler.NewScheduler(js)
	ctl := &controller{
		scheduler: scheduler,
	}
	ctl.Controller = mgr
	return ctl
}
//2.init处初始化
func Init(closing, done chan struct{}) error {
	...
	js := job.NewDefaultClient(config.Config.JobserviceURL, config.Config.CoreSecret)
	// init registry manager
	RegistryMgr = registry.NewDefaultManager()
	// init policy controller
	PolicyCtl = controller.NewController(js)
	...
	return nil
}
```
另外注意，所有的post方法在最后都使用了`redirect`方式返回success，比如`	r.Redirect(http.StatusCreated, strconv.FormatInt(id, 10))`。此为**web PRG模式**，[具体参考](https://www.cnblogs.com/TonyYPZhang/p/5424201.html) 

## execute replication

执行replication的操作位于`policy`处，入口为`beego.Router("/api/replication/executions", &api.ReplicationOperationAPI{}, "get:ListExecutions;post:CreateExecution")`函数，函数首先根据execution实体，获取policy以及policy的registry信息，以及trigger策略，最终调用operation包中的controller接口`StartReplication(policy *model.Policy, resource *model.Resource, trigger model.TriggerType) (int64, error)`，接口的具体实现由controller结构完成，controller中封装了执行policy的各个组件，通过New函数对外暴露：
```go
func NewController(js job.Client) Controller {
	ctl := &controller{
		replicators:  make(chan struct{}, maxReplicators),
		executionMgr: execution.NewDefaultManager(),
		scheduler:    scheduler.NewScheduler(js),
		flowCtl:      flow.NewController(),
	}
	for i := 0; i < maxReplicators; i++ {
		ctl.replicators <- struct{}{}
	}
	return ctl
}

type controller struct {
	//通过一个chan，来约束允许的最大执行同步任务的数量
	replicators  chan struct{}
	flowCtl      flow.Controller
	executionMgr execution.Manager
	scheduler    scheduler.Scheduler
}
```
回到startReplication函数，实现如下：
```go
func (c *controller) StartReplication(policy *model.Policy, resource *model.Resource, trigger model.TriggerType) (int64, error) {
	//policy check
	...
	//db中记录execution数据
	id, err := createExecution(c.executionMgr, policy.ID, trigger)
	...
	//从replicator中读取对象，如果chan中已无数据，则阻塞
	<-c.replicators
	go func() {
		//执行结束后，向chan归还一个对象
		defer func() {
			c.replicators <- struct{}{}
		}()
		//createFlow返回一个flow接口，由于resource为nil，因此返回了copyFlow对象
		//copyFlow对c.executionMgr, c.scheduler, executionID, policy, 空resources切片进行封装
		flow := c.createFlow(id, policy, resource)
		//start调用了flow接口的run
		if n, err := c.flowCtl.Start(flow); err != nil {
			//如果执行失败，更新execution实体的状态信息
			if e := c.executionMgr.Update(&models.Execution{
				ID:         id,
				Status:     models.ExecutionStatusFailed,
				StatusText: err.Error(),
				Total:      n,
				Failed:     n,
			}, "Status", "StatusText", "Total", "Failed"); e != nil {
				log.Errorf("failed to update the execution %d: %v", id, e)
			}
			log.Errorf("the execution %d failed: %v", id, err)
		}
	}()
	return id, nil
}
```
以上代码首先通过一个chan来控制可执行的同步任务数，然后通过go routine开启任务，*思考？为什么这里使用了flowCtl对flow的执行进行了封装？* 最终的任务执行为调用copyFlow的Run方法： 	
```go
func (c *copyFlow) Run(interface{}) (int, error) {
	//1. create adapter
	srcAdapter, dstAdapter, err := initialize(c.policy)
	...
	var srcResources []*model.Resource
	if len(c.resources) > 0 {
		srcResources, err = filterResources(c.resources, c.policy.Filters)
	} else {
		srcResources, err = fetchResources(srcAdapter, c.policy)
	}
	if err != nil {
		return 0, err
	}

	isStopped, err := isExecutionStopped(c.executionMgr, c.executionID)
	if err != nil {
		return 0, err
	}
	if isStopped {
		log.Debugf("the execution %d is stopped, stop the flow", c.executionID)
		return 0, nil
	}

	if len(srcResources) == 0 {
		markExecutionSuccess(c.executionMgr, c.executionID, "no resources need to be replicated")
		log.Infof("no resources need to be replicated for the execution %d, skip", c.executionID)
		return 0, nil
	}

	srcResources = assembleSourceResources(srcResources, c.policy)
	dstResources := assembleDestinationResources(srcResources, c.policy)

	if err = prepareForPush(dstAdapter, dstResources); err != nil {
		return 0, err
	}
	items, err := preprocess(c.scheduler, srcResources, dstResources)
	if err != nil {
		return 0, err
	}
	if err = createTasks(c.executionMgr, c.executionID, items); err != nil {
		return 0, err
	}

	return schedule(c.scheduler, c.executionMgr, items)
}
```
1. **create adapter**

执行Run函数的第一步，为获取目标和源registry的adapter，adapter为适配器接口，其定义如下：
```go
type Adapter interface {
	// Info return the information of this adapter
	Info() (*model.RegistryInfo, error)
	// PrepareForPush does the prepare work that needed for pushing/uploading the resources
	// eg: create the namespace or repository
	PrepareForPush([]*model.Resource) error
	// HealthCheck checks health status of registry
	HealthCheck() (model.HealthStatus, error)
}
```
如果需要harbor支持某厂家的registry产品，就要定义adapter的实现。initialize函数根据policy的内容去获取对应的adapter，具体代码:
```go
func initialize(policy *model.Policy) (adp.Adapter, adp.Adapter, error) {
	var srcAdapter, dstAdapter adp.Adapter
	var err error
	//根据policy中存放的目标registry的类型（即厂家）去获取对应的factory
	srcFactory, err := adp.GetFactory(policy.SrcRegistry.Type)
	...
	//根据不同厂家的factory生产adapter，这里就是个简单工厂
	srcAdapter, err = srcFactory.Create(policy.SrcRegistry)
	...
}
```
上述代码首先根据policy中存放的目标registry的类型去获取对应的factory。factory接口用于创建不同registry的适配器接口，位于`replication/adapter/adapter.go`：
```go
type Factory interface {
	Create(*model.Registry) (Adapter, error)
	AdapterPattern() *model.AdapterPattern
}
```   
factory的实现由支持的各个厂家registry提供，通过init初始化对应的factory，比如华为位于`src/replication/adapter/huawei/` :
```go
func init() {
	err := adp.RegisterFactory(model.RegistryTypeHuawei, new(factory))
	if err != nil {
		log.Errorf("failed to register factory for Huawei: %v", err)
		return
	}
	log.Infof("the factory of Huawei adapter was registered")
}
```
下面以harbor自身为例，根据harbor的factory，adapter创建过程如下：
```go
func newAdapter(registry *model.Registry) (*adapter, error) {
	//根据registry的http/s创建http transport
	transport := util.GetHTTPTransport(registry.Insecure)
	//Modifier接口用于对http请求内容进行更换/更新
	modifiers := []modifier.Modifier{
		&auth.UserAgentModifier{
			UserAgent: adp.UserAgentReplication,
		},
	}
	//根据认证信息，向modifier中增加认证相关的k-v对
	if registry.Credential != nil {
		var authorizer modifier.Modifier
		if registry.Credential.Type == model.CredentialTypeSecret {
			authorizer = common_http_auth.NewSecretAuthorizer(registry.Credential.AccessSecret)
		} else {
			authorizer = auth.NewBasicAuthCredential(
				registry.Credential.AccessKey,
				registry.Credential.AccessSecret)
		}
		modifiers = append(modifiers, authorizer)
	}
	//根据registry生成docker registry的adapter，此处涉及了docker registry的认证
	dockerRegistryAdapter, err := native.NewAdapter(registry)
	...
	return &adapter{
		registry: registry,
		url:      registry.URL,
		//这个client封装了http client以及设置的modifier
		client: common_http.NewClient(
			&http.Client{
				Transport: transport,
			}, modifiers...),
		Adapter: dockerRegistryAdapter,
	}, nil
}
```
以上代码中着重关注`dockerRegistryAdapter, err := native.NewAdapter(registry)`，该函数主要工作是根据registry属性创建了credential以及根据token service地址封装了一个tokenAuthorizer，主要是用于获取token，docker auth流程可以[参考](harbor-registry-auth.md) ，这个tokenAuthorizer实现了modify接口，查看modify方法，可以看到tokenAuthorizer通过credential信息得到token后，添加至req的header:
```go
// add token to the request
func (t *tokenAuthorizer) Modify(req *http.Request) error {
	// only handle requests sent to registry
	goon, err := t.filterReq(req)
	...
	// parse scopes from request
	scopes, err := parseScopes(req)
	var token *models.Token
	// try to get token from cache if the request is for empty scope(login)
	// or single scope
	if len(scopes) <= 1 {
		key := ""
		if len(scopes) == 1 {
			key = scopeString(scopes[0])
		}
		token = t.getCachedToken(key)
	}

	if token == nil {
		//根据registry中的registry地址，发送credential信息，并得到token
		token, err = t.generator.generate(scopes, t.registryURL.String())
		...
		// if the token is null(this happens if the registry needs no authentication), return
		// directly. Or the token will be cached
		...
		// only cache the token for empty scope(login) or single scope request
		if len(scopes) <= 1 {
			key := ""
			if len(scopes) == 1 {
				key = scopeString(scopes[0])
			}
			t.updateCachedToken(key, token)
		}
	}

	tk := token.GetToken()
	...
	req.Header.Add(http.CanonicalHeaderKey("Authorization"), fmt.Sprintf("Bearer %s", tk))
	return nil
}
```
最终调用`NewAdapterWithCustomizedAuthorizer(registry, authorizer)`,该函数根据中需要注意的就是根据加入的各个modifier对象去对req做扩充，最终返回一个Adapter实现：
```go
func NewAdapterWithCustomizedAuthorizer(registry *model.Registry, authorizer modifier.Modifier) (*Adapter, error) {
	transport := util.GetHTTPTransport(registry.Insecure)
	modifiers := []modifier.Modifier{
		&auth.UserAgentModifier{
			//harbor-replication-service
			UserAgent: adp.UserAgentReplication,
		},
	}
	//将authorizer加入modify
	if authorizer != nil {
		modifiers = append(modifiers, authorizer)
	}
	client := &http.Client{
		Transport: registry_pkg.NewTransport(transport, modifiers...),
	}
	reg, err := registry_pkg.NewRegistry(registry.URL, client)
	...
	return &Adapter{
		Registry: reg,
		registry: registry,
		client:   client,
		clients:  map[string]*registry_pkg.Repository{},
	}, nil
}
```
dockerRegistryAdapter创建完成后，将其封装至harbor的adapter实现后，adapter的创建整体完成。由于各个adapter的创建过程大体相似，这里不再赘述。至此，create adapter完成。

2. **resource**
adapter创建完成后，接下来需要根据在policy中描述的filter信息获取需要执行同步的资源集合，即执行`fetchResources(adapter adp.Adapter, policy *model.Policy) ([]*model.Resource, error)`过程:
```go
func fetchResources(adapter adp.Adapter, policy *model.Policy) ([]*model.Resource, error) {
	var resTypes []model.ResourceType
	var filters []*model.Filter
	//根据policy的定义，确定resource的类型集合，比如image/chart包
	for _, filter := range policy.Filters {
		if filter.Type != model.FilterTypeResource {
			filters = append(filters, filter)
			continue
		}
		resTypes = append(resTypes, filter.Value.(model.ResourceType))
	}
	if len(resTypes) == 0 {
		//获取具体adapter实现的registry信息，包括了registry支持的资源等
		info, err := adapter.Info()
		...
		resTypes = append(resTypes, info.SupportedResourceTypes...)
	}

	resources := []*model.Resource{}
	for _, typ := range resTypes {
		var res []*model.Resource
		var err error
		if typ == model.ResourceTypeImage {
			// images
			reg, ok := adapter.(adp.ImageRegistry)
			...
			//具体的fetch实现
			res, err = reg.FetchImages(filters)
		} else if typ == model.ResourceTypeChart {
			// charts
			reg, ok := adapter.(adp.ChartRegistry)
			...
			res, err = reg.FetchCharts(filters)
		} else {
			...
		}
		...
		resources = append(resources, res...)
	}
	return resources, nil
}
```
上述代码的重点为`reg, ok := adapter.(adp.ImageRegistry)&&res, err = reg.FetchImages(filters)`**这两句，每个厂家的adapter中都存在匿名的`native.Adapter`结构，后者实现了ImageRegistry/ChartRegistry接口，因此，adapter可以类型转换为对应的接口，同时继承了native.Adapter的方法**，接口的定义如下：
```go
// ImageRegistry defines the capabilities that an image registry should have
type ImageRegistry interface {
	//获取Image信息，在harbor发送同步任务时用到
	FetchImages(filters []*model.Filter) ([]*model.Resource, error)
	//后续的接口都在job service处执行同步任务时调用
	ManifestExist(repository, reference string) (exist bool, digest string, err error)
	PullManifest(repository, reference string, accepttedMediaTypes []string) (manifest distribution.Manifest, digest string, err error)

	PushManifest(repository, reference, mediaType string, payload []byte) error
	// the "reference" can be "tag" or "digest", the function needs to handle both
	DeleteManifest(repository, reference string) error
	BlobExist(repository, digest string) (exist bool, err error)
	PullBlob(repository, digest string) (size int64, blob io.ReadCloser, err error)
	PushBlob(repository, digest string, size int64, blob io.Reader) error
}

// ChartRegistry defines the capabilities that a chart registry should have
type ChartRegistry interface {
	FetchCharts(filters []*model.Filter) ([]*model.Resource, error)
	ChartExist(name, version string) (bool, error)
	DownloadChart(name, version string) (io.ReadCloser, error)
	UploadChart(name, version string, chart io.Reader) error
	DeleteChart(name, version string) error
}
```

每一个resource的最终对象对应了project。最终返回的resources定义如下：
```go
type Resource struct {
	//资源类型,比如chart/image等
	Type         ResourceType           `json:"type"`
	//具体的资源描述
	Metadata     *ResourceMetadata      `json:"metadata"`
	//对应的registry描述，比如harbor 或其他私有仓库
	Registry     *Registry              `json:"registry"`
	//额外需要存储的信息
	ExtendedInfo map[string]interface{} `json:"extended_info"`
	// Indicate if the resource is a deleted resource
	Deleted bool `json:"deleted"`
	// indicate whether the resource can be overridden
	Override bool `json:"override"`
}
// ResourceMetadata of resource
type ResourceMetadata struct {
	//repo信息，名称为{peojectName}/{repoName}
	Repository *Repository `json:"repository"`
	//某一个repo下，具体要操作的资源集合，比如iamge的tag, chart的version等
	Artifacts  []*Artifact `json:"artifacts"`
	Vtags      []string    `json:"v_tags"` // deprecated, use Artifacts instead
}
// Repository info of the resource
type Repository struct {
    //名称为{peojectName}/{repoName}
	Name     string                 `json:"name"`
	//所属project的metadata
	Metadata map[string]interface{} `json:"metadata"`
}
// Artifact is the individual unit that can be replicated
type Artifact struct {
	Type   string   `json:"type"`
	Digest string   `json:"digest"`
	Labels []string `json:"labels"`
	//image的最小单元，chart的version和image的tag都由此字段描述
	Tags   []string `json:"tags"`
}
```
上述代码完成了srcResources对于policy中描述的资源的fetch，接下来继续对resource的字段进行赋值：
```go
	//将policy描述的源registry赋值给srcResource的Registry字段
	srcResources = assembleSourceResources(srcResources, c.policy)
	//将srcResource中描述的资源的各个信息赋值给dstResources，即同步后，源和目的registry的project/image/tag是相同的，
	//另外将policy的destRegistry赋值给dstResources
	dstResources := assembleDestinationResources(srcResources, c.policy)
```

3. **prepare**

当adapter和resource都完成后，将进行同步前的prepare工作，prepare的工作由adapter接口的`PrepareForPush([]*model.Resource) error`函数完成，这个函数由各个厂家的adapter具体实现，主要作用就是调用各自的api，创建诸如project等资源对象，以harbor为例：
```go
func (a *adapter) PrepareForPush(resources []*model.Resource) error {
	projects := map[string]*project{}
	for _, resource := range resources {
		...resource check
		//
		paths := strings.Split(resource.Metadata.Repository.Name, "/")
		projectName := paths[0]
		//如果是public项目，并且在map存在，进行合并
		metadata := abstractPublicMetadata(resource.Metadata.Repository.Metadata)
		pro, exist := projects[projectName]
		if exist {
			metadata = mergeMetadata(pro.Metadata, metadata)
		}
		projects[projectName] = &project{
			Name:     projectName,
			Metadata: metadata,
		}
	}
	//调用harbor api, 创建project
	for _, project := range projects {
		pro := struct {
			Name     string                 `json:"project_name"`
			Metadata map[string]interface{} `json:"metadata"`
		}{
			Name:     project.Name,
			Metadata: project.Metadata,
		}
		err := a.client.Post(a.getURL()+"/api/projects", pro)
		...err handle
		log.Debugf("project %s created", project.Name)
	}
	return nil
}
```

此时，要同步的资源描述resource以及在各个厂家registry的db型描述都已就绪，在执行同步任务之前，对要同步的资源逐条（project为单位）封装至`ScheduleItem`,这个字段维护源和目的project的1/1关系。这一步是在`preprocess`完成：
```go
// Preprocess the resources and returns the item list that can be scheduled
func (d *defaultScheduler) Preprocess(srcResources []*model.Resource, destResources []*model.Resource) ([]*ScheduleItem, error) {
	//check resource
	...
	var items []*ScheduleItem
	for index, srcResource := range srcResources {
		destResource := destResources[index]
		item := &ScheduleItem{
			SrcResource: srcResource,
			DstResource: destResource,
		}
		items = append(items, item)

	}
	return items, nil
}
```
之后，创建task任务，用于向jobservice发送任务:
```go
func createTasks(mgr execution.Manager, executionID int64, items []*scheduler.ScheduleItem) error {
	for _, item := range items {
		//task类型
		operation := "copy"
		if item.DstResource.Deleted {
			operation = "deletion"
		}

		task := &models.Task{
			ExecutionID:  executionID,
			Status:       models.TaskStatusInitialized,
			ResourceType: string(item.SrcResource.Type),
			SrcResource:  getResourceName(item.SrcResource),
			DstResource:  getResourceName(item.DstResource),
			Operation:    operation,
		}
		//db保存
		id, err := mgr.CreateTask(task)
		...
		item.TaskID = id
		log.Debugf("task record %d for the execution %d created", id, executionID)
	}
	return nil
}
```

4. **schedule**

最后，执行定义的items，具体的执行将交给[job service](harbor-job-service.md)完成：
```go
func schedule(scheduler scheduler.Scheduler, executionMgr execution.Manager, items []*scheduler.ScheduleItem) (int, error) {
	//将封装job-service的具体job，并通过SubmitJob(j)提交任务。注意，每一个project对应着一个job
	results, err := scheduler.Schedule(items)
	...
	allFailed := true
	n := len(results)
	for _, result := range results {
		// if the task is failed to be submitted, update the status of the
		// task as failure
		now := time.Now()
		if result.Error != nil {
			log.Errorf("failed to schedule the task %d: %v", result.TaskID, result.Error)
			if err = executionMgr.UpdateTask(&models.Task{
				ID:      result.TaskID,
				Status:  models.TaskStatusFailed,
				EndTime: now,
			}, "Status", "EndTime"); err != nil {
				log.Errorf("failed to update the task status %d: %v", result.TaskID, err)
			}
			continue
		}
		allFailed = false
		// if the task is submitted successfully, update the status, job ID and start time
		if err = executionMgr.UpdateTaskStatus(result.TaskID, models.TaskStatusPending, 0, models.TaskStatusInitialized); err != nil {
			log.Errorf("failed to update the task status %d: %v", result.TaskID, err)
		}
		if err = executionMgr.UpdateTask(&models.Task{
			ID:        result.TaskID,
			JobID:     result.JobID,
			StartTime: now,
		}, "JobID", "StartTime"); err != nil {
			log.Errorf("failed to update the task %d: %v", result.TaskID, err)
		}
		log.Debugf("the task %d scheduled", result.TaskID)
	}
	// if all the tasks are failed, return err
	if allFailed {
		return n, errors.New("all tasks are failed")
	}
	return n, nil
}
```
核心业务逻辑就是`results, err := scheduler.Schedule(items)`,代码中将为每一个item创建job，并submit:
```go
func (d *defaultScheduler) Schedule(items []*ScheduleItem) ([]*ScheduleResult, error) {
	var results []*ScheduleResult
	for _, item := range items {
		result := &ScheduleResult{
			TaskID: item.TaskID,
		}
		...
		j := &models.JobData{
			Metadata: &models.JobMetadata{
				//job类型为generic
				JobKind: job.KindGeneric,
			},
			StatusHook: fmt.Sprintf("%s/service/notifications/jobs/replication/task/%d", config.Config.CoreURL, item.TaskID),
		}
		//job的名称为 REPLICATION
		j.Name = job.Replication
		src, err := json.Marshal(item.SrcResource)
		...
		dest, err := json.Marshal(item.DstResource)
		...
		//job参数
		j.Parameters = map[string]interface{}{
			"src_resource": string(src),
			"dst_resource": string(dest),
		}
		//将job提交给jobservice执行
		id, joberr := d.client.SubmitJob(j)
		...
		result.JobID = id
		results = append(results, result)
	}
	return results, nil
}
```

## replication job

job service的工作分为两步，第一步为入队操作，第二步为消费队中元素。
首先，
harbor的各个组件通过post请求，将job任务发送至job service的api接口，然后，api接收job后执行消息入队，具体代码分析参考[job service](harbor-job-service.md)。在job service服务启动时，会注册消息的消费hander，具体的执行根据job类别的不同进入不同的实现，对于replication来说，最终的执行逻辑位于`/harbor/src/jobservice/job/impl/replication/replication.go`的Run函数中：
```go
// Run gets the corresponding transfer according to the resource type
// and calls its function to do the real work
func (r *Replication) Run(ctx job.Context, params job.Parameters) error {
	logger := ctx.GetLogger()
	//解析获取要同步的src/dst
	src, dst, err := parseParams(params)
	...
	//根据同步资源类型，得到创建trans对象的工厂
	factory, err := transfer.GetFactory(src.Type)
	...

	stopFunc := func() bool {
		cmd, exist := ctx.OPCommand()
		if !exist {
			return false
		}
		return cmd == job.StopCommand
	}
	trans, err := factory(ctx.GetLogger(), stopFunc)
	...
	return trans.Transfer(src, dst)
}
```
这个函数的主要作用就是得到一个trans结构的factory,这个factory的设计和前文registry的adapter factory的设计思路一致，通过一个map来维持简单工厂集合。然后向这个factory中传入定制的stopFunc和logger两个组件，这样trans的实现就和依赖的logger和stop逻辑解耦，**如果一个组件是无状态的，那么可以将其定义为函数变量**。factory通过一个map得到，这个map在image/chart的init函数中被填充，具体如下：
```go
//以image为例子
func init() {
	//注册factory函数，类型为image
	if err := trans.RegisterFactory(model.ResourceTypeImage, factory); err != nil {
		log.Errorf("failed to register transfer factory: %v", err)
	}
}
//factory的实现，
func factory(logger trans.Logger, stopFunc trans.StopFunc) (trans.Transfer, error) {
	return &transfer{
		logger:    logger,
		isStopped: stopFunc,
	}, nil
}
```

回过头继续看Run函数，具体的执行交给`trans.Transfer(src, dst)`，Transfer接口的Transfer分别由image的trans和chart的trans实现，通过刚才的factory创建出对应的trans。以image.trans为例子，进入实现：
```go
func (t *transfer) Transfer(src *model.Resource, dst *model.Resource) error {
	// initialize
	if err := t.initialize(src, dst); err != nil {
		return err
	}

	// delete the repository on destination registry
	if dst.Deleted {
		return t.delete(&repository{
			repository: dst.Metadata.GetResourceName(),
			tags:       dst.Metadata.Vtags,
		})
	}
	//封装repo
	srcRepo := &repository{
		repository: src.Metadata.GetResourceName(),
		tags:       src.Metadata.Vtags,
	}
	dstRepo := &repository{
		repository: dst.Metadata.GetResourceName(),
		tags:       dst.Metadata.Vtags,
	}
	// copy the repository from source registry to the destination
	return t.copy(srcRepo, dstRepo, dst.Override)
}
```
首先第一步是initialize,这个initialize主要用于创建src和dst的registry对应的adapter：
```go
func (t *transfer) initialize(src *model.Resource, dst *model.Resource) error {
	//调用前文的stopFunc，获取job状态，如果stop，直接返回
	if t.shouldStop() {
		return nil
	}
	// 获取src image的registry adapter
	srcReg, err := createRegistry(src.Registry)
	...
	t.src = srcReg
	t.logger.Infof("client for source registry [type: %s, URL: %s, insecure: %v] created",
		src.Registry.Type, src.Registry.URL, src.Registry.Insecure)

	// 获取dst image的registry adapter
	dstReg, err := createRegistry(dst.Registry)
	...
	t.dst = dstReg
	t.logger.Infof("client for destination registry [type: %s, URL: %s, insecure: %v] created",
		dst.Registry.Type, dst.Registry.URL, dst.Registry.Insecure)
	return nil
}
```
createRegistry的实现中，其代码逻辑和前文章节的**execute replication的第一步create adapter**相同，都是通过src的type(这个tpye的字面值就是各个厂家)得到adapter factory，然后调用create创建。

initialize函数返回后，Transfer函数的后续逻辑就是repo的封装，最终调用`t.copy(srcRepo, dstRepo, dst.Override)`:
```go
func (t *transfer) copy(src *repository, dst *repository, override bool) error {
	//repo即 peoject/image
	srcRepo := src.repository
	dstRepo := dst.repository
	...
	var err error
	for i := range src.tags {
		if e := t.copyImage(srcRepo, src.tags[i], dstRepo, dst.tags[i], override); e != nil {
			t.logger.Errorf(e.Error())
			err = e
		}
	}
	...
	return nil
}
```
其具体执行逻辑为在for中一个个同步tag级别的image,进入`copyImage`,:
```go
//入参的定义分别为：srcRepo 源rep, srcRef 源tag, destRepo 目标repo， detRef 目标tag，override 覆盖标志位
func (t *transfer) copyImage(srcRepo, srcRef, dstRepo, dstRef string, override bool) error {
	...
	// 从源registry请求manifest描述，manifest中描述了image的具体layer
	manifest, digest, err := t.pullManifest(srcRepo, srcRef)
	...
	// 从目标regisry上发送head请求查看repo+tag是否已存在，如果存在，返回摘要
	exist, digest2, err := t.exist(dstRepo, dstRef)
	...
	// 如果存在，处理
	if exist {
		
		if digest == digest2 {
			...
			return nil
		}
		// the same name image exists, but not allowed to override
		if !override {
			...
			return nil
		}
		//存在，切能够覆盖，则走后续逻辑，不返回
	}
	
	// copy contents between the source and destination registries
	for _, content := range manifest.References() {
		if err = t.copyContent(content, srcRepo, dstRepo); err != nil {
			return err
		}
	}

	// push the manifest to the destination registry
	if err := t.pushManifest(manifest, dstRepo, dstRef); err != nil {
		return err
	}

	...
	return nil
}
```
上述代码的主要工作分为两个部分，第一部分是根据sec/dst Registry的信息，从对应的registry上获取manifest信息。这里的调用为adapter继承的native.Adapter的方法。方法通过向[registry api](https://docs.docker.com/registry/spec/api/) 发送对应的http请求完成(**从native.Adapter对于接口的实现，以及各个厂商adapter都继承自这个adapter可以看出，所有厂商的核心registry都是docker registry**)；第二部分是根据获取的manifest描述，执行具体的cpoy操作，并将manifest post给目标registry，首先是image内容复制：
```go
//content即为各个layer的描述
func (t *transfer) copyContent(content distribution.Descriptor, srcRepo, dstRepo string) error {
	//得到layer的digest
	digest := content.Digest.String()
	switch content.MediaType {
	// when the media type of pulled manifest is manifest list,
	// the contents it contains are a few manifests
	case schema2.MediaTypeManifest:
		// as using digest as the reference, so set the override to true directly
		return t.copyImage(srcRepo, digest, dstRepo, digest, true)
	// handle foreign layer
	case schema2.MediaTypeForeignLayer:
		t.logger.Infof("the layer %s is a foreign layer, skip", digest)
		return nil
	// copy layer or image config
	// the media type of the layer or config can be "application/octet-stream",
	// schema1.MediaTypeManifestLayer, schema2.MediaTypeLayer, schema2.MediaTypeImageConfig
	default:
		return t.copyBlob(srcRepo, dstRepo, digest)
	}
}
```
这里的核心逻辑是copyBlob：
```go
// copy the layer or image config from the source registry to destination
func (t *transfer) copyBlob(srcRepo, dstRepo, digest string) error {
	if t.shouldStop() {
		return nil
	}
	t.logger.Infof("copying the blob %s...", digest)
	exist, err := t.dst.BlobExist(dstRepo, digest)
	...
	//调用native.Adapter的实现，里面的业务逻辑为调用registry api获取内容
	size, data, err := t.src.PullBlob(srcRepo, digest)
	...
	defer data.Close()
	//push
	if err = t.dst.PushBlob(dstRepo, digest, size, data); err != nil {
		t.logger.Errorf("failed to pushing the blob %s: %v", digest, err)
		return err
	}
	t.logger.Infof("copy the blob %s completed", digest)
	return nil
}
```
copy逻辑没有我们想象的复杂，内部逻辑就是通过native.Adapter完成registry api的调用。这里可以参考[docker push](../docker/docker-image-push.md)和[docker pull](../docker/docker-image-pull.md)

最后，manifest的push和image layer的实现相同，在`t.pushManifest(manifest, dstRepo, dstRef)`中完成，不再赘述。至此同步结束。










