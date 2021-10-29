# mep-agent
mep-agent扮演部署的应用的cide-car，为实际部署的mep服务提供了获取token接口，从而实现与mep服务的交互。另一方面，通过挂载的`app_instance_info.yaml`，将描述的app开放api注册在mep服务上（具体为注册在mep网关上）。

## cide car yaml
服务包部署时，其yaml描述如下：
```yaml
---
apiVersion: v1
kind: Pod
metadata:
  name: httpbin-pod
  namespace: jzdtest
  labels:
    app: httpbin-pod
spec:
  containers:
   -
    name: httpbin
    image: '{{.Values.imagelocation.domainname}}/{{.Values.imagelocation.project}}/httpbin:1.0'
    imagePullPolicy: IfNotPresent
    ports:
     -
      containerPort: 80
   -  # mep-agent的配置
    name: mep-agent
    image: '{{.Values.imagelocation.domainname}}/{{.Values.imagelocation.project}}/mep-agent:latest'
    imagePullPolicy: Always
    command: ["/bin/sh", "-ce", "tail -f /dev/null"]
    env:  #配置环境变量，主要涉及MEP地址和证书
     -
      name: ENABLE_WAIT
      value: '"true"'
     -
      name: MEP_IP 
      value: '"mep-api-gw.mep"'  # 配置APIGW的地址，使用k8s的svc域名
     -
      name: MEP_APIGW_PORT
      value: '"8443"'
     -
      name: CA_CERT_DOMAIN_NAME   # 设置ca证书，和kong进行https通信
      value: '"edgegallery"'
     -
      name: CA_CERT
      value: /usr/mep/ssl/ca.crt
     -
      name: AK   # 配置 AK SK
      valueFrom:
        secretKeyRef:
          name: '{{ .Values.appconfig.aksk.secretname }}'
          key: accesskey
     -
      name: SK
      valueFrom:
        secretKeyRef:
          name: '{{ .Values.appconfig.aksk.secretname }}'
          key: secretkey
     -
      name: APPINSTID  # 设置appInstanceId
      valueFrom:
        secretKeyRef:
          name: '{{ .Values.appconfig.aksk.secretname }}'
          key: appInsId
    volumeMounts:  #挂载app instance info，文件的值来自于
     -
      name: mep-agent-service-config-volume
      mountPath: /usr/mep/conf/app_instance_info.yaml
      subPath: app_instance_info.yaml
  volumes:
   -
    name: mep-agent-service-config-volume
    configMap:
      name: '{{ .Values.global.mepagent.configmapname }}'
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin-svc
  namespace: jzdtest
  labels:
    svc: httpbin-svc
spec:
  ports:
   -
    port: 8080
    targetPort: 80
    protocol: TCP
    nodePort: 32115
  selector:
    app: httpbin-svc
  type: NodePort
```

其中，主要看mep-agent的配置，主要包括**环境变量的配置**和**关联应用的开放api配置**：

1. **环境变量**

- MEP-APIGW地址相关，明文配置
- CA证书相关，使用k8s secret
- App Instance相关，使用k8s secret

首先查看secret，通过上文yaml可看到其使用了同一个secret：
```
root@cmcc-vm:/home/cmcc# kubectl get secret nqbaereunu -n jzdtest -o yaml
apiVersion: v1
data:
  accesskey: aCtwV3krUVQvbDFIYWJqbEtvWT0=
  appInsId: ODkxYzJiYmEtZjFmMi00MGJkLWE5N2UtOWJlYmJhZmNjOTY0
  secretkey: ai9QWjIrK3plSWRkZ0ZrL1ZkbjZqUTkveUZxYUpBMDQ5L3NjSDNpUHRsMjc2NmRyYVFLbWdGcDAzbU43SHNqWQ==
kind: Secret
metadata:
...
type: Opaque
# base64解密
echo aCtwV3krUVQvbDFIYWJqbEtvWT0= | base64 -d   ===>   accesskey:  h+pWy+QT/l1HabjlKoY=
echo ODkxYzJiYmEtZjFmMi00MGJkLWE5N2UtOWJlYmJhZmNjOTY0 | base64 -d ==>  appInsId: 891c2bba-f1f2-40bd-a97e-9bebbafcc964
echo ai9QWjIrK3plSWRkZ0ZrL1ZkbjZqUTkveUZxYUpBMDQ5L3NjSDNpUHRsMjc2NmRyYVFLbWdGcDAzbU43SHNqWQ== |base64 -d  secretKey: j/PZ2++zeIddgFk/Vdn6jQ9/yFqaJA049/scH3iPtl2766draQKmgFp03mN7HsjY
```
这个secret在部署chart包时被创建，详情查看applcm组件相关内容。secret中的值来源于appo组件或developer组件(取决于沙箱部署还是边缘节点部署)。

2. **开放api**

关联的应用的api将通过mep-agent注册在mepserver上作为开放能力，api通过`app_instance_info.yaml`来描述。
挂载的`app_instance_info.yaml`内容可通过kubectl进入容器查看：

```
# 进入mep-agent容器
root@cmcc-vm:/home/cmcc# kubectl exec -it httpbin-pod -c mep-agent /bin/sh -n jzdtest 
kubectl exec [POD] [COMMAND] is DEPRECATED and will be removed in a future version. Use kubectl kubectl exec [POD] -- [COMMAND] instead.
httpbin-pod:~$ cd /usr/mep/
httpbin-pod:~$ ls
bin    conf   log    views
httpbin-pod:~$ cd conf/
httpbin-pod:~/conf$ ls
app_conf.yaml           app_instance_info.yaml
httpbin-pod:~/conf$ cat app_instance_info.yaml 
# serviceInfoPosts用于描述注册的api信息
serviceInfoPosts:
# 注册服务的回调信息
serAvailabilityNotificationSubscriptions:
  - subscriptionType: SerAvailabilityNotificationSubscription
    callbackReference: string
    links:
      self:
        href: /mecSerMgmtApi/example
    filteringCriteria:
      serInstanceIds:
        - ServiceInstance123
      serNames:
        - ExampleService
      serCategories:
        - href: /example/catalogue1
          id: id12345
          name: RNI
          version: 
      states:
        - ACTIVE
      isLocal: true
```

## main启动

进入mep-agent的启动函数：
```go
func main() {
	// 从env中读取ak/sk，读取后清空
	err := util.ReadTokenFromEnvironment()
	...
    //进行tls配置，从env中读取CA_CERT_DOMAIN_NAME，即edgeGallery
    //从/mep-agent/conf/app_conf.yaml中读取密码套件
    //return &tls.Config{
	//	ServerName:         domainName,  //从env读取
	//	MinVersion:         tls.VersionTLS12,
	//	CipherSuites:       cipherSuites, //从app_conf.yaml读取
	//	InsecureSkipVerify: true,
	//}
	service.TLSConf, err = service.TLSConfig()
	...
    //从env读取MEP_IP,MEPAIGW_PORT
    //并设置服务注册、服务发现、mep auth和heartbeat的url 
	config.ServerURLConfig, err = config.GetServerURL()
	...
	// start main service
	// 读取挂载的app_instance_info.yaml
	go service.BeginService().Start("./conf/app_instance_info.yaml")
    
	log.Info("Starting server")
	beego.ErrorController(&controller.ErrorController{})
	beego.Run()
}

```

### 开放api注册
以上工作除了从环境变量读取信息，配置为service的全局变量，剩下是通过`app_instance_info.yaml`启动服务，即将开放api注册到mep：

```go
// Start service entrance
func (ser *ser) Start(confPath string) {
	var wg = &sync.WaitGroup{}
	// read app_instance_info.yaml file and transform to AppInstanceInfo object
	//从app_instance_info.yaml读取，并序列化为AppInstanceInfo
	conf, errGetConf := GetAppInstanceConf(confPath)
	...
	//从env获取app instance id
	_, errAppInst := util.GetAppInstanceID()
	...
	// signed ak and sk, then request the token
	// 封装ak sk
	var auth = model.Auth{SecretKey: util.AppConfig["SECRET_KEY"], AccessKey: string(*util.AppConfig["ACCESS_KEY"])}
	// 根据ak sk生成待验证token，写入req的header，key为Authorization
	// 向mep-auth发送token验证请求
    // POST https://${MEP_IP}:${MEP_APIGW_PORT}/mep/token
	// token计入业务全局变量util.MepToken
	errGetMepToken := GetMepToken(auth)
	...
	util.FirstToken = true

	// register service to mep with token
	// only ServiceInfo not nil
	if conf.ServiceInfoPosts != nil {
	    //携带从mep-auth得到的token
	    //调用 POST https://${MEP_IP}:${MEP_APIGW_PORT}/mep/mec_service_mgmt/v1/applications/${appInstanceId}/services
	    //向mep服务注册中心将conf，即app_instance_info.yaml配置描述的开放api，注册为mep的服务
	    //和mep的通信将使用https，ca证书即从env中读取的环境变量
		responseBody, errRegisterToMep := RegisterToMep(conf, wg)
		...
        //注册后，根据返回的heartbeat url，访问mep的网关，保证服务的可用
		for _, serviceInfo := range responseBody {
			if serviceInfo.LivenessInterval != 0 && serviceInfo.Links.Self.Liveness != "" {
				// 每个service add一次
				wg.Add(1)
				heartBeatTicker(serviceInfo)
			} else {
				log.Info("Liveness is not configured or required")
			}
		}
	}
	//如果有service需要heartbeat，将一直阻塞
	wg.Wait()
}

//heartBeat实现如下
func heartBeatTicker(serviceInfo model.ServiceInfoPost) {
	for range time.Tick(time.Duration(serviceInfo.LivenessInterval) * time.Second) {
		go HeartBeatRequestToMep(serviceInfo)
	}
}
// HeartBeatRequestToMep Send service heartbeat to MEP.
func HeartBeatRequestToMep(serviceInfo model.ServiceInfoPost) {
	heartBeatRequest := serviceLivenessUpdate{State: "ACTIVE"}
	data, errJSONMarshal := json.Marshal(heartBeatRequest)
	...
	//url = https://{MEP_IP}:{MEP_APIGW_PORT}/{serviceInfo.Links.Self.Liveness}
	url := config.ServerURLConfig.MepHeartBeatURL + serviceInfo.Links.Self.Liveness
	var heartBeatInfo = heartBeatData{data: string(data), url: url, token: &util.MepToken}
	_, errPostRequest := sendHeartBeatRequest(heartBeatInfo)
	...
}
```

## 接口定义

mep-agent的route定义位于/router/router.go,对其他服务提供api接口供调用
```go
func init() {
    // 从全局变量中获取token，直接返回
	beego.Router("/mep-agent/v1/token", &controllers.TokenController{})
	// 调用mep GET https://${MEP_IP}:${MEP_APIGW_PORT}/mep/mec_service_mgmt/v1/services?ser_name=
	// 从mep注册中心获取服务信息
	beego.Router("/mep-agent/v1/endpoint/:serName", &controllers.EndpointController{})
}
```

## 总结
mep-agent在启动时：
1. 根据从应用中获取的ak/sk，向mep-auth获取token
2. 提供了rest api，提供token的查询和服务发现接口
3. 将app的api信息注册到mep上

