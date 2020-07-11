# harbor core authorize


## prepare

prepare中的逻辑并没有进行鉴权操作，只是类似filter的功能，和filter的不同是，filter的粒度更粗（当然可以根据正则细化），而prepare完成了在具体模块（project）的业务过滤。

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
//Project的鉴权函数，第一个参数是Project实体，第二个表示执行的操作（pull/push/crud/list/scanner等），subresource表示project下的子资源
func (b *BaseController) RequireProjectAccess(projectIDOrName interface{}, action rbac.Action, subresource ...rbac.Resource) bool {
	hasPermission, err := b.HasProjectPermission(projectIDOrName, action, subresource...)
	if err != nil {
		...
		return false
	}

	if !hasPermission {
		...
		return false
	}
	return true
}
```

## rbac resource

继续进入`HasProjectPermission`,函数中根据projectIDOrName得到主键后，将访问资源进行描述：
```go
func (b *BaseController) HasProjectPermission(projectIDOrName interface{}, action rbac.Action, subresource ...rbac.Resource) (bool, error) {
	//get project id
	...
	//resource就是string，描述了访问资源，如 /project/{id}/{subresources}...等等
	resource := rbac.NewProjectNamespace(projectID).Resource(subresource...)
	if !b.SecurityCtx.Can(action, resource) {
		return false, nil
	}
	return true, nil
}
```
SecurityCtx实现了security包中的Context接口，该接口的Can用于鉴权，以`local`包下为例：
```go
// Can returns whether the user can do action on resource
func (s *SecurityContext) Can(action rbac.Action, resource rbac.Resource) bool {
	ns, err := resource.GetNamespace()
	//因为harbor的资源控制最小单位是project，因此直接case project
	if err == nil {
		switch ns.Kind() {
		case "project":
			projectID := ns.Identity().(int64)
			isPublicProject, _ := s.pm.IsPublic(projectID)
			projectNamespace := rbac.NewProjectNamespace(projectID, isPublicProject)
			//NewUser返回了一个visitor，这个visitor实现了rbac的User接口
			user := project.NewUser(s, projectNamespace, s.GetProjectRoles(projectID)...)
			return rbac.HasPermission(user, resource, action)
		}
	}
	return false
}
```
上述代码中，根据resource的描述，封装了一个RBAC模块的User接口实现`vistor`，*怀疑这里的vistor使用了访问者模式，待验证*：
```go
func NewUser(ctx visitorContext, namespace rbac.Namespace, projectRoles ...int) rbac.User {
	return &visitor{
		ctx:          ctx,   //securityContext
		namespace:    namespace,	// projectNamespace，实现了rbac.Namespace接口
		projectRoles: projectRoles, //s.GetProjectRoles(projectID)的返回，返回对于某个project，对应user持有的所有角色列表
	}
}
```
然后进入`rbac.HasPermission(user, resource, action)`，可以看到内部只有一句:
```go
	enforcerForUser(user).Enforce(user.GetUserName(), resource.String(), action.String())
```

## casbin

[casbin](https://github.com/casbin/casbin) 是一个AC框架，通过**PERM**来进行权限控制，PERM即policy,effect,request,mathchers。在casbin中，重要的配置由两部分，第一部分是**model文件**定义，model的作用主要为定义鉴权的规则;另一部分是**policy文件**定义。

### model文件

model文件主要是定义了鉴权的规则，包含了4部分，即policy,effect,request,matchers:

1. **policy**
定义访问策略的模型。其实就是定义**Policy规则文档**中各字段的名称和顺序。
```
//如果不定义 eft(策略结果)，那么将不会去读策略文件中的结果字段，并将匹配的策略结果都默认为allow。
p={sub, obj, act} 或 p={sub, obj, act, eft}
```
2. **request**
表示了带鉴权的请求，一个基本的请求是一个元组对象，至少包含subject（访问实体）, object（访问的资源）和 action（访问方法）。
```
//就是定义了传入访问控制匹配函数的参数名和顺序
r={sub, obj,act}
```
3. **matchers**
Request和Policy文件中内容的匹配规则。比如：
```
//请求的参数（实体、资源和方法）都相等，即在策略文件内容中能找到，那么返回策略结果(p.eft)。策略结果会保存在p.eft中。
m = r.sub == p.sub && r.act == p.act && r.obj == p.obj
```
4. **effect**
对Matchers匹配后的结果再进行一次逻辑组合判断的模型。例如：
```
//如果匹配策略结果p.eft 存在(some) allow的结果，那么最终结果就为 真
e = some(where(p.eft == allow))

//如果有匹配出结果为alllow的策略并且没有匹配出结果为deny的策略则结果为真，换句话说，就是匹配的策略都为allow时才为真，如果有任何deny，都为假
e = some(where (p.eft == allow)) && !some(where (p.eft == deny))
```

### policy文件

policy文件的内容为需要进行鉴权的请求描述，其格式按照model文件中policy中的定义描述，比如：
```
//表示zeta这个sub 对数据data1 执行read操作，是allow的
p, zeta, data1, read, allow
p, bob, data2, write, allow
p, zeta, data2, write, deny
p, zeta, data2, write, allow
```

### 执行

综上，根据model文件和policy的描述，可以得出使用casbin的鉴权过程：
1. 假设一个request请求（zeta,data1,read）到达
2. 根据request的描述，调用matchers规则，在policy文件中找到了对应的记录`zeta, data1, read, allow`，将记录allow保存至p.eft
3. 调用effect规则，因为所有的p.eft都为allow，则鉴权通过。

### 总结

因此，实现鉴权的关键就是定义出model文件以及policy文件内容。对于model文件，因为它其实是一个类似模板的通用配置，因此可在文件or直接的字符串中定义，对于policy，其描述了任意sub对于一个obj的操作act，因此在实际应用中，此数据可能来源于DB。

## harbor & casbin
