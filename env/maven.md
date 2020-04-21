# maven 3.6.1 CentOS 7
## 下载maven 3.6.1
* IDEA 2019与3.6.2不兼容，因此配置3.6.1 
* http://mirror.bit.edu.cn/apache/maven/maven-3/
## 安装 
* 创建maven目录 mkdir /usr/local/maven/
* 解压 tar -zxvf tar -zxvf apache-maven-3.6.1-bin.tar.gz  -C /usr/local/maven/
* 设置环境变量
  - vim /etc/profile
  - `export M2_HOME=M2_HOME=/usr/local/maven/{具体目录}
export PATH=${M2_HOME}/bin:$PATH`
 - 生效 source /etc/profile
## 配置阿里镜像
* 打开maven安装目录->conf->setting.xml
* 在mirrors标签下添加：
`<mirror>
    <id>aliyunmaven</id>
    <mirrorOf>*</mirrorOf>
    <name>阿里云公共仓库</name>
    <url>https://maven.aliyun.com/repository/public</url>
`</mirror>
## 配置本地仓库(可选)
* 修改maven的默认仓库
* vi settings.xml 添加标签 <localRepository>/home/jzd/.m2/repository</localRepository>
## 检查
* mvn-v