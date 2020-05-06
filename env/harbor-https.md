see https://github.com/goharbor/harbor/blob/master/docs/configure_https.md

1.  ѡ��һ������Ŀ¼������ CA�� rsa˽Կca.key��
	`openssl genrsa -out ca.key 4096`
2. ����CA֤��ca.crt��
   ` openssl req -x509 -new -nodes -sha512 -days 3650  -subj 
    "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=yourdomain.com"   -key ca.key  - 
    out ca.crt`
    ����yourdomain.comΪCA���������Ϣ
3. ���ɷ�����rsa˽Կyourdoamin.com.key������yourdomain.comΪ������������Ϣ�������ó���harbor����������
	`openssl genrsa -out yourdomain.com.key 4096`
4. ������������crs ֤��������Ϣ����������rsa˽Կ������CN��Ϊ������������Ϣ�������key�ļ�����Ϊ��harbor����ͬ��
    `openssl req -sha512 -new  -subj 
    "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=yourdomain.com"  -key 
    yourdomain.com.key  -out yourdomain.com.csr`
5. ����crs������Ϣ��CA˽Կ������������֤��yourdomain.com.crt,ע���2������һ���ڵ�ǰ����Ŀ¼����һ��v3.ext�� 
    ��������������ݣ���ע��X509v3�汾����֤�顣����[alt_names]��ָ����Harbor��ip��
	
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

 	��������֤����Key ��������������/data/certĿ¼ cp yourdomain.com.crt /data/cert/  & cp yourdomain.com.key /data/cert/
6. ����docker��������˵�crtת����**docker�ͻ����õ�cert**yourdomain.com.cert��
	`openssl x509 -inform PEM -in yourdomain.com.crt -out yourdomain.com.cert`
7. ��֤����Ϣ����docker������Ŀ¼��
	`cp yourdomain.com.cert /etc/docker/certs.d/yourdomain.com/
  	cp yourdomain.com.key /etc/docker/certs.d/yourdomain.com/
  	cp ca.crt /etc/docker/certs.d/yourdomain.com/`
8. ��������֤�������OS�Ŀ����б�(ubuntu)
	`cp yourdomain.com.crt /usr/local/share/ca-certificates/yourdomain.com.crt
	update-ca-certificates`
9. �༭harbor��yaml���ã�
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

10. ִ��prepare�ű�
     `./prepare`

11. ����harbor ʹ��up/down��ʽ��docker-compose down -v / docker-compose up -d
	
