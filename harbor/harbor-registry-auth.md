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

1. docker login

- http header: 4个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。其中Authoriztion的值为Basic base64(usr:pwd)
- http url:/self-define/auth?account=user1&client_id=docker&offline_token=true&service=harbor-registry

可以看到login时请求的认证信息

2. docker pull

- http header(未登录): 3个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。
- http header(已登录): 4个k-v，User-Agent，Authoriztion，Accept-Encoding，Connection。其中Authoriztion的值为Basic base64(usr:pwd)
- http url(未登录):/self-define/auth?scope=repository%3Ausr1test1%2Fbusybox%3Apull&service=harbor-registry
- http url(已登录):/self-define/auth?account=user2&scope=repository%3Ausr1test1%2Fbusybox%3Apull&service=harbor-registry

可以看到docker pull时携带的请求资源信息，包括了repo/repoInfo/操作(pull)，当已经登录，也会携带登录的信息，这个行为同样应用于docker push

3. k8s docker pull

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
```
...
beego.Router("/service/token", &token.Handler{})
...
```
进入这个`Handler`，可以看到其`Get`方法用于处理token，直接进入主逻辑：
```
func (g generalCreator) Create(r *http.Request) (*models.Token, error) {
	var err error
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



