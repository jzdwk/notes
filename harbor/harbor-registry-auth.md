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
	//获取请求的
	pm, err := filter.GetProjectManager(r)
	...
	//鉴权逻辑
	access := GetResourceActions(scopes)
	err = filterAccess(access, ctx, pm, g.filterMap)
	//鉴权通过后创建token
	return MakeToken(ctx.GetUsername(), g.service, access)
}
```



