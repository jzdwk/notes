# mysql 5.6 CentOS 7
see: https://blog.csdn.net/pengjunlee/article/details/81212250
## ж��mariaDB
* CentOS Ĭ�ϰ�װ��mysql����mariadb��������mysql��һ����Դ��֧
  * rpm -qa|grep -i mariadb 
  * rpm -qa | grep mysql 
  * ж�� rpm -qa|grep mariadb|xargs rpm -e --nodeps
## ��װmysql
* ���ذ�װ���ļ� wget http://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
* ��װ rpm -ivh mysql-community-release-el7-5.noarch.rpm
* ��װ���֮�󣬻��� /etc/yum.repos.d/ Ŀ¼������ mysql-community.repo ��mysql-community-source.repo ���� yum Դ�ļ�
* ��װ yum install mysql-server
## ����������
* ��������
   * systemctl start mysqld.service #���� mysql
   - systemctl restart mysqld.service #���� mysql
   - systemctl stop mysqld.service #ֹͣ mysql
   - systemctl enable mysqld.service #���� mysql ��������
* �״ΰ�װ��root����Ϊ�գ���������
  - ��¼ mysql -u root
  - use mysql;
  - update user set password=PASSWORD("��������root�û�����") where User='root';
  - flush privileges; 
  - ����root��Զ�̵�¼Ȩ�� GRANT ALL PRIVILEGES ON *.* TO root@"%" IDENTIFIED BY "password";
