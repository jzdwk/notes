# KongPlugin

kongPlugin主要为kong提供了除了反向代理外的额外功能。对常用的plugin以及使用做个记录。

## auth-key

auth-key主要提供apikey的功能，这个plugin可以应用在k8s ingress/service中，大致的思路是：
1. 为要进行认证的资源对象(ingress/service)创建一个auth-key插件对象：

```
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata:
  name: httpbin-auth
plugin: key-auth
```

2. 将插件对象通过annotation应用于k8s资源对象中，这是，反向代理将返回401码。
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
5. 用户使用这个secret的key，便能访问服务：
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
2. 应用于要认证的对象：
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

auth-key,jwt都提供了一种认证的方式，而授权的插件则可以使用acl。



