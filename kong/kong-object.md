# kong

主要介绍一下kong的各个资源对象的概念，并随着深入补充一下用例。

## admin api

kong admin api是所有kong资源/配置管理的入口,按照部署方式分为[普通版](https://docs.konghq.com/2.0.x/admin-api/)和[DB-less版](https://docs.konghq.com/2.0.x/db-less-admin-api/)。在k8s部署后，通过svc看到admin的端口号，默认为：

- http: 8001
- https: 8443

其具体的使用方式则根据kong的svc部署方式而定。另外，api接收两种格式的http请求：

- application/x-www-form-urlencoded
- application/json

下面列举一些常用的全局api：

- /status： 常见的性能和状态度量
- /config： kong的配置内容

具体使用参见官方doc。

## tag

tag可用于kong的所有资源对象中，这些对象通过tags属性进行标记。类似于k8s中的label，便于进行资源对象管理。因此，可通过tags进行资源检索。

### 注意

tag的检索使用“,”表示“与关系”，使用“/”表示“或关系”，不可交叉。

## service

一个service代表一个微服务实体，可以简单理解为一个网站的根地址www.test.com, 对于k8s场景来说，就是应用的svc，或者说是ingress中描述的host，service中最重要的属性是url(protocol,host,port,path)。service定义后，通过不同的route进行访问。
service创建例子如下：
```http POST :8001/services name=example_service url='http://mockbin.org'```

## route

route定义了一组用于匹配client请求的规则，每一个route都会对应到一个具体的service上，一个service可以包含多个不同的route。在k8s中，对于http应用，route就是svc对应的后端应用的rest的url，或者说是ingress中描述的path。一个请求指向kong proxy后，会根据定义的path，经proxy访问service对应的path。其请求路径为：

- request-->routers[]-->service

注意这个router是kong里的概念，位于service之前。这时，当访问kong proxy + /mock的时候，将直接转发至http://mockbin.org。

route创建例子如下：

```
http XX:8001/services/example_service/routes paths:='["/mock"]' name=mocking
```

配置path时，也可以使用正则进行匹配。除了path，route在路由时的约束还有host配置，如：

```
curl -i -X POST http://localhost:8001/routes/ \
    -H 'Content-Type: application/json' \
    -d '{"hosts":["example.com", "foo-service.com"]}'
```

此时，route将根http的请求头进行路由匹配，host的配置可以使用通配符,如\*.example.com。同样的，也可以增加method约束，以及除了host项的header约束，比如：
```
{
    "headers": { "version": ["v1", "v2"] },
    "service": {
        "id": "..."
    }
}
```
此时，请求头中带有version:v1或者v2的将被路由到指定的service。总的来说，在配置一个route时，不同的应用层约束如下：

- http, 至少包含一个 methods, hosts, headers or paths;
- https, 至少包含一个 methods, hosts, headers, paths or snis;
- tcp, 至少包含一个 sources or destinations;
- tls, 至少包含一个 sources, destinations or snis;
- grpc, 至少包含一个 hosts, headers or paths;
- grpcs, 至少包含一个 hosts, headers, paths or snis

从另一个角度说，**route在进行不同协议的请求路由时，上述的每一个条件都要匹配，否则将不可达**另外，当指定service后进行route配置时，上述的约束将根据service的内容一次性填充。

### 注意

当添加了多个route，且route对于host/path的配置相同，kong的匹配原则是：**将首先尝试匹配具有最多规则的路由**，举个例子：
```
{
    "hosts": ["example.com"],
    "service": {
        "id": "1"
    }
},
{
    "hosts": ["example.com"],
    "methods": ["POST"],
    "service": {
        "id": "2"
    }
}
```
kong将首先按第二个路由的定义进行匹配，如果是post方法，则路由到id为2的service，其余路由至1.

### 其他 

route的tls配置，以及对grpc等的代理，请[参考文档](https://docs.konghq.com/2.0.x/proxy/)

## consumer

consumer定义了对于一个service的使用者。这个使用者既可以使用kong来管理，也可以将user列表映射到外部DB，以保持Kong与现有主数据存储之间的一致性。*具体应用场景待了解*

## plugin

kong除了可以作为反向代理(通过配置route+service)，也可以通过plugin来增加功能，比如加入访问频次限制、缓存、auth-key。plugin实体表示了一个plugin的配置，这个plugin可以应用在整个http请求与返回的过程中，并可配置在不同的kong资源对象上。

### 例子

第一个例，添加一个流量限速的plugins操作：
```
http -f post :8001/plugins name=rate-limiting config.minute=5 config.policy=local
```
例子中通过api添加了一个限速的plugin，此时，当继续访问上文中的/mock，高于频次限制将返回提示信息。(这是一个global的配置)

第二个例子，添加一个内存的cache：
```
http -f :8001/plugins name=proxy-cache config.strategy=memory config.content_type="application/json"
```
此时，访问/mock时，将被缓存。

第三个例子，添加一个apikey用来验证api消费者的身份，注意这个plugins添加给了name为mock的route： 
```
http :8001/routes/mock/plugins name=key-auth
```
这时访问/mock，将返回401码，提示未通过认证。因此，我们需要创建一个apikey，首先，调用admin api的consumer接口创建一个consumer：
```
http :8001/consumers username=consumer1 custom_id=consumer1
```
然后，将创建的key添加到这个consumer：
```
http :8001/consumers/consumer1/key-auth key=apikey1
```
最后，再访问/mock时，带上这个apikey：
```
http :8000/mock/request apikey:apikey
```
### 注意

plugin在整个请求响应中，只会运行一次。但是，plugin可以定义在多个资源上，比如service,route以及consumer，不同资源的配置属性可能不同，换句话说，一个http请求可能会经历多个资源，举个例子：

1. curl -i -X GET http://www.test.com/req1 这个请求，我们定义了一个url是`http://http://www.test.com/req1`的service，当然，我们还需要定义一个path是req1的route。
2. 我们new了一个plugin，同时应用于service和route，在add进service是使用了配置A，route时，使用了配置B。

这个plugin如何工作？另外，还有一个场景是，如果我们想让多数请求都使用某一个plugin，如key-auth，但是，针对某些不同的请求，又有个性化配置，如何做到？因此，plugin的配置存在一个**优先级**，这个优先级的定义是：**plugin所指定的资源对象越具体越详细，它的优先级就越高**。因此，存在了以下的优先级顺序：

1. Plugins configured on a combination of: a Route, a Service, and a Consumer. (Consumer means the request must be authenticated).
2. Plugins configured on a combination of a Route and a Consumer. (Consumer means the request must be authenticated).
3. Plugins configured on a combination of a Service and a Consumer. (Consumer means the request must be authenticated).
4. Plugins configured on a combination of a Route and a Service.
5. Plugins configured on a Consumer. (Consumer means the request must be authenticated).
6. Plugins configured on a Route.
7. Plugins configured on a Service. 
8. Plugins configured to run globally. 

举一个例子：

- 在service和consumer上各添加了rate-limiting插件，但是使用了不同的配置，前者配置为A，后者配置为B，那么，当一个带有认证的请求在service和consumer上各添加了rate-limiting插件，但是使用了不同的配置，前者配置为A，后者配置为B，那么，当一个带有认证的请求(通过consumer)到来时，将使用配置B而忽略A。如果这个请求没有使用认证，则走配置A。如果将配置B置false，则所有请求都走配置A。
- 同样的，如果这个插件配置在了route(conf = A)和service(conf = B)时，访问该route,基于配置B，否则将基于配置A

## certificate

证书对象表示一个公钥证书。Kong使用这个对象来处理加密客户端的SSL/TLS请求，或在验证客户端/服务的对等证书时用作受信任的CA仓库。*证书的使用待了解*。

## ca certificate

CA配置相当于给kong添加一个内置的CA中心，用于对证书进行验证。

## SNI

sni对象维护了一个从hostname到cert证书的多对一的映射，也就是说，一个证书对象可以有许多与之关联的主机名。

## upstream 

upstream表示一个虚拟主机名，可用于在多个service(targets)上对请求进行负载平衡，upstream指的是service对象后的虚拟对象，主要用于和真正的host连接，并提供LB、熔断等。例如，一个名为service.v1.xyz的upstream对应主机为service.v1.xyz的服务对象，对该服务的请求将代理到upstream中定义的target。其整体流程是：

- request-->router-->service-->具体upstream(虚概念)-->targer(host)

一个upstream还包括一个健康检查程序，它能够根据target是否健康来启用和禁用target。健康检查可在upstream配置，并应用于它的所有target。

### 例子

首先，创建一个upstream，名为upstream1:
```
http POST :8001/upstreams name=upstream
```
将之前创建的example_service的host属性，指定为这个upstream，而不是之前的那个http地址，注意使用了PATCH方法：
```
http PATCH :8001/services/example_service host='upstream'
```
最后，将不同的实际targert地址添加至upstream的targets
```http POST :8001/upstreams/upstream/targets target=mockbin.org:80
http POST :8001/upstreams/upstream/targets target=httpbin.org:80
```

## targets

target表示一个标识后端服务，带有端口的ip地址/主机名，的实例。每个upstream都可以有多个target，并且可以动态地添加。

### 注意

因为upstream维护target更改的历史记录，所以不能直接对target进行删除或修改。若要禁用target，需要发布一个权重为0的新target;或者，使用DELETE方法来完成。
