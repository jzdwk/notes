# kong ingress controller

## design

[kong ingress controller](https://github.com/Kong/kubernetes-ingress-controller) 和 [nginx ingress controller](https://github.com/kubernetes/ingress-nginx) 相似，提供了传统的ingress controller的功能，即根据ingress的策略，转发给不同的svc。

* 传统ingress controller套路:client--->ingress controller(edge node/svc_LB/svc_NodePort...)--(根据ingress配置，直接转发)-->svc

* kong ingress controller:client--->kong ingress controller(edge node/LB/)--(根据ingress配置，以及plugin，提供代理or额外的增强功能，如限流，api key)-->svc

kong ingress controller 由2部分组成

* kong 流量转发的核心组件,类比于nginx
* controller 监听k8s api,根据ingress配置or Plugin配置，更新kong状态
整体的流程就是，controller监k8s api server，当出现更新，则通知kong，kong对更新自身状态，包括增加路由/激活plugin等.

在这里补充一下nginx ingress controller 的流程，nginx ingress controller是k8s官方推荐的ingress controller的一种，用以支持k8s ingress 策略。它由两部分组成：

* nginx: nginx 服务，负责转发
* handler/controller: 监听k8s api ,当下发ingress配置策略，更新nginx的配置文件(/location模块、/upstream模块)，并reload nginx.conf

nginx ingress controller的部署方式有:
* daemonset + hostNetwork ingress 容器多，流量直打controller的node,请求源ip不变，dns使用node所在物理机的resolv.conf
* deployment + svc_NodePort: ingress controller容器少，流量经svc的node转发至controller的node，请求ip变为svc的node ip, 可以使用内部的coredns

## plugin

待完成

# kong

OK,刚才我们知道了kong ingress controller的主要作用，就是监听k8s api server的ingress配置（host+具体项目的svc），修改kong的配置。
接下来，记录下kong的主要组件以及交互：

## service

一个 service 代表一个微服务实体，可以简单理解为一个网站的根地址（www.test.com） 通过[kong admin api](https://docs.konghq.com/2.0.x/admin-api/)进行添加。
例如：http POST :8001/services name=example_service url='http://mockbin.org'

## router

一个 router 表示当请求到达kong后如何转发给service，一个service可以对应多个router。
例如： http :8001/services/example_service/routes paths:='["/mock"]' name=mocking
request-->routers[]-->service
注意这个router是kong里的概念，位于service之前。这时，当访问kong proxy + /mock的时候，将直接转发至http://mockbin.org。

## plugin

kong除了可以作为反向代理，也可以通过插件来增加功能，比如加入访问频次限制、缓存、auth-key。

第一个例，添加一个流量限速的plugins操作：
http -f post :8001/plugins name=rate-limiting config.minute=5 config.policy=local
例子中通过api添加了一个限速的plugin，此时，当继续访问上文中的/mock，高于频次限制将返回提示信息。(思考一下怎么做单个service/router的限制)

第二个例子，添加一个内存的cache：
http -f :8001/plugins name=proxy-cache config.strategy=memory config.content_type="application/json"
此时，访问/mock时，将被缓存。

第三个例子，添加一个apikey用来验证api消费者的身份，注意这个plugins添加给了name为mock的route： 
http :8001/routes/mock/plugins name=key-auth
这时访问/mock，将返回401码，提示未通过认证。因此，我们需要创建一个apikey，首先，调用admin api的consumer接口创建一个consumer：
http :8001/consumers username=consumer1 custom_id=consumer1
然后，将创建的key添加到这个consumer：
http :8001/consumers/consumer1/key-auth key=apikey1
最后，再访问/mock时，带上这个apikey：
http :8000/mock/request apikey:apikey

## upstream

kong实现负载均衡的模块是upstream，upstream指的是service对象后的虚拟对象，主要用于和真正的host连接，并提供LB、熔断等。
request-->router-->service-->具体upstream(虚概念)-->targer(host)
首先，创建一个upstream，名为upstream1:
http POST :8001/upstreams name=upstream
将之前创建的example_service的host属性，指定为这个upstream，而不是之前的那个http地址，注意使用了PATCH方法：
http PATCH :8001/services/example_service host='upstream'
最后，将不同的实际targert地址添加至upstream的targets
http POST :8001/upstreams/upstream/targets target=mockbin.org:80
http POST :8001/upstreams/upstream/targets target=httpbin.org:80

## security

security并不是kong的组件，是kong通过RBAC所支持的安全策略，详细信息[待完善](https://docs.konghq.com/getting-started-guide/latest/manage-teams/)

## 
