see https://github.com/goharbor/harbor/blob/master/docs/configure_https.md

1.  选择一个工作目录，生成 CA的 rsa私钥ca.key：
	`openssl genrsa -out ca.key 4096`
2. 生成CA证书ca.crt：
   ` openssl req -x509 -new -nodes -sha512 -days 3650  -subj 
    "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=yourdomain.com"   -key ca.key  - 
    out ca.crt`
    其中yourdomain.com为CA主体鉴别信息
3. 生成服务器rsa私钥yourdoamin.com.key，其中yourdomain.com为服务器主体信息，我设置成了harbor，便于区别：
	`openssl genrsa -out yourdomain.com.key 4096`
4. 创建服务器的crs 证书请求信息，基于自身rsa私钥，其中CN域为服务器主体信息，后面的key文件命名为了harbor，下同：
    `openssl req -sha512 -new  -subj 
    "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=yourdomain.com"  -key 
    yourdomain.com.key  -out yourdomain.com.csr`
5. 基于crs请求信息和CA私钥，创建服务器证书yourdomain.com.crt,注意分2步，第一步在当前工作目录创建一个v3.ext文 
    件并填充以下内容，标注按X509v3版本生成证书。其中[alt_names]我指定了Harbor的ip：
	
	`cat > v3.ext <<-EOF
	authorityKeyIdentifier=keyid,issuer
	basicConstraints=CA:FALSE
	keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
	extendedKeyUsage = serverAuth
	subjectAltName = @alt_names

	[alt_names]
	IP=192.168.182.133
	EOF

	openssl x509 -req -sha512 -days 3650 -extfile v3.ext -CA ca.crt -CAkey ca.key -CAcreateserial - 
        in yourdomain.com.csr -out yourdomain.com.crt`

 	将服务器证书以Key 拷贝至服务器的/data/cert目录 cp yourdomain.com.crt /data/cert/  & cp yourdomain.com.key /data/cert/
6. 配置docker，将服务端的crt转换成**docker客户端用的cert**yourdomain.com.cert：
	`openssl x509 -inform PEM -in yourdomain.com.crt -out yourdomain.com.cert`
7. 将证书信息放在docker的配置目录下
	`cp yourdomain.com.cert /etc/docker/certs.d/yourdomain.com/
  	cp yourdomain.com.key /etc/docker/certs.d/yourdomain.com/
  	cp ca.crt /etc/docker/certs.d/yourdomain.com/`
8. 将服务器证书添加至OS的可信列表(ubuntu)
	`cp yourdomain.com.crt /usr/local/share/ca-certificates/yourdomain.com.crt
	update-ca-certificates`
9. 编辑harbor的yaml配置：
   `#set hostname
   hostname: yourdomain.com
http:
  port: 80
https:`
 ` # https port for harbor, default is 443
  port: 443`
  `# The path of cert and key files for nginx
  certificate: /data/cert/yourdomain.com.crt
  private_key: /data/cert/yourdomain.com.key`

10. 执行prepare脚本
     `./prepare`

11. 重启harbor 使用up/down方式，docker-compose down -v / docker-compose up -d
	
