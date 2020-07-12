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
			//实际鉴权逻辑
			return rbac.HasPermission(user, resource, action)
		}
	}
	return false
}
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
//请求的参数（实体、资源和方法）都相等，即在策略文件内容中能找到，那么返回策略结果(p.eft)；找不到即deny。策略结果会保存在p.eft中。
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

5. **role**
进行role的定义，比如：
```
[role_definition]
g = _, _
g2 = _, _
g3 = _, _, _
```
其中，g, g2, g3 表示不同的 RBAC 体系, _, _ 表示用户和角色 _, _, _ 表示用户, 角色, 域。role的定义被matchers调用，来确定policy，比如g(r.sub, p.sub)表示r和q的用户和角色相同。

### policy文件

policy文件的内容为需要进行鉴权的请求描述，其格式按照**model文件中policy**的定义描述，比如：
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

回到harbor的具体应用，其对casbin的调用位于`common/rbac/rbac.go`的函数`HasPermission`:
```go
//user即封装了secContext、project、projectRoles的vistor,resource即带访问的project描述，action即操作
func HasPermission(user User, resource Resource, action Action) bool {
	return enforcerForUser(user).Enforce(user.GetUserName(), resource.String(), action.String())
}
```
上述代码中，User接口的实现位于`common/rbac/project/vistor.go`,其定义如下：
```go
func NewUser(ctx visitorContext, namespace rbac.Namespace, projectRoles ...int) rbac.User {
	return &visitor{
		ctx:          ctx,   //securityContext
		namespace:    namespace,	// projectNamespace封装了projectID以及isPublic属性，实现了rbac.Namespace接口
		projectRoles: projectRoles, //s.GetProjectRoles(projectID)的返回，返回对于某个project，对应user持有的所有角色列表（[]int形式）
	}
}
```
注意，这里User的含义不再是指账户or用户，而是**资源请求者**，里面包含了资源申请者描述以及待审批的资源描述。
继续回到`HasPermission`中，其第一句`enforcerForUser(user)`内部
```go
func enforcerForUser(user User) *casbin.Enforcer {
	//casbin的model文件
	m := model.Model{}
	//加载model文件
	m.LoadModelFromText(modelText)
	//Enforcer是进行鉴权和policy管理的核心接口，adapter用于不同的policy加载具体实现
	e := casbin.NewEnforcer(m, &userAdapter{User: user})
	//加载执行matcher策略需要的func
	e.AddFunction("keyMatch2", keyMatch2Func)
	return e
}
```
### model

在这里可以看到重要的**model文件**和**ploicy文件**的影子，首先是model文件，也就是一个字符串modelText:
```
# Request definition
[request_definition]
r = sub, obj, act

# Policy definition
[policy_definition]
p = sub, obj, act, eft

# Role definition , 只定义用户和角色（）
[role_definition]
g = _, _

# Policy effect， 鉴权结果约束
[policy_effect]
e = some(where (p.eft == allow)) && !some(where (p.eft == deny))

# Matchers，匹配policy条目需要的匹配规则
[matchers]
m = g(r.sub, p.sub) && keyMatch2(r.obj, p.obj) && (r.act == p.act || p.act == '*')
```

### adapter

继续查看`enforcerForUser`函数，当model定义完成后，执行NewEnforcer(m, &userAdapter{User: user})，Enforcer是进行鉴权和策略管理的核心接口，因此，策略加载的逻辑在userAdapter中实现。userAdapter中包含了匿名字段User接口，其具体实现就是上节中的vistor，代表资源申请者。userAdapter同时实现了casbin接口`persist.Adapter`:
```go
// Adapter is the interface for Casbin adapters.
type Adapter interface {
	// LoadPolicy loads all policy rules from the storage.
	LoadPolicy(model model.Model) error
	// SavePolicy saves all policy rules to the storage.
	SavePolicy(model model.Model) error

	// AddPolicy adds a policy rule to the storage.
	// This is part of the Auto-Save feature.
	AddPolicy(sec string, ptype string, rule []string) error
	// RemovePolicy removes a policy rule from the storage.
	// This is part of the Auto-Save feature.
	RemovePolicy(sec string, ptype string, rule []string) error
	// RemoveFilteredPolicy removes policy rules that match the filter from the storage.
	// This is part of the Auto-Save feature.
	RemoveFilteredPolicy(sec string, ptype string, fieldIndex int, fieldValues ...string) error
}
```
其实际实现的是LoadPolicy方法：
```go
func (a *userAdapter) LoadPolicy(model model.Model) error {
	//获取user的所有policy定义
	for _, line := range a.getUserAllPolicyLines() {
		persist.LoadPolicyLine(line, model)
	}
	return nil
}
```
因此可以看到核心语句为`getUserAllPolicyLines()`，继续进入实现：
```go
func (a *userAdapter) getUserAllPolicyLines() []string {
	lines := []string{}
	//如果没有认证，返回“anonymous”，否则返回securityContext中的username
	username := a.GetUserName()
	// returns empty policy lines if username is empty
	//username为空直接返回，意味着policy为空，因此任何的请求都失败
	if username == "" {
		return lines
	}
	//1.获取User的policy
	lines = append(lines, a.getUserPolicyLines()...)
	//2.获取User对应的Role的policy
	for _, role := range a.GetRoles() {
		lines = append(lines, a.getRolePolicyLines(role)...)
		//3.获取UserName和Role之间的policy
		lines = append(lines, fmt.Sprintf("g, %s, %s", username, role.GetRoleName()))
	}
	return lines
}
```
从上述代码可以看到，policy的内容主要由3部分组成：描述User的Policy,描述Role的Policy以及描述User和Role关系的Policy。

1. **User Policy** 

获取User Policy的函数入口位于`getUserPolicyLines`:
```go
func (a *userAdapter) getUserPolicyLines() []string {
	lines := []string{}
	...
	for _, policy := range a.GetPolicies() {
		//format为policy的合法格式
		line := fmt.Sprintf("p, %s, %s, %s, %s", username, policy.Resource, policy.Action, policy.GetEffect())
		lines = append(lines, line)
	}
	return lines
}
```
而policy的加载最终由vistor的GetPloicies实现，此时**加载的policy都针对公有项目or请求者是admin，对于公有项目，任何人可见可查询**：
```go
func (v *visitor) GetPolicies() []*rbac.Policy {
	if v.ctx.IsSysAdmin() {
		//加载admin的policy
		return GetAllPolicies(v.namespace)
	}
	if v.namespace.IsPublic() {
		//加载public  project policy
		return PoliciesForPublicProject(v.namespace)
	}
	return nil
}
```
以admin为例:
```go
// GetAllPolicies returns all policies for namespace of the project
func GetAllPolicies(namespace rbac.Namespace) []*rbac.Policy {
	policies := []*rbac.Policy{}
	//加载allPolicy
	for _, policy := range allPolicies {
		//将all policy的描述封装为rbac.Policy并添加进切片
		policies = append(policies, &rbac.Policy{
			Resource: namespace.Resource(policy.Resource),
			Action:   policy.Action,
			Effect:   policy.Effect,
		})
	}
	return policies
}
```
其中rbac.Policy的定义为：
```go
type Policy struct {
	//资源描述，会调用namespace.Resource去format为类似 project/{pid}/label，其中的label即加载的policy数组定义的Rosource
	Resource
	//加载的policy数据中的action描述
	Action
	//默认allow
	Effect
}
```
再看加载的admin的policy的定义：
```go
allPolicies = []*rbac.Policy{
		{Resource: rbac.ResourceSelf, Action: rbac.ActionRead},
		{Resource: rbac.ResourceSelf, Action: rbac.ActionUpdate},
		{Resource: rbac.ResourceSelf, Action: rbac.ActionDelete},
		...
	}
```
回到userAdapter的`getUserPolicyLines`，可知返回的user policy大致内容为：
```
p, zhangsan, porject/{pid}/label, read, allow
```

2. **Role Policy**

role Policy的加载逻辑和User类似，首先获取user中的roleIDs，然后在rolePoliciesMap中加载对应的策略,**，如果username对于该项目没有角色，则没有roleID，相应的不会加载role policy**,:
```go
func (a *userAdapter) getUserAllPolicyLines() []string {
	...
	lines = append(lines, a.getUserPolicyLines()...)
	//a.GetRole获取a的所有Role
	for _, role := range a.GetRoles() {
		lines = append(lines, a.getRolePolicyLines(role)...)
		lines = append(lines, fmt.Sprintf("g, %s, %s", username, role.GetRoleName()))
	}
	return lines
}

func (a *userAdapter) getRolePolicyLines(role Role) []string {
	lines := []string{}
	...
	//加载role相关的policy
	for _, policy := range role.GetPolicies() {
		line := fmt.Sprintf("p, %s, %s, %s, %s", roleName, policy.Resource, policy.Action, policy.GetEffect())
		lines = append(lines, line)
	}
	return lines
}
```
其中role相关policy的定义如下：
```go
rolePoliciesMap = map[string][]*rbac.Policy{
		"projectAdmin": {
			{Resource: rbac.ResourceSelf, Action: rbac.ActionRead},
			{Resource: rbac.ResourceSelf, Action: rbac.ActionUpdate},
			{Resource: rbac.ResourceSelf, Action: rbac.ActionDelete},
			...
		}，
		"master": {
		...
		}
		...			
```
因此，role poicy的内容最终为：
```
p, projectAdmin, project/{pid}/label, allow
```

3. **UserName&Role Policy**

继续回到getUserAllPolicyLines，可以看到同样的需要获取UserName和Role的关系：
```go
func (a *userAdapter) getUserAllPolicyLines() []string {
	...
	lines = append(lines, a.getUserPolicyLines()...)
	//a.GetRole获取a的所有Role
	for _, role := range a.GetRoles() {
		lines = append(lines, a.getRolePolicyLines(role)...)
		//获取username和role的关系
		lines = append(lines, fmt.Sprintf("g, %s, %s", username, role.GetRoleName()))
	}
	return lines
}

func (role *visitorRole) GetRoleName() string {
	switch role.roleID {
	case common.RoleProjectAdmin:
		return "projectAdmin"
	case common.RoleMaster:
		return "master"
	case common.RoleDeveloper:
		return "developer"
	case common.RoleGuest:
		return "guest"
	default:
		return ""
	}
}
```
即最终的policy内容为：
```
g, zhangsan, projectAdmin
```
至此，policy的内容加载完毕。

## 鉴权

回到函数HasPermission，在model和policy内容加载完成后，执行enforce：
```go
// HasPermission returns whether the user has action permission on resource
func HasPermission(user User, resource Resource, action Action) bool {
	return enforcerForUser(user).Enforce(user.GetUserName(), resource.String(), action.String())
}
```

### 场景1

假设zhangsan要对projectID=1的资源label进行delete操作（zhangsan为项目管理projectAdmin，project为私有，有权限），其涉及的步骤如下：
1. req = zhangsan, project/1/label, delete
2. 根据加载的policy中，存在以下条目：
```
p, projectAdmin, project/1/label, delete
```
3. 根据username和role关系，存在：
```
g, zhangsan, projectAdmin
```
4. 使用matchers的规则，将req匹配到对应的policy条目上，鉴权通过。

### 场景2

假设zhangsan要对projectID=2的资源label进行delete操作（project为私有，zhangsan在该项目中无角色，因此无权限），其涉及的步骤如下：
1. req = zhangsan, project/2/label, delete
2. 根据加载的policy中，**由于私有项目，张三没有具体角色，因此即没有user policy也没有role policy**
3. 同样也没有 username&role policy
4. 使用matchers的规则，没有匹配的policy条目上，鉴权失败。


### matchers

在上述鉴权过程中，model文件中matchers定义和加载如下：
```
func enforcerForUser(user User) *casbin.Enforcer {
	...
	e.AddFunction("keyMatch2", keyMatch2Func)
	return e
}

...
# Matchers
[matchers]
m = g(r.sub, p.sub) && keyMatch2(r.obj, p.obj) && (r.act == p.act || p.act == '*')
```
其中keyMatch2Func内容为，主要工作就是对要操作的对象进行mathch：
```go
func keyMatch2Func(args ...interface{}) (interface{}, error) {
	name1 := args[0].(string)
	name2 := args[1].(string)
	//name即project/{pid}/{subresource} ,例如project/1/label
	return bool(keyMatch2(name1, name2)), nil
}

// keyMatch2 determines whether key1 matches the pattern of key2, its behavior most likely the builtin KeyMatch2
// except that the match of ("/project/1/robot", "/project/1") will return false
func keyMatch2(key1 string, key2 string) bool {
	key2 = strings.Replace(key2, "/*", "/.*", -1)
	re := regexp.MustCompile(`(.*):[^/]+(.*)`)
	for {
		if !strings.Contains(key2, "/:") {
			break
		}

		key2 = re.ReplaceAllString(key2, "$1[^/]+$2")
	}
	return util.RegexMatch(key1, "^"+key2+"$")
}
```

## 总结

至此，harbor的鉴权过程分析完毕，总的来说，harbor通过casbin框架进行具体的鉴权操作。model的定义是预先配置好的，当鉴权请求到来后（securityContext中的Can调用），根据请求者身份和要操作的project，动态加载policy(从内存中，即预先定义的数组)，最终根据req和加载的policy，执行model中的鉴权规则。