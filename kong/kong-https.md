# kong https 

使用kong去代理一个https路由主要涉及一下资源对象：

1. kong route 用于最终的请求代理
2. kong certificate 用于保存被代理的路由对应的域名的证书，比如route描述的请求是：/get，全请求为https://httpbin.com
3. snis 标注一个服务实体，其描述可以存在通配符，比如`myhttpbin.*`，当请求的域名配备该sni，kong将返回该sni绑定的服务端证书

## 准备CA和服务端证书

首先使用OpenSSL生成一个自签的证书：

1. 生成一个ca的私钥，此时要输入一个key密码
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
openssl rsa -in ca.key -out ca.key
```

5. 生成证书的请求文件csr，此时同样会填写证书各个域的信息，，其中**证书的CN域的值，即是http请求时，header中的Host值，两者必须保持一致**： 
```shell
openssl req -new -key server.key -out server.csr
```
另外，在执行后提示输入一个challenge password，不需要填写
```
...
Please enter the following 'extra' attributes
to be sent with your certificate request
A challenge password []:
An optional company name []:myhttpbin

```

6. 生成server证书文件：
```shell
openssl x509 -req -days 365 -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out server.crt

```

7. 使用ca去验证服务器证书：
```shell
openssl verify -CAfile ca.crt server.crt
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

具体参考 https://docs.konghq.com/2.1.x/admin-api/#certificate-object

至此，https本身的设置已经完成。假设我们创建的自签服务器证书server.pem的CN描述为`myhttpbin.com`,此时的整体验证过程为：

1. http向kong的https代理端口发送https请求，代理端口默认使用8443

2. kong接收https请求后，**根据http header中的Host值，匹配到某个sni**，从而找到绑定的server.pem证书，然后给client发送这个证书。

3. client接收到server.pem证书后，使用ca去验证服务器证书。此时，根据https对证书的验证策略，请求头的**Host**字段值需要和证书的CN描述`myhttpbin.com`保持一致。

