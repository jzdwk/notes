# maven 3.6.1 CentOS 7
## ����maven 3.6.1
* IDEA 2019��3.6.2�����ݣ��������3.6.1 
* http://mirror.bit.edu.cn/apache/maven/maven-3/
## ��װ 
* ����mavenĿ¼ mkdir /usr/local/maven/
* ��ѹ tar -zxvf tar -zxvf apache-maven-3.6.1-bin.tar.gz  -C /usr/local/maven/
* ���û�������
  - vim /etc/profile
  - `export M2_HOME=M2_HOME=/usr/local/maven/{����Ŀ¼}
export PATH=${M2_HOME}/bin:$PATH`
 - ��Ч source /etc/profile
## ���ð��ﾵ��
* ��maven��װĿ¼->conf->setting.xml
* ��mirrors��ǩ����ӣ�
`<mirror>
    <id>aliyunmaven</id>
    <mirrorOf>*</mirrorOf>
    <name>�����ƹ����ֿ�</name>
    <url>https://maven.aliyun.com/repository/public</url>
`</mirror>
## ���ñ��زֿ�(��ѡ)
* �޸�maven��Ĭ�ϲֿ�
* vi settings.xml ��ӱ�ǩ <localRepository>/home/jzd/.m2/repository</localRepository>
## ���
* mvn-v