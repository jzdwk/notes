# mep auth
MEP-auth为APP提供认证鉴权功能，提供token申请接口，APP可以基于AK/SK签名算法，向MEP-auth提供正确的签名，获得token，然后通过该token访问MEP-server相关接口。
http://docs.edgegallery.org/zh_CN/release-v1.2/Projects/MEP/MEP_Features.html

## yaml定义


## main

```go
func main() {
    //数据库初始化
	adapter.InitDb()
	//加载mepauth的认证相关配置，从上节yaml中可看到具体secret挂载路径
	configFilePath := filepath.FromSlash("/usr/mep/mprop/mepauth.properties")
```
进入mep pod的mepauth容器查看配置文件内容：
```shell
kubectl exec -it mep-7c65f9fbd7-ppbz8 -c mepauth -n mep /bin/sh

mep-7c65f9fbd7-ppbz8:~/mprop$ cat mepauth.properties 

JWT_PRIVATE_KEY=te9Fmv%qaq
ACCESS_KEY=QVUJMSUMgS0VZLS0tLS0
SECRET_KEY=DXPb4sqElKhcHe07Kw5uorayETwId1JOjjOIRomRs5wyszoCR5R7AtVa28KT3lSc
APP_INST_ID=5abe4782-2c70-4e47-9a4e-0ee3a1a0fd1f
KEY_COMPONENT=oikYVgrRbDZHZSaobOTo8ugCKsUSdVeMsg2d9b7Qr250q2HNBiET4WmecJ0MFavRA0cBzOWu8sObLha17auHoy6ULbAOgP50bDZapxOylTbr1kq8Z4m8uMztciGtq4e11GA0aEh0oLCR3kxFtV4EgOm4eZb7vmEQeMtBy4jaXl6miMJugoRqcfLo9ojDYk73lbCaP9ydUkO56fw8dUUYjeMvrzmIZPLdVjPm62R4AQFQ4CEs7vp6xafx9dRwPoym
TRUSTED_LIST=

mep-7c65f9fbd7-ppbz8:~/mprop$ pwd
/usr/mep/mprop
mep-7c65f9fbd7-ppbz8:~/mprop$
```
继续返回main函数
```go
	appConfig, err := readPropertiesFile(configFilePath)
    //...
	// Clearing all the sensitive information on exit for error case. For the success case
	// function handling the sensitive information will clear after the usage.
	// clean of mepauth.properties file use kubectl apply -f empty-mepauth-prop.yaml
	defer clearAppConfigOnExit(appConfig)
	//...Validate check
	keyComponentUserStr := appConfig["KEY_COMPONENT"]
	err = util.ValidateKeyComponentUserInput(keyComponentUserStr)
	...
	util.KeyComponentFromUserStr = keyComponentUserStr
    //执行kong的初始化工作
	if !doInitialization(appConfig["TRUSTED_LIST"]) {
		return
	}
    //jwt 私钥加密后写入容器文件中
	err = util.EncryptAndSaveJwtPwd(appConfig["JWT_PRIVATE_KEY"])
	...
	reqSer, ok := appConfig["REQUIRED_SERVICES"]
	...
	 //sk sk和app id写入db
	err = controllers.ConfigureAkAndSk(string(*appConfig["APP_INST_ID"]),
		string(*appConfig["ACCESS_KEY"]), appConfig["SECRET_KEY"], "initApp", string(*reqSer))
	...
	//beego开启服务端证书配置
	tlsConf, err := util.TLSConfig("HTTPSCertFile")
	...
	controllers.InitAuthInfoList()
	beego.BeeApp.Server.TLSConfig = tlsConf
	setSwaggerConfig()
	beego.ErrorController(&controllers.ErrorController{})
	beego.Run()
}
```
### init kong 网关
深入看main函数中的`doInitialization(appConfig["TRUSTED_LIST"])`实现：
```go
func doInitialization(trustedNetworks *[]byte) bool {
    //从/ssl/ca.crt读取kong网关的ca证书
	config, err := util.TLSConfig("apigw_cacert")
    ...
	initializer := &apiGwInitializer{tlsConfig: config}
    //初始化kong网关
	err = initializer.InitAPIGateway(trustedNetworks)
	...
	err = util.InitRootKeyAndWorkKey()
	...
	return true
}
```
继续看`initializer.InitAPIGateway(trustedNetworks)`的内部，其主要工作为向kong网关上注册mepserver和mepauth自身：
```go
func (i *apiGwInitializer) InitAPIGateway(trustedNetworks *[]byte) error {
	//获取kong地址
	//https://{kong_ip}:{kong_port}
	apiGwUrl, getApiGwUrlErr := util.GetAPIGwURL()
	...
	//1.创建mepauth对应的consumer 
	//POST {kong_url}/consumer  其中name = mepauth.jwt
	//2. 创建consumer的jwt public key
	//POST {kong_url}/consumer/mepauth.jwt/jwt  
	err := i.SetApiGwConsumer(apiGwUrl)
    ...
    // 将mepserver注册在kong
    // 1. 注册kong service
    // PUT https://{kong_addr}/services/mepserver
    // 其中service url为mepserver，https://mepServerHost:mepServerPort
    // 2. 注册kong route
    // POST https://{kong_addr}/mepserver/routes
    // 其中path为： /mep/mec_service_mgmt 以及 /mep/mec_app_support
    // 3. 向service注册
    // jwt/appid-header/pre-function/rate-limiting/response-transformer plugins
    // POST https://{kong_addr}/mepserver/plugins
	err = i.SetupApiGwMepServer(apiGwUrl)
	...
	// 将mep auth注册在kong
    // 1. 注册kong service
    // PUT https://{kong_addr}/services/mepauth
    // 其中service url为mepserver，https://mepAuthHost:mepAuthPort
    // 2. 注册kong route
    // POST https://{kong_addr}/mepauth/routes
    // 其中path为： /mep/token 以及 /mep/appMng/v1
    // 3. 向service注册
    // rate-limiting/response-transformer plugins
    // POST https://{kong_addr}/mepserver/plugins
	err = i.SetupApiGwMepAuth(apiGwUrl, trustedNetworks)
    ...
    // 向kong上注册全局的httplog插件
    // 其中回调地址为 https://mep-mm5:80/mep/service_govern/v1/kong_log
	err = i.SetupHttpLogPlugin(apiGwUrl)
	...
	return nil
}
```
## route 定义

mep auth本身提供的功能比较简单，主要为两大类接口，app认证配置和token生成
```go
// Init mepauth APIs
func init() {
	beego.Get("/health", func(ctx *context.Context) {
		ctx.Output.Context.ResponseWriter.ResponseWriter.Write([]byte("ok"))
	})
	//定义mepauth的api
	ns := beego.NewNamespace("/mep/",
		beego.NSInclude(
		    // 向mep auth记录app的认证相关信息，包括app的id/ak/sk，提供crud操作
			&controllers.ConfController{},
			// mepauth的jwt token处理
			// 提供了一个post接口，从header中取出token信息，解析出ak从mepauth获取sk// 记录，sk签名后同提供的token中签名进行比对
			// 验证通过token信息后返回
			&controllers.TokenController{},
		),
	)
	beego.AddNamespace(ns)
}
```




## 附

### mep auth yaml
mep auth组件的yaml定义如下, 具体命令为`kubectl get deploy mep -o yaml -n mep`,其中只列出和mepauth相关的容器配置：
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  annotations:
    deployment.kubernetes.io/revision: "1"
    meta.helm.sh/release-name: mep-edgegallery
    meta.helm.sh/release-namespace: default
  creationTimestamp: "2021-07-30T14:54:40Z"
  generation: 1
  labels:
    app: mep
    app.kubernetes.io/managed-by: Helm
  managedFields:
  - apiVersion: apps/v1
    fieldsType: FieldsV1
    fieldsV1:
    ...//省略
  name: mep
  namespace: mep
spec:
  progressDeadlineSeconds: 600
  replicas: 1
  revisionHistoryLimit: 10
  selector:
    matchLabels:
      app: mep
  strategy:
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
    type: RollingUpdate
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: mep/mm5, mep/mp1
      creationTimestamp: null
      labels:
        app: mep
    spec:
      containers:
      # kong网关
      - env:
        - name: KONG_NGINX_WORKER_PROCESSES
          value: "1"
        - name: KONG_ADMIN_LISTEN
          value: 0.0.0.0:8001, 0.0.0.0:8444 ssl
        - name: KONG_PROXY_LISTEN
          value: 0.0.0.0:8000, 0.0.0.0:8443 ssl http2
        - name: KONG_DATABASE
          value: postgres
        - name: KONG_PG_DATABASE
          value: kong
        - name: KONG_PG_HOST
          value: pg-service
        - name: KONG_PG_USER
          value: kong
        - name: KONG_PG_PASSWORD
          valueFrom:
            secretKeyRef:
              key: kong_pg_pwd
              name: pg-secret
        - name: KONG_PROXY_ACCESS_LOG
          value: /tmp/access.log
        - name: KONG_ADMIN_ACCESS_LOG
          value: /tmp/admin-access.log
        - name: KONG_PROXY_ERROR_LOG
          value: /tmp/proxy.log
        - name: KONG_ADMIN_ERROR_LOG
          value: /tmp/proxy-admin.log
        - name: KONG_HEADERS
          value: "off"
        image: eg-common/kong:2.0.4-ubuntu
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 3
          initialDelaySeconds: 30
          periodSeconds: 10
          successThreshold: 1
          tcpSocket:
            port: 8000
          timeoutSeconds: 5
        name: kong-proxy
        ports:
        - containerPort: 8000
          name: proxy
          protocol: TCP
        - containerPort: 8443
          name: proxy-ssl
          protocol: TCP
        - containerPort: 8001
          name: admin-api
          protocol: TCP
        - containerPort: 8444
          name: admin-api-ssl
          protocol: TCP
        readinessProbe:
          failureThreshold: 3
          initialDelaySeconds: 15
          periodSeconds: 10
          successThreshold: 1
          tcpSocket:
            port: 8000
          timeoutSeconds: 5
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /etc/kong/
          name: kong-conf
        - mountPath: /var/lib/kong/data/
          name: kong-certs
        - mountPath: /usr/local/share/lua/5.1/kong/plugins/appid-header/
          name: kong-plugins
      # mepauth组件
      - env:
        - name: MEPAUTH_APIGW_HOST
          value: localhost
        - name: MEPAUTH_APIGW_PORT
          value: "8444"
        - name: MEPAUTH_CERT_DOMAIN_NAME
          value: edgegallery
        - name: MEPAUTH_DB_NAME
          value: kong
        - name: MEPAUTH_DB_HOST
          value: pg-service
        - name: MEPAUTH_DB_USER
          value: kong
        - name: MEPAUTH_DB_PASSWD
          valueFrom:
            secretKeyRef:
              key: kong_pg_pwd
              name: pg-secret
        image: edgegallery/mepauth:v1.2.0
        imagePullPolicy: IfNotPresent
        livenessProbe:
          failureThreshold: 30
          httpGet:
            path: /health
            port: 10443
            scheme: HTTPS
          initialDelaySeconds: 30
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 5
        name: mepauth
        ports:
        - containerPort: 10443
          protocol: TCP
        readinessProbe:
          failureThreshold: 30
          httpGet:
            path: /health
            port: 10443
            scheme: HTTPS
          initialDelaySeconds: 15
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 5
        resources: {}
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /usr/mep/ssl/
          name: mepauth-certs
          readOnly: true
        - mountPath: /usr/mep/keys/
          name: mepauth-jwt
          readOnly: true
        - mountPath: /usr/mep/mprop/
          name: mepauth-properties
      # ... mep配置，省略
      dnsPolicy: ClusterFirst
      # ...init containers, kong的db初始化，省略
      initContainers:
      # ...
      volumes:
      - name: kong-conf
        secret:
          defaultMode: 420
          items:
          - key: kong.conf
            mode: 420
            path: kong.conf
          secretName: kong-secret
      - name: kong-certs
        secret:
          defaultMode: 420
          items:
          - key: server.crt
            mode: 420
            path: kong.crt
          - key: server.key
            mode: 420
            path: kong.key
          - key: ca.crt
            mode: 420
            path: ca.crt
          secretName: mepauth-secret
      - name: kong-plugins
        secret:
          defaultMode: 420
          items:
          - key: handler.lua
            mode: 420
            path: handler.lua
          - key: schema.lua
            mode: 420
            path: schema.lua
          secretName: kong-secret
      - name: mep-certs
        secret:
          defaultMode: 420
          items:
          - key: server.cer
            mode: 420
            path: server.cer
          - key: server_key.pem
            mode: 420
            path: server_key.pem
          - key: trust.cer
            mode: 420
            path: trust.cer
          secretName: mep-ssl
      - name: mepauth-certs
        secret:
          defaultMode: 420
          items:
          - key: server.crt
            mode: 420
            path: server.crt
          - key: server.key
            mode: 420
            path: server.key
          - key: ca.crt
            mode: 420
            path: ca.crt
          secretName: mepauth-secret
      - name: mepauth-jwt
        secret:
          defaultMode: 420
          items:
          - key: jwt_publickey
            mode: 420
            path: jwt_publickey
          - key: jwt_encrypted_privatekey
            mode: 420
            path: jwt_encrypted_privatekey
          secretName: mepauth-secret
      - name: mepauth-properties
        secret:
          defaultMode: 420
          items:
          - key: mepauth.properties
            mode: 420
            path: mepauth.properties
          secretName: mepauth-prop
      - name: mep-cfg
        secret:
          defaultMode: 420
          items:
          - key: config.yaml
            mode: 420
            path: config.yaml
          secretName: mep-config
      - name: dns-datastore
        persistentVolumeClaim:
          claimName: dns-datastore-pvc
      - name: mep-datastore
        persistentVolumeClaim:
          claimName: mep-datastore-pvc
```
### mep app conf
mep app.conf的定义如下：
```shell
kubectl exec -it mep-7c65f9fbd7-ppbz8 -c mepauth -n mep /bin/sh
mep-7c65f9fbd7-ppbz8:~$ cd conf/
mep-7c65f9fbd7-ppbz8:~/conf$ ls
app.conf
mep-7c65f9fbd7-ppbz8:~/conf$ cat app.conf 
# Copyright 2020 Huawei Technologies Co., Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

appname = mepauth
httpport = 8080
runmode = prod
copyrequestbody = true
mepauth_key = mepauth

# apigw support
apigw_host = localhost
apigw_port = 8444
apigw_cacert = "ssl/ca.crt"
server_name = edgegallery

# https support
EnableHTTP = false
EnableHTTPS = true
ServerTimeOut = 10

mepserver_host = 10.244.84.12
mepserver_port = "8088"


HTTPSAddr = 10.244.84.12
HttpsPort = 10443
HTTPSCertFile = "ssl/server.crt"
HTTPSKeyFile = "ssl/server.key"

# jwt support
jwt_public_key = "keys/jwt_publickey"
jwt_encrypted_private_key = "keys/jwt_encrypted_privatekey"
#TLS configuration
ssl_ciphers = TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256

#db config
db_name = kong
db_user = kong
db_passwd = cmcc12#$
db_host = pg-service
db_port = 5432
db_sslmode = disable
dbAdapter = pgDbmep-7c65f9fbd7-ppbz8:~/conf$ 
```
