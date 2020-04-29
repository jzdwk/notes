# kong in k8s

kong在k8s里的部署主要依靠一下两项项关键点：

- kong ingress controller
- kong CRD资源

## kong ingress controller

[kong ingress controller](https://github.com/Kong/kubernetes-ingress-controller) 和 [nginx ingress controller](https://github.com/kubernetes/ingress-nginx) 相似，提供了传统的ingress controller的功能，即根据ingress的策略，转发给不同的svc。

- nginx ingress controller套路:client req--DNS-->ingress controller所在node(edge node/svc_LB/svc_NodePort...)--(根据ingress配置，直接转发)-->svc
- kong ingress controller套路:client--->kong ingress controller所在node(edge node/LB/)--(根据ingress配置，以及plugin，提供代理or额外的增强功能，如限流，api key)-->svc

kong ingress controller 由2部分组成:

- kong 流量转发的核心组件,类比于nginx
- controller 监听k8s api,根据ingress配置or Plugin配置，更新kong状态

整体的流程就是，controller监k8s api server，当出现更新，则通知kong，kong对更新自身状态，包括增加路由/激活plugin等。

在这里补充一下nginx ingress controller 的流程，nginx ingress controller是k8s官方推荐的ingress controller的一种，用以支持k8s ingress 策略。它由两部分组成：

- nginx: nginx 服务，反向代理，负责转发request
- handler/controller: 监听k8s api ,当下发ingress配置策略，更新nginx的配置文件(/location模块、/upstream模块)，并reload nginx.conf

nginx ingress controller的部署方式有:

- daemonset + hostNetwork ingress 容器多，流量直打controller的node,请求源ip不变，dns使用node所在物理机的resolv.conf
- deployment + svc_NodePort: ingress controller容器少，流量经svc的node转发至controller的node，请求ip变为svc的node ip, 可以使用内部的coredns

当然，同样应用于kong ingress controller的部署策略（使用helm方式则直接默认进行了设置）。

##  CustomResourceDefinition

[CRD](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions/)用于自定义k8s的资源对象。在kong中，定义了以下CRD资源:
- KongIngress
- KongPlugin
- KongConsumer
- KongCredential
- KongClusterPlugin
- TCPIngress

## kong and k8s

在详细说明CRD资源对象之前，需要将Kong与K8S中的资源做一个映射关系:

- k8s ingress ==> kong route
- k8s service ==> kong service/upstream
- k8s pod ==> kong target

### KongIngress

k8s的ingress只是提供了一个host/path路由的功能。作为ingress的补充，kongIngress在原有k8s中ingress的基础上，通过更改kong upstream/service/route的属性，提供了对其k8s ingress/service描述规则进行更改的功能，比如配置path的匹配规则。其**作用对象为k8s的service和ingress**.

在使用时，通过在k8s的ingress/service中加入kongIngress的annotations进行扩展。具体用法为：
```configuration.konghq.com: kong-ingress-resource-name```
比如，在ingress资源上增加一个名叫sample-custom-resource的kongIngress:
```kubectl patch ingress demo -p '{"metadata":{"annotations":{"configuration.konghq.com":"sample-customization"}}}'```

另外需要注意，根据上文提到的k8s对象与kong的对应关系：

- 当涉及到health-checking, load-balancing等和service相关的配置，将annotation加入k8s的service对象。
- 当涉及到路由，协议配置时，将annotation加入k8s的ingress对象。

完整的kongIngress 模板如下：

```
apiVersion: configuration.konghq.com/v1
kind: KongIngress
metadata:
  name: configuration-demo
upstream:
  slots: 10
  hash_on: none
  hash_fallback: none
  healthchecks:
    threshold: 25
    active:
      concurrency: 10
      healthy:
        http_statuses:
        - 200
        - 302
        interval: 0
        successes: 0
      http_path: "/"
      timeout: 1
      unhealthy:
        http_failures: 0
        http_statuses:
        - 429
        interval: 0
        tcp_failures: 0
        timeouts: 0
    passive:
      healthy:
        http_statuses:
        - 200
        successes: 0
      unhealthy:
        http_failures: 0
        http_statuses:
        - 429
        - 503
        tcp_failures: 0
        timeouts: 0
proxy:
  protocol: http
  path: /
  connect_timeout: 10000
  retries: 10
  read_timeout: 10000
  write_timeout: 10000
route:
  methods:
  - POST
  - GET
  regex_priority: 0
  strip_path: false
  preserve_host: true
  protocols:
  - http
  - https
```

### KongPlugin

kong插件资源，kong本身提供了一些plugins，详见kong concept。这些插件可以**应用于k8s的资源ingress/service以及kongConsumer（CRD）**，用来在不同的层（4/7）进行限流等功能。在使用时，同样将在k8s的annotations中加入plugin。完整的kongPlugin定义如下：

```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: <object name>
  namespace: <object namespace>
  labels:
    global: "true"   # optional, if set, then the plugin will be executed
                     # for every request that Kong proxies
                     # please note the quotes around true
disabled: <boolean>  # optionally disable the plugin in Kong
config:              # configuration for the plugin
    key: value
plugin: <name-of-plugin> # like key-auth, rate-limiting etc
```

其中config项下，用于配置plugin的key-value段。通过```plugins.konghq.com```段，可将其作用在k8s的service、ingress对象上，例如，创建一个response-transformer的plugin:
```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: add-response-header
config:
  add:
    headers:
    - "demo: injected-by-kong"
plugin: response-transformer
```
并将其应用到ingress上：```kubectl patch ingress demo -p '{"metadata":{"annotations":{"konghq.com/plugins":"add-response-header"}}}'```

### KongClusterPlugin

和kongPlugin类似，只是cluster级的资源对象（kongPlugin是namespace）。当插件的安装和部署需要进行集中化处理时，选用cluster级。比如下例：

```
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: request-id
config:
  header_name: my-request-id
plugin: correlation-id
```

### KongConsumer

用于配置kong consumer，每一个kongConsumer资源对象对应一个kong中的consumer实体。其模板如下：

```
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: <object name>
  namespace: <object namespace>
username: <user name>
custom_id: <custom ID>
```


### TCPIngress

k8s的ingress只用于暴露http服务，使用tcpIngress则可以进行基于tcp和tls sni的路由，tcpIngress的模板如下：

```
apiVersion: configuration.konghq.com/v1beta1
kind: TCPIngress
metadata:
  name: <object name>
  namespace: <object namespace>
spec:
  rules:
  - host: <SNI, optional>
    port: <port on which to expose this service, required>
    backend:
      serviceName: <name of the kubernetes service, required>
      servicePort: <port number to forward on the service, required>
```

如果没有指定host，则直接对流量进行转发，如果指定了host，则根据host的配置，将流量进行ssl加密处理。

### KongCredential(Deprecated)

kongCredential和kongConsumer是配合使用的，它可以向consumer上添加key来进行认证，两者通过consumerRef建立关联，其模板如下：

```
apiVersion: configuration.konghq.com/v1
kind: KongCredential
metadata:
  name: credential-team-x
consumerRef: consumer-team-x
type: key-auth
config:
  key: 62eb165c070a41d5c1b58d9d3d725ca1
```

其中，type的种类包括了：

- key-auth for Key authentication
- basic-auth for Basic authenticaiton
- hmac-auth for HMAC authentication
- jwt for JWT based authentication
- oauth2 for Oauth2 Client credentials
- acl for ACL group associations

## conjecture

这时，我们就可以猜到，kong ingress controller 通过在k8s api server list-watch这些CDR资源，以及ingress资源。当有ingress策略与CDR下发时，通过调用kong admin api去更新kong配置。从而实现proxy和api gateway的功能。随后，尝试进行kong ingress controller的源码解析。




