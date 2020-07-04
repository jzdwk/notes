# KongPlugin

kongPlugin主要为kong提供了除了反向代理外的额外功能。对常用的plugin以及使用做个记录。

## auth-key

auth-key主要提供apikey的功能，这个plugin可以应用在k8s ingress/service中，大致的思路是：
1. 为要进行认证的资源对象(ingress/service)创建一个key-auth插件对象：

```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: httpbin-auth
plugin: key-auth
```

2. 将插件对象通过annotation应用于k8s资源对象中，这时，反向代理将返回401码。
3. 创建一个k8s secret对象，这个secret中保存了apikey，如下例的`my-scooper-secret`:

```
kubectl create secret generic harry-apikey  \
  --from-literal=kongCredType=key-auth  \
  --from-literal=key=my-sooper-secret-key
```

4. 创建一个KongConsumer，并引用刚才的secret：

```
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: harry
username: harry
credentials:
- harry-apikey
```

6. 用户使用这个secret的key，便能访问服务：
```curl -i -H 'apikey: my-sooper-secret-key' $PROXY_IP/foo/status/200```

因此可以看到，kong auth-key的认证大致为：
client--api-key---> ingress/service--根据plugin-->查找consumer-->比对key

## jwt

jwt插件提供了token认证的功能，大致的流程和上面的auth-key差不多，具体来看：
1. 创建jwt插件：
```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: app-jwt
plugin: jwt
```
2. 应用于要认证的kong对象：

```
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: demo-post
  annotations:
    plugins.konghq.com: app-jwt
    konghq.com/strip-path: "false"
spec:
  rules:
  - http:
      paths:
      - path: /post
        backend:
          serviceName: httpbin
          servicePort: 80
```

3. 创建secret,需要注意的是，这个secret的属性中加入了生成token所需的算法信息：
```
kubectl create secret \
  generic app-user-jwt  \
  --from-literal=kongCredType=jwt  \
  --from-literal=key="user-issuer" \
  --from-literal=algorithm=RS256 \
  --from-literal=rsa_public_key="-----BEGIN PUBLIC KEY-----
  qwerlkjqer....
  -----END PUBLIC KEY-----"
```
4. 创建consumer，并引用这个secret：
```
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: plain-user
username: plain-user
credentials:
  - app-user-jwt
```
5. 使用生成的token便能访问：
```
curl -i -H "Authorization: Bearer ${USER_JWT}" $PROXY_IP/get```

## ACL

apikey,jwt都提供了一种认证的方式，但是没有提供授权，授权的插件则可以使用acl。acl授权打大致流程为：首先创建一个acl的资源授权规则，然后为不同kongConsumer创建不同的secret，其中secret中定义了具体的权限，并将secret添加到kongConsumer的Credential中。最终，将acl插件加入k8s ingrss/service对象。当携带token的请求到来后，根据token找到对应的kongConsumer，然后根据kongConsumer中的secret的权限定义，与acl中的权限规则进行比对，得出访问结论。下面是一个例子。

1. 首先创建一个acl对象，这个对象用于对某个admin级的资源做授权操作。其中的whitelist就是被授权的资源集，可以看到只有app-admin

```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: admin-acl
plugin: acl
config:
  whitelist: ['app-admin']
```

2. 接下来创建一个普通用的secret,secret中的kongCredType定义为acl，group定义了这个secret的权限属性app-usr：

```
kubectl create secret \
  generic app-user-acl \
  --from-literal=kongCredType=acl  \
  --from-literal=group=app-user
```

3. 将secret加入kongConsumer的引用，此时kongConsumer中将由两个credentials，一个jwt用来认证，acl用来授权:

```
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: plain-user
username: plain-user
credentials:
  - app-user-jwt
  - app-user-acl
```

4. 最终，将最初定义的acl插件添加到要增加授权功能的ingress：

```
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: demo-post
  annotations:
    plugins.konghq.com: app-jwt,admin-acl
    konghq.com/strip-path: "false"
spec:
  rules:
  - http:
      paths:
      - path: /post
        backend:
          serviceName: httpbin
          servicePort: 80
```

5. 使用访问，可以发现访问失效,原因在于当使用user的token访问后，kong将根据user找到对应的kongConsumer plain-user，plain-user引用的secret app-user-acl中定义的权限主体是app-user，而ingress中添加的acl中定义的授权资源为只有app-admin，故而授权失败。

```
curl -i -H "Authorization: Bearer ${USER_JWT}" $PROXY_IP/get
{"message":"You cannot consume this service"}
```


