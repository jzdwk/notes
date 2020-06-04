# harbor registry auth

harbor的业务认证位于core的filter中实现，参见[core-auth](harbor-core-auth)。此外，需要对docker login进行认证，并将认证结果返回给docker。

docker login的认证标准可以[参考](https://docs.docker.com/registry/spec/auth/token/) 。harbor在这里的主要所用是扮演了[v2 registry](https://docs.docker.com/registry/) 的角色。

## registry配置

首先根据harbor docker-compose的配置，可以看到关于v2 registry的配置位置：
```
registry:
  ..
  volumes:
  ...
    - /common/config/registry/:/etc/registry/
	...
```
进入相应目录，里面的`config.yml`即具体配置，看到有关认证的项auth：
```
auth:
  token:
     issuer: harbor-token-issuer
	 realm: https://XXX/service/token
	 ...
```
这个`realm`就是返回给docker的用于真正鉴权的地址。

### 测试

当在harbor的commone中将registry的配置文件relm项进行修改，改为自定义的地址，则docker的授权请求将发送至此地址，其内容为：

1. **docker login**

- http header: 4个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。其中Authoriztion的值为Basic base64(usr:pwd)
- http url:/self-define/auth?account=user1&client_id=docker&offline_token=true&service=harbor-registry

可以看到login时请求的认证信息

2. **docker pull**

- http header(未登录): 3个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。
- http header(已登录): 4个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。其中Authoriztion的值为Basic base64(usr:pwd)
- http url(未登录):/self-define/auth?scope=repository%3Ausr1test1%2Fbusybox%3Apull&service=harbor-registry
- http url(已登录):/self-define/auth?account=user2&scope=repository%3Ausr1test1%2Fbusybox%3Apull&service=harbor-registry

可以看到docker pull时携带的请求资源信息，包括了repo/repoInfo/操作(pull)，当已经登录，也会携带登录的信息，这个行为同样应用于docker push。其中的`%3a`对应于ASCII中的符号`:`，`%2F`对应`/`。即`scope=repository:usr1test1/busybox:pull`，类型：image：操作。

3. **k8s docker pull**

当使用k8s资源对象创建pod时，pod的image如果为harbor私有镜像提供，则需要增加secret，例子如下：
```
apiVersion: v1
kind: ReplicationController
metadata:
  name: busy
spec:
  replicas: 1
  selector:
    app: busy
  template:
    metadata:
      labels:
        app: busy
    spec:
      containers:
      - name: busy
        image: myharbor.com/usr1test1/busybox:1.0
      imagePullSecrets:
      - name: harbor-key

```
其中imagePullSecrets中的secret定义如下：
```
kubectl  create secret docker-registry harbor-key \
--docker-server=myharbor.com \
--docker-username=user2 \
--docker-password=<your-pword> \
```
此时，将有k8s调用docker的pull接口，最终发送给authZ的请求与docker pull一致：

- http header(已登录): 4个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。其中Authoriztion的值为Basic base64(usr:pwd)
- http url(已登录):/self-define/auth?account=user2&scope=repository%3Ausr1test1%2Fbusybox%3Apull&service=harbor-registry


## 鉴权

查看habror中core的route。可看到对于token的处理函数定义：
```go
...
beego.Router("/service/token", &token.Handler{})
...
```
进入这个`Handler`，可以看到其`Get`方法用于处理token，这里需要注意的代码为选择合适的creator:
```go
func (h *Handler) Get() {
	request := h.Ctx.Request
	//service就是在上文的get请求中携带的service项，即harbor-registry
	service := h.GetString("service")
	tokenCreator, ok := creatorMap[service]
	...
	//创建token，返回
	token, err := tokenCreator.Create(request)
	...
	h.Data["json"] = token
	h.ServeJSON()

}
```
接下来，直接进入主逻辑Create：
```go
func (g generalCreator) Create(r *http.Request) (*models.Token, error) {
	var err error
	//scopes 就是上文中get请求中url后携带的scope=类型:image:操作
	scopes := parseScopes(r.URL)
	...
	ctx, err := filter.GetSecurityContext(r)
	...
	//获取请求的pm
	pm, err := filter.GetProjectManager(r)
	...
	//鉴权逻辑
	access := GetResourceActions(scopes)
	err = filterAccess(access, ctx, pm, g.filterMap)
	//鉴权通过后创建token
	return MakeToken(ctx.GetUsername(), g.service, access)
}
```

上述代码中，`GetResourceActions`完成简单的字符串解析，将get请求中的scope字段封装为了`ResourceActions`:
```go
type ResourceActions struct {
	Type    string   // 类型，对应于请求中scope=后冒号分割的第一个字段
	Class   string  
	Name    string   // repo/image，对应于请求中scope=后冒号分割的第二个字段
	Actions []string //资源操作，对应于请求中scope=后冒号分割的第三个字段
}
```
然后便是鉴权的核心逻辑`filterAccess(access, ctx, pm, g.filterMap)`，进入实现：
```go
func filterAccess(access []*token.ResourceActions, ctx security.Context,
	pm promgr.ProjectManager, filters map[string]accessFilter) error {
	var err error
	for _, a := range access {
		//filter有两种实现，repository和registry，因为get请求的type=repository,所以得到前者
		f, ok := filters[a.Type]
		...
		//执行repository的filter
		err = f.filter(ctx, pm, a)
		...
	}
	return nil
}
```
这一步就是获取对应的filter，直接进入对应的实现repositoryFilter:
```go
func (rep repositoryFilter) filter(ctx security.Context, pm promgr.ProjectManager,
	a *token.ResourceActions) error {
	// 得到image值
	img, err := rep.parser.parse(a.Name)
	...
	projectName := img.namespace
	permission := ""
	project, err := pm.Get(projectName)
	...
	//权限处理
	resource := rbac.NewProjectNamespace(project.ProjectID).Resource(rbac.ResourceRepository)
	//生成actions，用于token内容的生成
	if ctx.Can(rbac.ActionPush, resource) && ctx.Can(rbac.ActionPull, resource) {
		permission = "RWM"
	} else if ctx.Can(rbac.ActionPush, resource) {
		permission = "RW"
	} else if ctx.Can(rbac.ActionScannerPull, resource) {
		permission = "RS"
	} else if ctx.Can(rbac.ActionPull, resource) {
		permission = "R"
	}
	a.Actions = permToActions(permission)
	return nil
}
```
综上，filter根据user和repo的属性进行鉴权，在这个过程中一旦出错，说明鉴权失败。如果filter执行成功，则开始创建token。此处生成的token符合[jwt规范](http://self-issued.info/docs/draft-ietf-oauth-json-web-token.html) ,[简单介绍](https://www.jianshu.com/p/576dbf44b2ae) 请戳：
```go
func MakeToken(username, service string, access []*token.ResourceActions) (*models.Token, error) {
	//从配置中获取生成token的key
	pk, err := libtrust.LoadKeyFile(privateKey)
	...
	//过期时间
	expiration, err := config.TokenExpiration()
	...
	//issuer=harbor-token-issuer，username=user2，service=harbor-registry
	tk, expiresIn, issuedAt, err := makeTokenCore(issuer, username, service, expiration, access, pk)
	...
	//最后base64签名
	rs := fmt.Sprintf("%s.%s", tk.Raw, base64UrlEncode(tk.Signature))
	//返回token
	return &models.Token{
		Token:     rs,
		ExpiresIn: expiresIn,
		IssuedAt:  issuedAt.Format(time.RFC3339),
	}, nil
}
```
其中的makeTokenCore即根据入参创建jwt的token，为标准实现，生成的token内容为，其中的**Access**描述具体的权限，这个Access的描述也就是**实现鉴权的关键**：
- Header；
```json
{
	"Type":"JWT",
	"SigningAlg":"RS256", //算法
	"KeyID":"XXXX",
	"X5c":null,
	"RawJWK":null
}
```
- Claims:
```json
{
	"Issuer":"harbor-token-issuer",
	"Subject":"user2",   //用户
	"Audience":"harbor-registry",
	"Expiration":"XXX",  //时间约束
	"NotBefore":"XXX",
	"IssuedAt":"XXX",
	"JWTID":"XXX",
	"Access":[
		{
			"Type":"repository",  //类型
			"Class":null,
			"Name":"repo/image"  //image描述
			"Actions":["pull"]  //可列出的项有且只能是["pull","push","*"]
		}
	]
}
```
- Signature，即HMAC(base64(Header)+base64(claims),pk)


。最终authZ service将token返回给docker(registry client)后，docker再将此token发送给registry完成请求。


