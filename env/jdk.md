# jdk1.8 CentOS 7
## ɾ��ϵͳ�Դ�openJDK
* yum list installed|grep java
* yum -y remove java-1.8.0-openjdk*
* yum -y remove tzdata-java.noarch
## ����jdk 1.8 
* https://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html
## ��װ 
* ����javaĿ¼ mkdir /usr/local/java/
* ��ѹ tar -zxvf jdk-8u171-linux-x64.tar.gz -C /usr/local/java/
* ���û�������
  - vim /etc/profile
  - `export JAVA_HOME=/usr/local/java/jdk1.8.0_171
export JRE_HOME=${JAVA_HOME}/jre
export CLASSPATH=.:${JAVA_HOME}/lib:${JRE_HOME}/lib
export PATH=${JAVA_HOME}/bin:$PATH`
 - ��Ч source /etc/profile
 - ���ln ln -s /usr/local/java/jdk1.8.0_171/bin/java /usr/bin/java
## ���
* java -version