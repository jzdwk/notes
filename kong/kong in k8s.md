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
整体的流程就是，controller监k8s api server，当出现更新，则通知kong，kong对更新自身状态，包括增加路由/激活plugin等。在这里补充一下nginx ingress controller 的流程，nginx ingress controller是k8s官方推荐的ingress controller的一种，用以支持k8s ingress 策略。它由两部分组成：
- nginx: nginx 服务，反向代理，负责转发request
- handler/controller: 监听k8s api ,当下发ingress配置策略，更新nginx的配置文件(/location模块、/upstream模块)，并reload nginx.conf
nginx ingress controller的部署方式有:
- daemonset + hostNetwork ingress 容器多，流量直打controller的node,请求源ip不变，dns使用node所在物理机的resolv.conf
- deployment + svc_NodePort: ingress controller容器少，流量经svc的node转发至controller的node，请求ip变为svc的node ip, 可以使用内部的coredns
当然，同样应用于kong ingress controller的部署策略。

##  CustomResourceDefinition

[CRD](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions/)用于自定义k8s的资源对象。在kong中，定义了以下CRD资源:

1. *KongIngress*: k8s的ingress只是提供了一个host/path路由的功能，因此，作为ingress的补充，kongIngress在原有k8s中ingress的基础上提供了对在kong中定义的upstream、service、router实体进行维护的功能。在使用时，通过在ingress中加入kongIngress的annotations进行扩展。

2. *KongPlugin*:  kong插件资源，kong本身提供了一些plugins，详见上文。这些插件可以应用于k8s的资源ingress/service以及kongConsumer，用来在不同的层（4/7）进行限流等功能。在使用时，同样将在k8s的annotations中加入plugin。

3. *KongClusterPlugin*: 和kongPlugin类似，只是cluster级的资源对象（kongPlugin是namespace）。当插件的安装和部署需要进行集中化处理时，选用cluster级。

4. *KongConsumer*：用于配置kong consumer，每一个kongConsumer资源对象对应一个kong中的consumer实体。

5. *TCPIngress*: 向外部暴露非http/grpc的k8s中的服务，

6. *KongCredential* (Deprecated): 废弃

## conjecture

这时，我们就可以猜到，kong ingress controller 通过在k8s api server list-watch这些CDR资源，以及ingress资源。当有ingress策略与CDR下发时，通过调用kong admin api去更新kong配置。从而实现proxy和api gateway的功能。随后，尝试进行kong ingress controller的源码解析。




