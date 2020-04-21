# mysql 5.6 CentOS 7
see: https://blog.csdn.net/pengjunlee/article/details/81212250
## 卸载mariaDB
* CentOS 默认安装了mysql或者mariadb，后者是mysql的一个开源分支
  * rpm -qa|grep -i mariadb 
  * rpm -qa | grep mysql 
  * 卸载 rpm -qa|grep mariadb|xargs rpm -e --nodeps
## 安装mysql
* 下载安装包文件 wget http://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
* 安装 rpm -ivh mysql-community-release-el7-5.noarch.rpm
* 安装完成之后，会在 /etc/yum.repos.d/ 目录下新增 mysql-community.repo 、mysql-community-source.repo 两个 yum 源文件
* 安装 yum install mysql-server
## 启动与配置
* 启动命令
   * systemctl start mysqld.service #启动 mysql
   - systemctl restart mysqld.service #重启 mysql
   - systemctl stop mysqld.service #停止 mysql
   - systemctl enable mysqld.service #设置 mysql 开机启动
* 首次安装后，root密码为空，进行配置
  - 登录 mysql -u root
  - use mysql;
  - update user set password=PASSWORD("这里输入root用户密码") where User='root';
  - flush privileges; 
  - 开放root的远程登录权限 GRANT ALL PRIVILEGES ON *.* TO root@"%" IDENTIFIED BY "password";
