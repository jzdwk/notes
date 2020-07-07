# core auth

harbor支持多种认证模式，包括了：

- Database Authentication
- [LDAP](https://www.openldap.org/) \/Active Directory Authentication:
- [OIDC](openid.net/connect/) Provider Authentication

具体操作详情[参照doc](https://goharbor.io/docs/2.0.0/administration/configure-authentication/) 

## init

harbor的core模块基于beego，因此对于api的认证由beego的filter实现：
```
	filter.Init()
	//rest api session
	beego.InsertFilter("/api/*", beego.BeforeStatic, filter.SessionCheck)
	//所有api的ac
	beego.InsertFilter("/*", beego.BeforeRouter, filter.SecurityFilter)
	//只读资源控制
	beego.InsertFilter("/*", beego.BeforeRouter, filter.ReadonlyFilter)
```

首先进入`filter.Init()`,具体的实现如下：
```
func Init() {
	// integration with admiral
	if config.WithAdmiral() {
		reqCtxModifiers = []ReqCtxModifier{
			&secretReqCtxModifier{config.SecretStore},
			&tokenReqCtxModifier{},
			&basicAuthReqCtxModifier{},
			&unauthorizedReqCtxModifier{}}
		return
	}

	// standalone
	reqCtxModifiers = []ReqCtxModifier{
		&configCtxModifier{},
		&secretReqCtxModifier{config.SecretStore},
		&oidcCliReqCtxModifier{},
		&idTokenReqCtxModifier{},
		&authProxyReqCtxModifier{},
		&robotAuthReqCtxModifier{},
		&basicAuthReqCtxModifier{},
		&sessionReqCtxModifier{},
		&unauthorizedReqCtxModifier{}}
}
```
上述代码其实初始化了reqCtxModifiers这个请求上下文切片，每一个元素表示了一种过滤的具体方式，并实现了其modify方法。比如`configCtxModifier`在上下文中增加了配置信息，`oidcCliReqCtxModifier`首先校验是否使用了oidc认证等。**注意各个元素的填充顺序，当调用顺序靠前的Modifier的Modify方法并返回true后，后面的Modifier则不再调用。因此，这里authn的顺序为首先进行oidc,然后是idToken，以此类推。**
其中对于[admiral](https://vmware.github.io/admiral/) 的config方式进行了特殊处理，它是vmware的一个容器管理平台，暂且不用管。

## SessionCheck

session check顾名思义，主要用于session的检查，当请求上下文中携带session信息，具体来说是http请求中包含sid的cookie时，封装一个新的包含k-v的(代码中就是是否包含session的flag)context，并调用`req.WithContext`拷贝req对象，将新的context赋值给req，并替换掉原req：
```
func SessionCheck(ctx *beegoctx.Context) {
	req := ctx.Request
	_, err := req.Cookie(config.SessionCookieName)
	if err == nil {
		ctx.Request = req.WithContext(context.WithValue(req.Context(), SessionReqKey, true))
		log.Debug("Mark the request as no-session")
	}
}
```
上述代码提供了修改req中context的标准解法，即先获取req，再根据业务需求，调用`context.WithValue`封装新的context,再调用`req.WithContext`将其赋值给req。*思考？为什么req的context没有对外暴露，让开发者直接操作？答：对context的修改做了约束，只能够新增kv，而不提供修改原context。*

## SecurityFilter

这个filter主要完成了对所有api的认证操作，对之前init的ReqCtxModifier数组进行循环调用modify：
```
	//nil handler
	
	for _, modifier := range reqCtxModifiers {
		if modifier.Modify(ctx) {
			break
		}
	}
```
当有一个modify返回true，说明验证通过，直接break，因此此处的Modifiers的遍历顺序取决于之前init的数组各元素顺序。

### basicAuthReqCtxModifier

以http basic auth的认证方式为例子，basic方式即使用http的basic auth作为认证信息的载体，当之前modifier返回false，即没有使用诸如oidc的话，进入此函数。具体实现如下：
```
func (b *basicAuthReqCtxModifier) Modify(ctx *beegoctx.Context) bool {
	//从req中获取认证信息
	username, password, ok := ctx.Request.BasicAuth()
	...
	// integration with admiral
	if config.WithAdmiral() {
		...
	}

	// 调用dao层认证
	user, err := auth.Login(models.AuthModel{
		Principal: username,
		Password:  password,
	})
	... err handle
    //认证通过，将pm和认证的后的user信息封装成SecurityContext，将其一并加入req的context，和session中的处理一致
	pm := config.GlobalProjectMgr
	securCtx := local.NewSecurityContext(user, pm)
	setSecurCtxAndPM(ctx.Request, securCtx, pm)
	return true
}
```
注意，这里的认证方式，指的是http请求发送时，认证信息的承载方式，而不是具体的认证实现。比如basicAuthReqCtxModifier描述了http的basic auth认证，从basic auth取得身份信息后，具体的身份验证要根据配置从db/ldap里校验，即在Login中完成。具体的Login实现如下：
```
func Login(m models.AuthModel) (*models.User, error) {
	//从配置中获取认证模式，有基于db的/ldap/oidc等
	authMode, err := config.AuthMode()
	...	
	//默认为db模式，其他的还有ldap等
	if authMode == "" || dao.IsSuperUser(m.Principal) {
		authMode = common.DBAuth
	}
	//根据认证模式，从registry中获取对应的AuthenticateHelper接口，这个接口提供了不同认证模式下的账户管理方法，AuthenticateHelper的实现在不同的认证模式的init函数中加载。
	authenticator, ok := registry[authMode]
	...
	//根据得到的具体认证器实现authenticator，进行认证
	user, err := authenticator.Authenticate(m)
	if err != nil {
		if _, ok = err.(ErrAuth); ok {
			log.Debugf("Login failed, locking %s, and sleep for %v", m.Principal, frozenTime)
			lock.Lock(m.Principal)
			time.Sleep(frozenTime)
		}
		return nil, err
	}
	err = authenticator.PostAuthenticate(user)
	return user, err
}
```
上述代码通过authmode，获取对应的认证器authenticator来完成实际的认证过程，其中认证器authenticator的继承结构如下：
```
db/ldap/authproxy等具体authenticator-继承->DefaultAuthenticateHelper-实现->AuthenticateHelper
```
## ReadonlyFilter

第三个注册的过滤器主要使用了whitelist来约束read-only模式下使用harbor的行为，当前部署模式下无需考虑：
```
func filter(req *http.Request, resp http.ResponseWriter) {
	if !config.ReadOnly() {
		return
	}
	
	if matchRepoTagDelete(req) || matchRetag(req) {
		resp.WriteHeader(http.StatusServiceUnavailable)
		_, err := resp.Write([]byte("The system is in read only mode. Any modification is prohibited."))
		if err != nil {
			log.Errorf("failed to write response body: %v", err)
		}
	}
}
```

qutation: 
- https://zhuanlan.zhihu.com/p/61151082 harbor源码浅析