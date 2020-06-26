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

执行replication的操作位于`policy`处，入口为`beego.Router("/api/replication/executions", &api.ReplicationOperationAPI{}, "get:ListExecutions;post:CreateExecution")
` 函数，函数首先根据execution实体，获取policy以及policy的registry信息，以及trigger策略，最终调用operation包中的controller接口`StartReplication(policy *model.Policy, resource *model.Resource, trigger model.TriggerType) (int64, error)`，接口的具体实现由controller结构完成，controller中封装了执行policy的各个组件，通过New函数对外暴露：
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
上述代码的重点为`reg, ok := adapter.(adp.ImageRegistry)&&res, err = reg.FetchImages(filters)`这两句，每个厂家的adapter中都包含了`native.Adapter`结构，此结构实现了ImageRegistry/ChartRegistry接口，每一个resource的最终对象对应了project。最终返回的resources定义如下：
```go
type Resource struct {
	//资源类型
	Type         ResourceType           `json:"type"`
	//具体的资源描述
	Metadata     *ResourceMetadata      `json:"metadata"`
	//对应的registry
	Registry     *Registry              `json:"registry"`
	ExtendedInfo map[string]interface{} `json:"extended_info"`
	// Indicate if the resource is a deleted resource
	Deleted bool `json:"deleted"`
	// indicate whether the resource can be overridden
	Override bool `json:"override"`
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







