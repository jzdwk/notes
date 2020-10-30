# kong 安装

记录一下kong在ubuntu 18.04的安装方法

1. 下载kong的deb包，下载地址 https://docs.konghq.com/install/ubuntu/?_ga=2.208148498.1234996968.1603873234-1278379110.1586478466#packages

2. 执行安装:
```shell
 $ sudo apt-get update
 $ sudo apt-get install /absolute/path/to/package.deb
```

3. 配置db，kong支持`PostgreSQL 9.5+`以及`Cassandra 3.x.x`，项目中主要用到了`PostgreSQL 9.5+`，配置pg对于kong的用户：
```shell
#1.切换到pg的账户
sudo su postgres
#2. 用postgres登录
psql
#3. 创建kong角色，官方文档上没有设置密码，这里建议设置
postgres=# create user kong with password '123456';
#4. 创建db kong,并绑定kong角色,并赋权
postgres=# create database kong owner kong;  
postgres=# grant all on database dbtest to username;
```

4. 修改kong的配置文件，默认位置位于/etc/kong/kong.conf.default，可以cp一份，比如my.kong.conf,修改其中的pg_password项：
```shell
#pg_password =  123456                 # Postgres user's password.
```

5. 初始化数据,其中的-c后跟自定义配置的conf文件，由于修改了pg的密码，所以为`-c /etc/kong/my.kong.conf`：
```shell
kong migrations bootstrap [-c /path/to/kong.conf]
```

6. 启动kong，由于默认情况下，kong的admin端口只对本机开放，因此，如果需要开放这个端口，同样需要修改默认的kong.conf文件，定位：
```shell
#admin_listen = 127.0.0.1:8001 reuseport backlog=16384, 127.0.0.1:8444 http2 ssl reuseport backlog=16384
#修改为
admin_listen = 0.0.0.0:8001 reuseport backlog=16384, 0.0.0.0:8444 http2 ssl reuseport backlog=16384

## 启动，--vv用于打印信息
kong start -c  /etc/kong/my.kong.conf --vv
```

参考：https://docs.konghq.com/install/ubuntu/