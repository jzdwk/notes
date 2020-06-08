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

## harbor notification

通过beego的路由配置进入实现函数`Post` ,逻辑较为简单，步骤可简单分为：
1. 参数解析，注意*body*的处理中，设置了最大阈值4G，单位为byte。
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
2. 事件接收到后，逐一进行遍历处理：
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

3.1 继续分析，通过action分支处理，首先是push处理：
```go
		if action == "push" {
			// discard the notification without tag.
			if tag != "" {
				//同样一个routine去记录RepoRecord，这个RepoRecord记录了这个repo的pull/push数等信息
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
			imgPushMetadata := &notifierEvt.ImagePushMetaData{
				Project:  pro,
				Tag:      tag,
				Digest:   event.Target.Digest,
				RepoName: event.Target.Repository,
				OccurAt:  time.Now(),
				Operator: event.Actor.Name,
			}
			//事件发布，首先通过build将metadata封装为event，之后调用push
			if err := evt.Build(imgPushMetadata); err == nil {
				if err := evt.Publish(); err != nil {
					...
				}
			} else {
				....
			}

			go func() {
				e := &repevent.Event{
					Type: repevent.EventTypeImagePush,
					Resource: &model.Resource{
						Type: model.ResourceTypeImage,
						Metadata: &model.ResourceMetadata{
							Repository: &model.Repository{
								Name: repository,
								Metadata: map[string]interface{}{
									"public": strconv.FormatBool(pro.IsPublic()),
								},
							},
							Vtags: []string{tag},
						},
					},
				}
				if err := replication.EventHandler.Handle(e); err != nil {
					log.Errorf("failed to handle event: %v", err)
				}
			}()

			if autoScanEnabled(pro) {
				artifact := &v1.Artifact{
					NamespaceID: pro.ProjectID,
					Repository:  repository,
					Tag:         tag,
					MimeType:    v1.MimeTypeDockerArtifact,
					Digest:      event.Target.Digest,
				}

				if err := scan.DefaultController.Scan(artifact); err != nil {
					log.Error(errors.Wrap(err, "registry notification: trigger scan when pushing automatically"))
				}
			}
		}
		if action == "pull" {
			// build and publish image pull event
			evt := &notifierEvt.Event{}
			imgPullMetadata := &notifierEvt.ImagePullMetaData{
				Project:  pro,
				Tag:      tag,
				Digest:   event.Target.Digest,
				RepoName: event.Target.Repository,
				OccurAt:  time.Now(),
				Operator: event.Actor.Name,
			}
			if err := evt.Build(imgPullMetadata); err == nil {
				if err := evt.Publish(); err != nil {
					// do not return when publishing event failed
					log.Errorf("failed to publish image pull event: %v", err)
				}
			} else {
				// do not return when building event metadata failed
				log.Errorf("failed to build image push event metadata: %v", err)
			}

			go func() {
				log.Debugf("Increase the repository %s pull count.", repository)
				if err := dao.IncreasePullCount(repository); err != nil {
					log.Errorf("Error happens when increasing pull count: %v", repository)
				}
			}()

			// update the artifact pull time, and ignore the events without tag.
			if tag != "" {
				go func() {
					artifactQuery := &models.ArtifactQuery{
						PID:  pro.ProjectID,
						Repo: repository,
					}

					// handle pull by tag or digest
					pullByDigest := utils.IsDigest(tag)
					if pullByDigest {
						artifactQuery.Digest = tag
					} else {
						artifactQuery.Tag = tag
					}

					afs, err := dao.ListArtifacts(artifactQuery)
					if err != nil {
						log.Errorf("Error occurred when to get artifact %v", err)
						return
					}
					if len(afs) > 0 {
						log.Warningf("get multiple artifact records when to update pull time with query :%d-%s-%s, "+
							"all of them will be updated.", artifactQuery.PID, artifactQuery.Repo, artifactQuery.Tag)
					}

					// ToDo: figure out how to do batch update in Pg as beego orm doesn't support update multiple like insert does.
					for _, af := range afs {
						log.Debugf("Update the artifact: %s pull time.", af.Repo)
						af.PullTime = time.Now()
						if err := dao.UpdateArtifactPullTime(af); err != nil {
							log.Errorf("Error happens when updating the pull time of artifact: %d-%s, with err: %v",
								artifactQuery.PID, artifactQuery.Repo, err)
						}
					}
				}()
			}

		}
	}
}
```
