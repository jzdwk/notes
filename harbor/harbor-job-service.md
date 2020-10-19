# harbor job service

harbor中的job service

## submit job

以docker push后docker registry使用webhook调用harbor的[notification](harbor-registry-notification.md)为例，push事件对应的handler最终会封装一个job，调用`SubmitJob`发送给job service：

```go
func (d *DefaultClient) SubmitJob(jd *models.JobData) (string, error) {
	//job service 的api
	url := d.endpoint + "/api/v1/jobs"
	jq := models.JobRequest{
		Job: jd,
	}
	b, err := json.Marshal(jq)
	...
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	...
	req.Header.Set("Content-Type", "application/json")
	resp, err := d.client.Do(req)
	...
	//resp 处理
	defer resp.Body.Close()
	data, err := ioutil.ReadAll(resp.Body)
	...
	if resp.StatusCode != http.StatusAccepted {
		return "", &commonhttp.Error{
			Code:    resp.StatusCode,
			Message: string(data),
		}
	}
	stats := &models.JobStats{}
	if err := json.Unmarshal(data, stats); err != nil {
		return "", err
	}
	return stats.Stats.JobID, nil
}
```

## job service router

job service为一个独立的服务，和core独立，job service的api定义位于`src/jobservice/api/router.go`， 其api的handler使用了组件[gorilla](https://github.com/gorilla/) ：

```go
func (br *BaseRouter) registerRoutes() {
	subRouter := br.router.PathPrefix(fmt.Sprintf("%s/%s", baseRoute, apiVersion)).Subrouter()

	subRouter.HandleFunc("/jobs", br.handler.HandleLaunchJobReq).Methods(http.MethodPost)
	subRouter.HandleFunc("/jobs", br.handler.HandleGetJobsReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}", br.handler.HandleGetJobReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}", br.handler.HandleJobActionReq).Methods(http.MethodPost)
	subRouter.HandleFunc("/jobs/{job_id}/log", br.handler.HandleJobLogReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/stats", br.handler.HandleCheckStatusReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}/executions", br.handler.HandlePeriodicExecutions).Methods(http.MethodGet)
}
```

## launch job

当一个job发送至job service(调用submit job)，对应执行的是`r.handler.HandleLaunchJobReq`：

```go
func (dh *DefaultHandler) HandleLaunchJobReq(w http.ResponseWriter, req *http.Request) {
	data, err := ioutil.ReadAll(req.Body)
	...
	jobReq := &job.Request{}
	...
	//启动job
	jobStats, err := dh.controller.LaunchJob(jobReq)
	...
	dh.handleJSONData(w, req, http.StatusAccepted, jobStats)
}
```

它的主要作用就是根据job的类型调用不同的job消费策略：

```go
func (bc *basicController) LaunchJob(req *job.Request) (res *job.Stats, err error) {
	//job校验
	if err := validJobReq(req); err != nil {
		...
	}
	jobType, isKnownJob := bc.backendWorker.IsKnownJob(req.Job.Name)
	...
	if err := bc.backendWorker.ValidateJobParameters(jobType, req.Job.Parameters); err != nil {
		...
	}
	//根据job类型执行策略
	switch req.Job.Metadata.JobKind {
	case job.KindScheduled:
		res, err = bc.backendWorker.Schedule(
			...
			req.Job.Metadata.ScheduleDelay,

		)
	case job.KindPeriodic:
		res, err = bc.backendWorker.PeriodicallyEnqueue(		
			req.Job.Metadata.Cron,
			...
		)
	default:
		res, err = bc.backendWorker.Enqueue(
			...
		)
	}
	...
	return
}
```

其中消费策略的定义由Interface接口完成，这里包括了消息队列式的job消费方式Equeue，基于时间调度Schedule以及定时执行的PeriodicallyEnqueue等：

```go
type Interface interface {
	...
	// Enqueue job
	//
	// jobName string        : the name of enqueuing job
	// params job.Parameters : parameters of enqueuing job
	// isUnique bool         : specify if duplicated job will be discarded
	// webHook string        : the server URL to receive hook events
	//
	// Returns:
	//  *job.Stats : the stats of enqueuing job if succeed
	//  error      : if failed to enqueue
	Enqueue(jobName string, params job.Parameters, isUnique bool, webHook string) (*job.Stats, error)

	// Schedule job to run after the specified interval (seconds).
	//
	// jobName string         : the name of enqueuing job
	// runAfterSeconds uint64 : the waiting interval with seconds
	// params job.Parameters  : parameters of enqueuing job
	// isUnique bool          : specify if duplicated job will be discarded
	// webHook string        : the server URL to receive hook events
	//
	// Returns:
	//  *job.Stats: the stats of enqueuing job if succeed
	//  error          : if failed to enqueue
	Schedule(jobName string, params job.Parameters, runAfterSeconds uint64, isUnique bool, webHook string) (*job.Stats, error)

	// Schedule the job periodically running.
	//
	// jobName string        : the name of enqueuing job
	// params job.Parameters : parameters of enqueuing job
	// cronSetting string    : the periodic duration with cron style like '0 * * * * *'
	// isUnique bool         : specify if duplicated job will be discarded
	// webHook string        : the server URL to receive hook events
	//
	// Returns:
	//  models.JobStats: the stats of enqueuing job if succeed
	//  error          : if failed to enqueue
	PeriodicallyEnqueue(jobName string, params job.Parameters, cronSetting string, isUnique bool, webHook string) (*job.Stats, error)
}
```
对应的，对于core来说，其定义的job类型如下，代码位于`src/jobservice/job/kinds.go`：
```go
const (
	// KindGeneric : Kind of generic job
	KindGeneric = "Generic"
	// KindScheduled : Kind of scheduled job
	KindScheduled = "Scheduled"
	// KindPeriodic : Kind of periodic job
	KindPeriodic = "Periodic"
)
```

### generic job

对于generic job(比如docker push对应的event)，处理逻辑为将其放入一个队列，并消费：
```go
func (w *basicWorker) Enqueue(jobName string, params job.Parameters, isUnique bool, webHook string) (*job.Stats, error) {
	var (
		j   *work.Job
		err error
	)
	//调用gocraft/work入队
	if isUnique {
		if j, err = w.enqueuer.EnqueueUnique(jobName, params); err != nil {
			...
		}
	} else {
		if j, err = w.enqueuer.Enqueue(jobName, params); err != nil {
			...
		}
	}
	...
	return generateResult(j, job.KindGeneric, isUnique, params, webHook), nil
```
其中队列使用基于redis的[gocraft/work](https://github.com/gocraft/work) 。[redis](https://www.runoob.com/redis/redis-tutorial.html) 复习参考。

## consume job

对于上面的流程，当job入队后，需要消费者对job进行处理。根据gocraft的文档对[process job](https://github.com/gocraft/work#process-jobs) 的介绍，job消费的关键代码主要是注册handler以及redis pool的start。类似如下：
```go
	// Add middleware that will be executed for each job
	pool.Middleware((*Context).Log) //类似责任链的传递
	pool.Middleware((*Context).FindCustomer)

	// Map the name of jobs to handler functions
	pool.Job("send_email", (*Context).SendEmail)  //handler
	// Customize options:
	pool.JobWithOptions("export", work.JobOptions{Priority: 10, MaxFails: 1}, (*Context).Export)
	// Start processing jobs
	pool.Start()
```

### load config

此时，回过头看job service的main函数实现，代码位于`/src/jobservice/main.go`:

```go
func main() {
	//加载jobservice的配置
	...
	// context设置，Append node ID
	vCtx := context.WithValue(context.Background(), utils.NodeID, utils.GenerateNodeID())
	// Create the root context
	ctx, cancel := context.WithCancel(vCtx)
	defer cancel()

	// Initialize logger
	if err := logger.Init(ctx); err != nil {
		panic(err)
	}

	// Set job context initializer
	runtime.JobService.SetJobContextInitializer(func(ctx context.Context) (job.Context, error) {
		secret := config.GetAuthSecret()
		if utils.IsEmptyStr(secret) {
			return nil, errors.New("empty auth secret")
		}
		coreURL := config.GetCoreURL()
		configURL := coreURL + common.CoreConfigPath
		cfgMgr := comcfg.NewRESTCfgManager(configURL, secret)
		jobCtx := impl.NewContext(ctx, cfgMgr)

		if err := jobCtx.Init(); err != nil {
			return nil, err
		}

		return jobCtx, nil
	})

	// Start
	if err := runtime.JobService.LoadAndRun(ctx, cancel); err != nil {
		logger.Fatal(err)
	}
}
```

上述代码的主要工作是加载job service的配置，初始化log/db等组件以及注册job [context](https://www.jianshu.com/p/d24bf8b6c869) 的init函数。job service的配置同样位于`common/config/jobservice/config.yml`，主要是worker、redis和logger：

```
---
#Protocol used to serve
protocol: "http"

#Config certification if use 'https' protocol
#https_config:
#  cert: "server.crt"
#  key: "server.key"

#Server listening port
port: 8080

#Worker pool
worker_pool:
  #Worker concurrency
  workers: 10
  backend: "redis"
  #Additional config if use 'redis' backend
  redis_pool:
    #redis://[arbitrary_username:password@]ipaddress:port/database_index
    redis_url: redis://redis:6379/2
    namespace: "harbor_job_service_namespace"
#Loggers for the running job
job_loggers:
  - name: "STD_OUTPUT" # logger backend name, only support "FILE" and "STD_OUTPUT"
    level: "INFO" # INFO/DEBUG/WARNING/ERROR/FATAL
  - name: "FILE"
    level: "INFO"
    settings: # Customized settings of logger
      base_dir: "/var/log/jobs"
    sweeper:
      duration: 1 #days
      settings: # Customized settings of sweeper
        work_dir: "/var/log/jobs"

#Loggers for the job service
loggers:
  - name: "STD_OUTPUT" # Same with above
    level: "INFO"root@myharbor:/home/jzd/harbor/harbor1.8.2-https/common/config/
```
### job handler

消费job最主要的实现为函数`runtime.JobService.LoadAndRun(ctx, cancel)`:

```go
func (bs *Bootstrap) LoadAndRun(ctx context.Context, cancel context.CancelFunc) (err error) {
	rootContext := &env.Context{
		SystemContext: ctx,
		WG:            &sync.WaitGroup{},
		ErrorChan:     make(chan error, 5), // with 5 buffers
	}
	//调用init封装jobCtx
	if bs.jobConextInitializer != nil {
		rootContext.JobContext, err = bs.jobConextInitializer(ctx)
		...
	}
	//声明一个cfg对象
	...
	if cfg.PoolConfig.Backend == config.JobServicePoolBackendRedis {
		// 对应yml中的work_pool.workers
		workerNum := cfg.PoolConfig.WorkerCount
		...
		// 根据redis配置得到redigo的pool对象
		redisPool := bs.getRedisPool(cfg.PoolConfig.RedisPoolCfg)

		// redis的数据迁移，(此处还没太明白)
		rdbMigrator := migration.New(redisPool, namespace)
		rdbMigrator.Register(migration.PolicyMigratorFactory)
		if err := rdbMigrator.Migrate(); err != nil {
			// Just logged, should not block the starting process
			logger.Error(err)
		}

		// Create stats manager
		manager = mgt.NewManager(ctx, namespace, redisPool)
		// hook agent，处理job中设置的回调地址
		hookAgent := hook.NewAgent(rootContext, namespace, redisPool)
		//定义回调的执行逻辑，通过Trigger将evt填入agent的event channel
		hookCallback := func(URL string, change *job.StatusChange) error {
			msg := fmt.Sprintf("status change: job=%s, status=%s", change.JobID, change.Status)
			if !utils.IsEmptyStr(change.CheckIn) {
				msg = fmt.Sprintf("%s, check_in=%s", msg, change.CheckIn)
			}

			evt := &hook.Event{
				URL:       URL,
				Timestamp: time.Now().Unix(),
				Data:      change,
				Message:   msg,
			}

			return hookAgent.Trigger(evt)
		}

		// 根据之前的context/ns/redis pool/callback封装一个basicController
		lcmCtl := lcm.NewController(rootContext, namespace, redisPool, hookCallback)
```

上述代码依旧完成了进一步的封装和init，继续看`loadAndRunRedisWorkerPool`，首先是job的registry:

```go
// Load and run the worker worker
func (bs *Bootstrap) loadAndRunRedisWorkerPool(
	ctx *env.Context,
	ns string,
	workers uint,
	redisPool *redis.Pool,
	lcmCtl lcm.Controller,
) (worker.Interface, error) {
	redisWorker := cworker.NewWorker(ctx, ns, workers, redisPool, lcmCtl)
	//注册job
	if err := (
		map[string]interface{}{redisWorker.RegisterJobs
			// Only for debugging and testing purpose
			job.SampleJob: (*sample.Job)(nil),
			// Functional jobs
			job.ImageScanJob:           (*sc.Job)(nil),
			job.ImageScanAllJob:        (*all.Job)(nil),
			job.ImageGC:                (*gc.GarbageCollector)(nil),
			job.Replication:            (*replication.Replication)(nil),
			job.ReplicationScheduler:   (*replication.Scheduler)(nil),
			job.Retention:              (*retention.Job)(nil),
			scheduler.JobNameScheduler: (*scheduler.PeriodicJob)(nil),
			job.WebhookJob:             (*notification.WebhookJob)(nil),
		});...
	}

	if err := redisWorker.Start(); err != nil {
		return nil, err
	}
	return redisWorker, nil
}
```

上述代码可以看到通过RegisterJobs向redisWorker中注册各种类型的job，因此猜测此处为各个job handler的注册处。查看`RegisterJobs`的实现：

```go
func (w *basicWorker) registerJob(name string, j interface{}) (err error) {
	// nil & already exist hanlder
	...
	// Wrap job
	redisJob := runner.NewRedisJob(j, w.context, w.ctl)
	// Get more info from j
	theJ := runner.Wrap(j)
	// Put into the pool
	w.pool.JobWithOptions( //gocraft的实现
		name, //name就是在RegisterJobs的入参map中的key，即各种类型的job
		work.JobOptions{
			MaxFails: theJ.MaxFails(),
			SkipDead: true,
		},
		// Use generic handler to handle as we do not accept context with this way.
		func(job *work.Job) error {
			return redisJob.Run(job)  //job handler
		},
	)
	// Keep the name of registered jobs as known jobs for future validation
	w.knownJobs.Store(name, j)
	...
	return nil
}
```

代码中主要的工作就是调用`pool.JobWithOptions`向pool中注册了用于处理不同job的handler，即`redisJob.Run(job)`。进入具体实现:

```go
func (rj *RedisJob) Run(j *work.Job) (err error) {
	var (
		runningJob  job.Interface
		execContext job.Context
		tracker     job.Tracker
		markStopped = bp(false)
	)

	...
	jID := j.ID

	if eID, yes := isPeriodicJobExecution(j); yes {
		jID = eID
	}
	//根据jobId得到一个tracker接口的实例，tracker的主要作用是进行整个job的生命周期管理，根据job的执行情况变更其状态。
	if tracker, err = rj.ctl.Track(jID); err != nil {
		//失败控制，避免无线循环
		now := time.Now().Unix()
		if j.FailedAt == 0 || now-j.FailedAt < 2*24*3600 {
			j.Fails--
		}
		return
	}
```
其中的Tracker接口定义如下，可以看到其作为是管理整个job的生命周期：
```go
type Tracker interface {
	// Save the job stats which tracked by this tracker to the backend
	//
	// Return:
	//   none nil error returned if any issues happened
	Save() error

	// Load the job stats which tracked by this tracker with the backend data
	//
	// Return:
	//   none nil error returned if any issues happened
	Load() error

	// Get the job stats which tracked by this tracker
	//
	// Returns:
	//  *models.Info : job stats data
	Job() *Stats

	// Update the properties of the job stats
	//
	// fieldAndValues ...interface{} : One or more properties being updated
	//
	// Returns:
	//  error if update failed
	Update(fieldAndValues ...interface{}) error

	// NumericID returns the numeric ID of periodic job.
	// Please pay attention, this only for periodic job.
	NumericID() (int64, error)

	// Mark the periodic job execution to done by update the score
	// of the relation between its periodic policy and execution to -1.
	PeriodicExecutionDone() error

	// Check in message
	CheckIn(message string) error

	// Update status with retry enabled
	UpdateStatusWithRetry(targetStatus Status) error

	// The current status of job
	Status() (Status, error)

	// Expire the job stats data
	Expire() error

	// Switch status to running
	Run() error

	// Switch status to stopped
	Stop() error

	// Switch the status to error
	Fail() error

	// Switch the status to success
	Succeed() error

	// Reset the status to `pending`
	Reset() error
}
```
继续回到`func (rj *RedisJob) Run(j *work.Job) (err error)`:
```go
func (rj *RedisJob) Run(j *work.Job) (err error)
	...
	//返回redis中的job状态，并switch-case
	jStatus := job.Status(tracker.Job().Info.Status)
	switch jStatus {
	//pending, scheduled的继续走代码
	case job.PendingStatus, job.ScheduledStatus:
		break
	//stop状态置标记位
	case job.StoppedStatus:
		//stop
		markStopped = bp(true)
		return nil
	case job.ErrorStatus:
		//将job状态重新置为pending
		...
		break
	default:
		//error
	}
	//定义defer 从redis中重新获取job状态，stop or success处理
	defer func() {
		if err != nil {
			//job状态置为error
			if er := tracker.Fail(); er != nil {
				...
			}
			return
		}
		if latest, er := tracker.Status(); er == nil {
			//job如果是stop，置标记位
			if latest == job.StoppedStatus {
				// Logged
				logger.Infof("Job %s:%s is stopped", tracker.Job().Info.JobName, tracker.Job().Info.JobID)
				// Stopped job, no exit message printing.
				markStopped = bp(true)
				return
			}
		}

		// 如果以上情况都正常，job标记为成功，将job在redis中置过期，并发送callBackHook相关信息。
		if er := tracker.Succeed(); er != nil 
			logger.Errorf("Mark job status to success error: %s", er)
		}
	}()

	// Defer to handle runtime error
	defer func() {
		if r := recover(); r != nil {
			// Log the stack
			buf := make([]byte, 1<<10)
			size := runtime.Stack(buf, false)
			err = errors.Errorf("runtime error: %s; stack: %s", r, buf[0:size])
			logger.Errorf("Run job %s:%s error: %s", j.Name, j.ID, err)
		}
	}()

	// Build job context
	if rj.context.JobContext == nil {
		rj.context.JobContext = impl.NewDefaultContext(rj.context.SystemContext)
	}
	//将tracker封装成一个可执行上下文，该上下文除了包含tracker，还包括了需要使用的configManager,sysContext
	if execContext, err = rj.context.JobContext.Build(tracker); err != nil {
		return
	}

	// Defer to close logger stream
	defer func() {
		// Close open io stream first
		if closer, ok := execContext.GetLogger().(logger.Closer); ok {
			if er := closer.Close(); er != nil {
				logger.Errorf("Close job logger failed: %s", er)
			}
		}
	}()

	// Wrap job
	runningJob = Wrap(rj.job)
	// 通过CAS 将job的状态置为running
	if err = tracker.Run(); err != nil {
		return
	}
	// 执行具体的run操作，根据runningJob的类型，执行对应Job的Run方法，这些Job类型包括了scan,gc,replication,scheduler等。
	err = runningJob.Run(execContext, j.Args)
	// 根据job类型，判断这个job是否需要retry，如果不需要，设置足够大的一个失败次数(10000000000)
	rj.retry(runningJob, j)
	// 根据job的参数判断是否为周期性job，如果是，重新将其加入队列
	if _, yes := isPeriodicJobExecution(j); yes {
		if er := tracker.PeriodicExecutionDone(); er != nil {
			// Just log it
			logger.Error(er)
		}
	}

	return
}
```
上述代码需要注意的是**几个defer函数的定义，这些defer函数用于处理job失败的情况，其执行顺序为声明顺序的倒序**。整个job消费的处理流程可以描述为：

1. 根据jobID从redis中取出job，并封装为一个tracker对象，用于job的全生命周期管理

2. 解析job状态：

2.1 如果是pending（待处理），scheduled（周期性），则break后执行后续代码；

2.2 如果是stop状态，将stop标记(markStop)置true并return；

2.3 如果是error状态，将调用tracker.Reset，将job状态重置为pending，等待下一次操作

3. 执行job的run过程：

3.1 调用tracker.Run()操作，将job的状态变更为running；

3.2 根据job的类型，执行对应的Run(execContext, j.Args)方法，这个Run方法具体完成了job描述的业务逻辑

4. 进入defer环节，首先是一个关闭log和执行recover的defer

5.  进入处理job状态的defer：如果在上述job处理的过程中，发生err，则将job状态置为error并return，进入下一个defer;如果job的状态变为stop，则将stop标记改为true并return,进入下一个refer；上述情况都未发生，说明job执行成功，将状态改为success，设置过期

6. 进入下一个defer，如果job状态既不是stop，也没有err 说明job执行成功，打印日志并返回。

可以看到，对于每一个job的handler，其实现为从redis中获取job的状态信息，并根据不同状态更新handler的执行(包括是否retry/返回/执行running)。而具体的执行位于代码`err = runningJob.Run(execContext, j.Args)`,可以看到针对不同的job类型，提供了不同的实现，包括了GC/Replication/Schedule/web hook等job，以web hook为例：

```go
// execute webhook job
func (wj *WebhookJob) execute(ctx job.Context, params map[string]interface{}) error {
	//获取job中的参数
	payload := params["payload"].(string)
	address := params["address"].(string)
	req, err := http.NewRequest(http.MethodPost, address, bytes.NewReader([]byte(payload)))
	...
	if v, ok := params["auth_header"]; ok && len(v.(string)) > 0 {
		req.Header.Set("Authorization", v.(string))
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := wj.client.Do(req)
	...
	defer resp.Body.Close()
	...
	return nil
}
```

可以看到web hook类型的job的回调逻辑，其中`payload/address`即为在[notification](harbor-registry-notification.md) 中的`func (h *HTTPHandler) process(event *model.HookEvent)`封装信息。

另一方面，**每一次job状态的转义，都伴随着一次callBack的调用**，比如对于Success和Error：
```go
//失败
func (bt *basicTracker) Fail() error {
	err := bt.UpdateStatusWithRetry(ErrorStatus)
	if !errs.IsStatusMismatchError(err) {
		bt.refresh(ErrorStatus)
		//回调点
		if er := bt.fireHookEvent(ErrorStatus); err == nil && er != nil {
			return er
		}
	}

	return err
}
//成功
func (bt *basicTracker) Succeed() error {
	err := bt.UpdateStatusWithRetry(SuccessStatus)
	if !errs.IsStatusMismatchError(err) {
		bt.refresh(SuccessStatus)
		// Expire the stat data of the successful job
		if er := bt.expire(statDataExpireTimeForSuccess); er != nil {
			...
		}
		//回调点
		if er := bt.fireHookEvent(SuccessStatus); err == nil && er != nil {
			...
		}
	}
	return err
}
```

这个callBack函数的定义位于最初的`func (bs *Bootstrap) LoadAndRun(ctx context.Context, cancel context.CancelFunc)`中，其功能就是接收event后，封装为evt对象，调用hookAgent的Trigger，将evt入队：
```go
func (bs *Bootstrap) LoadAndRun(ctx context.Context, cancel context.CancelFunc) (err error) {
	...
	if cfg.PoolConfig.Backend == config.JobServicePoolBackendRedis {
		...
		hookCallback := func(URL string, change *job.StatusChange) error {
			msg := fmt.Sprintf("status change: job=%s, status=%s", change.JobID, change.Status)
			if !utils.IsEmptyStr(change.CheckIn) {
				msg = fmt.Sprintf("%s, check_in=%s", msg, change.CheckIn)
			}

			evt := &hook.Event{
				URL:       URL,
				Timestamp: time.Now().Unix(),
				Data:      change,
				Message:   msg,
			}

			return hookAgent.Trigger(evt)
		}

		...
}
```

最后，返回函数`func (bs *Bootstrap) LoadAndRun(ctx context.Context, cancel context.CancelFunc) (err error)`。在完成job的handler后，剩下的工作主要是两部分，一是`hookAgent.Serve()`，这个agent的主要功能是回调job的webhook，将执行成功的job信息发送回原地址;二是创建并拉起`apiServer服务`，即前文`router.go`中描述的api。

```go
func (bs *Bootstrap) LoadAndRun(ctx context.Context, cancel context.CancelFunc) (err error){
		// 启动redis和注册的worker handler...
		backendWorker, err = bs.loadAndRunRedisWorkerPool(
			rootContext,
			namespace,
			workerNum,
			redisPool,
			lcmCtl,
		)
		...
		// Run daemon process of life cycle controller
		// Ignore returned error
		if err = lcmCtl.Serve(); err != nil {
			return errors.Errorf("start life cycle controller error: %s", err)
		}
		// Start agent
		// Non blocking call
		hookAgent.Attach(lcmCtl)
		if err = hookAgent.Serve(); err != nil {
			return errors.Errorf("start hook agent error: %s", err)
		}
	} 
	...

	// Initialize controller
	ctl := core.NewController(backendWorker, manager)
	// Start the API server
	apiServer := bs.createAPIServer(ctx, cfg, ctl)
	...
	if er := apiServer.Start(); er != nil {
		...
	} 
	...
}
```

因为`hookAgent.Serve()`用来处理各种event，而这个event是在上文分析的各个job状态变动时，调用callback生成并放入channel，Serve()的作用就是取出这些event，根据其URL等描述，发送http请求。

