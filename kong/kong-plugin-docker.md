# kong插件容器安装

1. 准备待安装插件`api-transformer`以及kong容器：
```shell
[root@oneedge-iot-003 app]# docker ps
CONTAINER ID        IMAGE                                                       COMMAND                  CREATED             STATUS              PORTS                                                                NAMES
...
688cf9dba899        kong-cmcc-v1.2:2.0.5-centos                                 "/docker-entrypoint.…"   7 weeks ago         Up 7 weeks          0.0.0.0:8000-8001->8000-8001/tcp, 0.0.0.0:8443->8443/tcp, 8444/tcp   sigma-kong
...
```

2. 将插件`docker cp`进kong容器目录`/home/kong`：
```shell
[root@oneedge-iot-003 kong-exporter]# docker cp api-transformer 688cf9dba899:/home/kong 
```

3. 进入kong容器，安装插件：
```shell
[root@oneedge-iot-003 kong-exporter]# docker exec -it 688cf9dba899 /bin/bash
# 进入容器目录
[root@688cf9dba899 /]# cd /home/kong/api-transformer
# 执行luamake
[root@688cf9dba899 /]# luarocks make
```

4. 验证安装：

执行完后，会在目录`/usr/local/lib/luarocks/rocks-5.1`中，增加名为`kong-plugin-my-plugin`的目录。

5. 配置kong.conf

切换到目录`/etc/kong`，复制kong.conf.default到kong.conf，编辑kong.conf
```
## 修改日志级别，非必须，主要用于对plugin的bug进行定位
log_level = debug
#log_level = notice              # Log level of the Nginx server. Logs are
                                 # found at `<prefix>/logs/error.log`.
...
## 重要，在plugins项中增加api-transformer，bundled的意思是包含kong默认支持的plugin
plugins = bundled, api-transformer
#plugins = bundled               # Comma-separated list of plugins this node
                                 # should load. By default, only plugins
## 后文省略
...
```

6. 配置生效
```shell
# reload
kong prepare
kong reload -c xxx.conf
```

7. 导出镜像

```shell
[root@oneedge-iot-003 app]# docker commit -m "kong 2.0.5 with api-transformer" 688cf9dba899 kong-cmcc-v1.6:2.0.5-centos 
## 导出镜像文件
[root@oneedge-iot-003 app]# docker save -o sigma-kong.cmcc.2.0.5-centos-v1.6 kong-cmcc-v1.6:2.0.5-centos  
```

# 插件卸载

1. 清理已经在kong上应用的插件，即调用`{kong_admin_url}/plugins`的DELETE方法，删除所有该插件

2. 清理kong.conf中的plugins项，将添加的自定义插件删除，然后执行
```shell
# reload
kong prepare
kong reload -c xxx.conf
```

3. 使用`luarocks remove <kong-plugin-plugin-name>`，这将删除目录`/usr/local/lib/luarocks/rocks-5.1`中添加的自定义插件目录。