# kong https 

使用kong去代理一个https路由主要涉及一下资源对象：

1. kong route 用于最终的请求代理
2. kong certificate 用于保存被代理的路由对应的域名的证书，比如route描述的请求是：/get，全请求为https://httpbin.com
3. snis 标注一个服务实体，其描述可以存在通配符，比如`myhttpbin.*`，当请求的域名配备该sni，kong将返回该sni绑定的服务端证书

## 准备CA和服务端证书

首先使用OpenSSL生成一个自签的证书：

1. 生成一个ca的私钥，此时要输入一个key密码，比如`123456`
```shell
openssl genrsa -des3 -out ca.key 1024
```
2. 去除key密码
```shell
openssl rsa -in ca.key -out ca.key
```
3. 根据这个ca的私钥，生成一个ca证书
```shell
openssl req -new -x509  -days 365 -key ca.key -out ca.crt
```
4. 生成一个后端服务的私钥，和ca私钥操作相同：
```shell
openssl genrsa -des3 -out server.key 1024
# 去除密码
openssl rsa -in server.key -out server.key
```

5. 生成证书的请求文件csr，此时同样会填写证书各个域的信息，，其中**证书的CN域的值，即是http请求时，header中的Host值，两者必须保持一致，这里设置为myhttpbin.com，另，也可设置含有通配符的CN，比如\*.apigw.cn**： 
```shell
openssl req -new -key server.key -out server.csr

You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
-----
Country Name (2 letter code) [AU]:
State or Province Name (full name) [Some-State]:
Locality Name (eg, city) []:
Organization Name (eg, company) [Internet Widgits Pty Ltd]:
Organizational Unit Name (eg, section) []:
Common Name (e.g. server FQDN or YOUR name) []:myhttpbin.com
Email Address []:

Please enter the following 'extra' attributes
to be sent with your certificate request
A challenge password []:
An optional company name []:

```

6. 生成server证书文件：
```shell
openssl x509 -req -days 365 -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out server.crt

Signature ok
subject=C = AU, ST = Some-State, O = Internet Widgits Pty Ltd, CN = myhttpbin.com
Getting CA Private Key

```

7. 使用ca去验证服务器证书：
```shell
openssl verify -CAfile ca.crt server.crt
server.crt: OK
```

8. 其他：
```shell
#crt转pem
openssl x509 -in mycert.crt -out mycert.pem -outform PEM
```

参考：https://www.cnblogs.com/xiguadadage/p/10756424.html

## https配置

1. 创建一个http服务的service，比如httpbin服务

2. 创建route去绑定这个service

3. 创建一个certificate对象（如果携带snis字段，同时创建snis对象），这个对象主要用于描述被代理服务的证书信息，包括了：

- 服务端证书内容（PEM格式）

- 服务端证书对应的私钥，这个主要用来验证证书的正确性：

- SNI,Server Name Indication，根据它去确定使用哪个证书，携带该字段后，将会在kong sni资源处创建对应的sni对象。

其json如下：

```json
{	
    "cert": "-----BEGIN CERTIFICATE-----...", //证书内容
    "key": "-----BEGIN RSA PRIVATE KEY-----...",//证书私钥
    "snis": ["myhttpbin.*"] //SNI
}
```

**注意，其中的snis字段必须设置，如果不设置，kong将无法找到对应的服务器证书**

具体参考 https://docs.konghq.com/2.1.x/admin-api/#certificate-object

至此，https本身的设置已经完成。假设我们创建的自签服务器证书server.pem的CN描述为`myhttpbin.com`,此时的整体验证过程为：

1. http client向kong的https代理端口发送https请求，代理端口默认使用8443，如果不提供用于验证server.crt的ca.crt证书：
```
jzd@jzd:~/kong/https_test$ curl -X GET https://localhost:8443/anything
curl: (60) SSL certificate problem: self signed certificate
More details here: https://curl.haxx.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the web page mentioned above.

```

携带ca证书：

```
jzd@jzd:~/kong/https_test$ curl -X GET -H 'Host:myhttpbin.com' --cacert ca.crt  https://myhttpbin.com:8443/anything
{
  "args": {}, 
  "data": "", 
  "files": {}, 
  "form": {}, 
  "headers": {
    "Accept": "*/*", 
    "Host": "httpbin.org", 
    "User-Agent": "curl/7.58.0", 
    "X-Amzn-Trace-Id": "Root=1-6130860b-24472a074b7909e425a56b5a", 
    "X-Forwarded-Host": "myhttpbin.com"
  }, 
  "json": null, 
  "method": "GET", 
  "origin": "192.168.182.133, 223.104.38.170", 
  "url": "http://myhttpbin.com/anything"
}

```

2. kong接收https请求后，**根据http header中的Host值，匹配到某个sni**，从而找到绑定的server证书，然后给client发送这个证书。

3. client接收到server证书后，使用ca去验证服务器证书。此时，根据https对证书的验证策略，请求头的**Host**字段值需要和证书的CN描述`myhttpbin.com`保持一致。

