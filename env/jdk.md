# jdk1.8 CentOS 7
## 删除系统自带openJDK
* yum list installed|grep java
* yum -y remove java-1.8.0-openjdk*
* yum -y remove tzdata-java.noarch
## 下载jdk 1.8 
* https://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html
## 安装 
* 创建java目录 mkdir /usr/local/java/
* 解压 tar -zxvf jdk-8u171-linux-x64.tar.gz -C /usr/local/java/
* 设置环境变量
  - vim /etc/profile
  - `export JAVA_HOME=/usr/local/java/jdk1.8.0_171
export JRE_HOME=${JAVA_HOME}/jre
export CLASSPATH=.:${JAVA_HOME}/lib:${JRE_HOME}/lib
export PATH=${JAVA_HOME}/bin:$PATH`
 - 生效 source /etc/profile
 - 添加ln ln -s /usr/local/java/jdk1.8.0_171/bin/java /usr/bin/java
## 检查
* java -version