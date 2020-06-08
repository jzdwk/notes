# harbor registry notification

[webhook](https://www.jianshu.com/p/4cae7512c247) 可理解为一种事件驱动型的回调函数，当监听的事件发生数据变化时，向注册的回调地址发送变化信息。

## docker registry notification

docker通过webhook，向registry中加入了[notification](https://docs.docker.com/registry/notifications/) 机制实现image的管理。这个机制就是当有image pull/push事件发生时，将这些事件序列化后发送至配置的地址。

因此，继续查看harbor中，关于registry的配置，可以在`/common/config/registry/config.yml`中看到如下配置：
```
notifications:
  endpoints:
  - name: harbor
    disabled: false
    url: http://core:8080/service/notifications
    timeout: 3000ms
    threshold: 5
    backoff: 1s
```
可以看到其处理地址为`http://core:8080/service/notifications`。

## create notification event

通过beego的路由配置进入实现函数`Post` ,首先是参数解析，注意*body*的处理中，设置了最大阈值4G，单位为byte。

```go
func (n *NotificationHandler) Post() {
	//参数解析
	var notification models.Notification
	//阈值处理
	err := json.Unmarshal(n.Ctx.Input.CopyBody(1<<32), &notification)
	...
	events, err := filterEvents(&notification)
	...
}
```

另外，notification中封装了事件Event的切片，事件描述了docker pull/push的必要信息：

```go
type Event struct {
	ID        string 
	TimeStamp time.Time
	Action    string   //事件种类
	Target    *Target  //image信息
	Request   *Request //请求信息
	Actor     *Actor   //操作者信息
}
```

事件接收到后，逐一进行遍历处理：

```go
func (n *NotificationHandler) Post() {
	...
	for _, event := range events {
		//image的解析
		repository := event.Target.Repository
		project, _ := utils.ParseRepository(repository)
		tag := event.Target.Tag
		action := event.Action
		
		user := event.Actor.Name
		...
		//查db，找project
		pro, err := config.GlobalProjectMgr.Get(project)
		...
		//开启routine记录accessLog
		go func() {
			if err := dao.AddAccessLog(models.AccessLog{
				Username:  user,
				ProjectID: pro.ProjectID,
				RepoName:  repository,
				RepoTag:   tag,
				Operation: action,
				OpTime:    time.Now(),
			}); err != nil {
				log.Errorf("failed to add access log: %v", err)
			}
		}()
		...
```

上述代码注意一些编码方式：一是log的记录使用routine，二是dao层的使用统一采用了`o.Raw(sql, queryParam).QueryRows(&p)`接口，sql为原生写法，没有使用beego封装的`orm.NewQueryBuilder` 。这个思路与mybatis、springJDBC类似。

## push event handle

继续分析，通过action分支处理，首先是**push**处理：

```go
		if action == "push" {
			// discard the notification without tag.
			if tag != "" {
				//同样一个routine去记录RepoRecord，这个RepoRecord记录了这个repo的pull/push次数等信息
				go func() {
					exist := dao.RepositoryExists(repository)
					if exist {
						return
					}
					log.Debugf("Add repository %s into DB.", repository)
					repoRecord := models.RepoRecord{
						Name:      repository,
						ProjectID: pro.ProjectID,
					}
					if err := dao.AddRepository(repoRecord); err != nil {
						log.Errorf("Error happens when adding repository: %v", err)
					}
				}()
			}
			
			// 定义imagePush事件
			evt := &notifierEvt.Event{}
			//image push的元信息定义，ImagePushMetaData实现了Metadata接口的Resolve(event *Event)方法
			imgPushMetadata := &notifierEvt.ImagePushMetaData{
				Project:  pro,
				Tag:      tag,
				Digest:   event.Target.Digest,
				RepoName: event.Target.Repository,
				OccurAt:  time.Now(),
				Operator: event.Actor.Name,
			}
			//build通知事件notifierEvt.Event{}，通过Resolve(event *Event)，将ImagePushMetaData封装，其中evt的topic是"OnPushImage"
			if err := evt.Build(imgPushMetadata); err == nil {
				//事件发布
				if err := evt.Publish(); err != nil {
					...
				}
			} else {
				....
			}
```

上述代码首先创建了一个ImagePushMetaData，这个结构体实现了Metadata接口的Resolve(event \*Event)方法，后者将所有不同种类的metadata封装为notifierEvt.Event{}后，根据不同的metadata设置对应的event.topic，对于image push来说，topic就是·`OnPushImage`。然后调用`evt.Publish`，进入实现，其最终通过封装一个notification，通过NotificationWatcher调用Notify，这是一个**订阅-发布模型**：

```go
func (nw *NotificationWatcher) Notify(notification Notification) error {
	...
	defer nw.RUnlock()
	nw.RLock()
	var (
		indexer  HandlerIndexer
		ok       bool
		handlers = []NotificationHandler{}
	)
	//根据topic选取对应的handler，这个handler就是注册的Subscriber
	if indexer, ok = nw.handlers[notification.Topic]; !ok {
		return fmt.Errorf("No handlers registered for handling topic %s", notification.Topic)
	}
	
	for _, h := range indexer {
		handlers = append(handlers, h)
	}

	// 触发每个Subscriber定义的handler，这里通过一个无缓冲chan去约束handler行为，如果是有状态handler，同步处理，否则并发处理。
	for _, h := range handlers {
		var handlerChan chan bool
		if h.IsStateful() {
			t := reflect.TypeOf(h).String()
			handlerChan = nw.handlerChannels[t].channel
		}
		go func(hd NotificationHandler, ch chan bool) {
			if hd.IsStateful() && ch != nil {
				ch <- true
			}
			go func() {
				defer func() {
					if hd.IsStateful() && ch != nil {
						<-ch
					}
				}()
				//具体的处理逻辑
				if err := hd.Handle(notification.Value); err != nil {
					...
				} else {
					...
				}
			}()
		}(h, handlerChan)
	}

	return nil
}
```

回顾harbor的功能，当一个image push后，除了基本的数据存储处理，还存在比如漏洞扫描、image同步等功能，这些功能在image被push后触发，因此，这是一个典型的**订阅-发布模型**，订阅者为各个子模块，Publisher为image的notification。此处的每一notification(依topic区分)可以对应多个handler，每一个handler也可以注册至多个notification，即Publisher-n/m-Subscriber。（此处回忆*观察者模式*和*订阅发布*的不同点，可以[参考](https://zhuanlan.zhihu.com/p/51357583) ）。这里的关联在内存存储，描述在NotificationWatcher的handlers：

```go
type NotificationWatcher struct {
	// For handle concurrent scenario.
	*sync.RWMutex

	// To keep the registered handlers in memory.
	// Each topic can register multiple handlers.
	// Each handler can bind to multiple topics.
	handlers map[string]HandlerIndexer

	// Keep the channels which are used to control the concurrent executions
	// of multiple stateful handlers with same type.
	handlerChannels map[string]*HandlerChannel
}
```

而handlers这map，即注册逻辑则在`core/notifier/topic/tipics.go`的init函数中初始化：

```go
func init() {
	handlersMap := map[string][]notifier.NotificationHandler{
		model.PushImageTopic:         {&notification.ImagePreprocessHandler{}},
		model.PullImageTopic:         {&notification.ImagePreprocessHandler{}},
		model.DeleteImageTopic:       {&notification.ImagePreprocessHandler{}},
		model.WebhookTopic:           {&notification.HTTPHandler{}},
		model.UploadChartTopic:       {&notification.ChartPreprocessHandler{}},
		model.DownloadChartTopic:     {&notification.ChartPreprocessHandler{}},
		model.DeleteChartTopic:       {&notification.ChartPreprocessHandler{}},
		model.ScanningCompletedTopic: {&notification.ScanImagePreprocessHandler{}},
		model.ScanningFailedTopic:    {&notification.ScanImagePreprocessHandler{}},
		model.QuotaExceedTopic:       {&notification.QuotaPreprocessHandler{}},
	}

	for t, handlers := range handlersMap {
		for _, handler := range handlers {
			if err := notifier.Subscribe(t, handler); err != nil {
				log.Errorf("failed to subscribe topic %s: %v", t, err)
				continue
			}
			log.Debugf("topic %s is subscribed", t)
		}
	}
}
```

可以看到对于image push，定义了一个切片用于注册handler，而反过来，image push/push/delete都使用了`ImagePreprocessHandler`这个handler。进入具体的实现，其中value为最初封装的image信息：

```go
func preprocessAndSendImageHook(value interface{}) error {
	// if global notification configured disabled, return directly
	if !config.NotificationEnable() {
		log.Debug("notification feature is not enabled")
		return nil
	}
	//将event.Data信息重新解析到imageEvent
	imgEvent, err := resolveImageEventData(value)
	...
	//从NotificationPolicy中查询project相关的policy
	policies, err := notification.PolicyMgr.GetRelatedPolices(imgEvent.Project.ProjectID, imgEvent.EventType)
	...
	//解析imageEvent，封装payload
	payload, err := constructImagePayload(imgEvent)
	...
	//继续向特定handler发送通知
	err = sendHookWithPolicies(policies, payload, imgEvent.EventType)
	...
	return nil
}
```
上述代码做了两件事，一是将value解析并封装为payload，即事件的载体：
```go
// Payload of notification event
type Payload struct {
	Type      string     //等于event的类型
	OccurAt   int64      //时间戳
	Operator  string     //操作者
	EventData *EventData //事件描述
}
```
另一件是将再这个payload通过订阅-发布模型根据不同的policy和target发布到具体的handler:
```go
func sendHookWithPolicies(policies []*models.NotificationPolicy, payload *notifyModel.Payload, eventType string) error {
	errRet := false
	for _, ply := range policies {
		targets := ply.Targets
		for _, target := range targets {
			evt := &event.Event{}
			hookMetadata := &event.HookMetaData{
				EventType: eventType,
				PolicyID:  ply.ID,
				Payload:   payload,
				Target:    &target,
			}
			// It should never affect evaluating other policies when one is failed, but error should return
			if err := evt.Build(hookMetadata); err == nil {
				if err := evt.Publish(); err != nil {
					...
				}
			} else {
				...
			}
			...
		}
	}
	...
	return nil
}
```

通过前文的init可知，此时的handler为HTTPHandler，最终将调用
```go
func (h *HTTPHandler) process(event *model.HookEvent) error {
	j := &models.JobData{
		Metadata: &models.JobMetadata{
			JobKind: job.KindGeneric,
		},
	}
	j.Name = job.WebhookJob

	payload, err := json.Marshal(event.Payload)
	...
	j.Parameters = map[string]interface{}{
		"payload": string(payload),
		"address": event.Target.Address,
		// Users can define a auth header in http statement in notification(webhook) policy.
		// So it will be sent in header in http request.
		"auth_header":      event.Target.AuthHeader,
		"skip_cert_verify": event.Target.SkipCertVerify,
	}
	return notification.HookManager.StartHook(event, j)
}
```
即webhook的处理过程。

综上，回顾image push过程，harbor通过**订阅-发布**模型，将具体事件和事件的处理逻辑解耦，两者通过在`core/notifier/topic/tipics.go`中初始化`handlersMap`完成关联，也就是订阅-发布中**Broker**的角色，整体的流程为：

1. docker registry使用webhook通知harbor core的notification api
2. api解析事件信息，dao记录log
3. 根据事件类型(push)，dao记录push信息，随后map到具体的ImagePreprocessHandler
4. handler处理业务逻辑，dao获取执行策略，将image push envent重新封装
5. 重新map到具体的HttpHandler，调用webhook

