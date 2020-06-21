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
	srcAdapter, dstAdapter, err := initialize(c.policy)
	if err != nil {
		return 0, err
	}
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

