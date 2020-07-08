# harbor core authorize

在harbor core中，使用了filter完成了[请求认证](harbor-core-authn) 相关的工作，在对具体的资源进行操作前，需要进行鉴权处理，确认当前的登录者对资源对象存在操作权限。

harbor的管理对象是project，因此，以delete project为角度切入，进行分析。

首先，在`router.go`文件中定位`beego.Router("/api/projects/:id([0-9]+)/_deletable", &api.ProjectAPI{}, "get:Deletable")`,进入方法实现，可以看到：

1. 在projectAPI上，定义了`Prepare()`方法：
```go
func (p *ProjectAPI) Prepare() {
	//调用BaseController，Base级完成了将context中的securityContext和pm解析，赋给BaseController
	p.BaseController.Prepare()
	//获取project id
	if len(p.GetStringFromPath(":id")) != 0 {
		//error handle，如果id有问题or找不到对应Project，返回400等
		...
		p.project = project
	}
}
```
严格意义上，prepare中的逻辑并没有进行鉴权操作，只是类似filter的功能，和filter的不同是，filter的粒度更粗（当然可以根据正则细化），而prepare完成了在具体模块（project）的业务过滤。

2. 进入`Deletable()`函数，看到`p.requireAccess(rbac.ActionDelete)`，即鉴权的主要调用，其核心逻辑在BaseController中调用：
```go
// RequireProjectAccess returns true when the request has action access on project subresource
// otherwise send UnAuthorized or Forbidden response and returns false
//Project的鉴权函数，第一个参数是Project实体，第二个表示执行的操作（pull/push/crud/list/scanner等），subresource表示project下的子资源
func (b *BaseController) RequireProjectAccess(projectIDOrName interface{}, action rbac.Action, subresource ...rbac.Resource) bool {
	hasPermission, err := b.HasProjectPermission(projectIDOrName, action, subresource...)
	if err != nil {
		if err == errNotFound {
			b.SendNotFoundError(fmt.Errorf("project %v not found", projectIDOrName))
		} else {
			b.SendInternalServerError(err)
		}

		return false
	}

	if !hasPermission {
		if !b.SecurityCtx.IsAuthenticated() {
			b.SendUnAuthorizedError(errors.New("UnAuthorized"))
		} else {
			b.SendForbiddenError(errors.New(b.SecurityCtx.GetUsername()))
		}

		return false
	}

	return true
}
```
