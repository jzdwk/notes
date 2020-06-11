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

job service为一个独立的服务，和core独立，job service的api定义位于`src/jobservice/api/router.go`：

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

对于上面的流程，当job入队后，需要消费者对job进行处理。此时，回过头看job service的main函数实现，代码位于`/src/jobservice/main.go`:
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

最主要的实现为函数`runtime.JobService.LoadAndRun(ctx, cancel)`:

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

		// redis的数据迁移，如果有必要的话
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
上述代码依旧完成了进一步的封装和init，

```go
		// Start the backend worker
		backendWorker, err = bs.loadAndRunRedisWorkerPool(
			rootContext,
			namespace,
			workerNum,
			redisPool,
			lcmCtl,
		)
		if err != nil {
			return errors.Errorf("load and run worker error: %s", err)
		}

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
	} else {
		return errors.Errorf("worker backend '%s' is not supported", cfg.PoolConfig.Backend)
	}

	// Initialize controller
	ctl := core.NewController(backendWorker, manager)
	// Start the API server
	apiServer := bs.createAPIServer(ctx, cfg, ctl)

	// Listen to the system signals
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM, os.Kill)
	terminated := false
	go func(errChan chan error) {
		defer func() {
			// Gracefully shutdown
			// Error happened here should not override the outside error
			if er := apiServer.Stop(); er != nil {
				logger.Error(er)
			}
			// Notify others who're listening to the system context
			cancel()
		}()

		select {
		case <-sig:
			terminated = true
			return
		case err = <-errChan:
			return
		}
	}(rootContext.ErrorChan)

	node := ctx.Value(utils.NodeID)
	// Blocking here
	logger.Infof("API server is serving at %d with [%s] mode at node [%s]", cfg.Port, cfg.Protocol, node)
	if er := apiServer.Start(); er != nil {
		if !terminated {
			// Tell the listening goroutine
			rootContext.ErrorChan <- er
		}
	} else {
		// In case
		sig <- os.Interrupt
	}

	// Wait everyone exit
	rootContext.WG.Wait()

	return
}
```