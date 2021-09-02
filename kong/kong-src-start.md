# kong start

简单介绍下kong的启动流程。从kong的容器启动说起，当执行kong容器启动时，通过`docker ps --no-trunc`查看命令：
```shell
docker ps -a --no-trunc|grep kong-cmcc
3be6531a1997   kong-cmcc:2.0.5-centos    "/docker-entrypoint.sh kong docker-start"    6 months ago   Up 38 minutes  0.0.0.0:8000-8001->8000-8001/tcp,0.0.0.0:8443->8443/tcp, 8444/tcp  kong-trans
```
## kong start
 
进入容器，直接看脚本`docker-entrypoint.sh`的内容：
```shell
[root@3be6531a1997 /]# cat /docker-entrypoint.sh 
#!/usr/bin/env bash
set -Eeo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
# 用于将参数对应的文件的内容赋值给参数本身
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	# Do not continue if _FILE env is not set
	if ! [ "${!fileVar:-}" ]; then
		return
	elif [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

export KONG_NGINX_DAEMON=off

# 因为脚本执行为docker-entrypoint.sh kong docker-start，所以一下if均可执行
if [[ "$1" == "kong" ]]; then
  PREFIX=${KONG_PREFIX:=/usr/local/kong}
  # 将KONG的DB信息写入环境变量
  file_env KONG_PG_PASSWORD
  file_env KONG_PG_USER
  file_env KONG_PG_DATABASE

  if [[ "$2" == "docker-start" ]]; then
    # 执行kong prepare -p /usr/local/kong ，和nginx启动配合，可代替kong start
    kong prepare -p "$PREFIX" "$@"

    ln -sf /dev/stdout $PREFIX/logs/access.log
    ln -sf /dev/stdout $PREFIX/logs/admin_access.log
    ln -sf /dev/stderr $PREFIX/logs/error.log
    # 执行nginx -p /usr/local/kong -c nginx.conf
    exec /usr/local/openresty/nginx/sbin/nginx \
      -p "$PREFIX" \
      -c nginx.conf
  fi
fi

exec "$@"
```
首先执行了`kong prepare`来初始化prefix，之后`执行nginx -p /usr/local/kong -c nginx.conf`，因此查看**其conf文件，发现include了同级目录下的nginx-kong.conf**，注，其中涉及的lua-nginx-module , [详细参考](https://github.com/openresty/lua-nginx-module)


## nginx conf

nginx-kong.conf的内容如下：
```shell

charset UTF-8;
server_tokens off;

error_log /dev/stderr debug;


# 设置lua库路径，比如当lua中出现  require "abc.test",则根据path定义，替换问号并依次在./abc/test.lua；/abc/test/init.lua等路径查找文件
lua_package_path       './?.lua;./?/init.lua;;;;';
# 设置C编写的lua扩展模块的路径
lua_package_cpath      ';;;';
# 指定与每个远程服务器相关联的每个cosocket连接池的大小限制
lua_socket_pool_size   30;
lua_socket_log_errors  off;

# 设置运行running和等待pending计时器的最大数量
lua_max_running_timers 4096;
lua_max_pending_timers 16384;
# 在Lua cosockets使用的服务器证书链中设置验证深度。
lua_ssl_verify_depth   1;

# 设置共享内存字典，语法 lua_shared_dict <name> <size>，内存字典对于nginx所有的worker进程都可见
lua_shared_dict kong                        5m;
lua_shared_dict kong_locks                  8m;
lua_shared_dict kong_healthchecks           5m;
lua_shared_dict kong_process_events         5m;
lua_shared_dict kong_cluster_events         5m;
lua_shared_dict kong_rate_limiting_counters 12m;
lua_shared_dict kong_core_db_cache          128m;
lua_shared_dict kong_core_db_cache_miss     12m;
lua_shared_dict kong_db_cache               128m;
lua_shared_dict kong_db_cache_miss          12m;

# 如果为off, http头中带有下划线的字段将无效
underscores_in_headers on;

# 以下为ssl相关配置
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
# injected nginx_http_* directives
client_max_body_size 0;
ssl_prefer_server_ciphers off;
client_body_buffer_size 8k;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_session_tickets on;
ssl_session_timeout 1d;

lua_shared_dict prometheus_metrics 5m;

# 执行openresty的init阶段，具体由kong实现

init_by_lua_block {
    Kong = require 'kong'
    Kong.init()
}
init_worker_by_lua_block {
    Kong.init_worker()
}

# 设置kong upstream
upstream kong_upstream {
    server 0.0.0.1;
	# 在content阶段，定义lb的具体实现
    balancer_by_lua_block {
        Kong.balancer()
    }

    # injected nginx_upstream_* directives
    keepalive_requests 100;
    keepalive_timeout 60s;
    keepalive 60;
}

server {
    server_name kong; 
	# 注意这里的reuseport 是linux3.9版本后的新特性，该选项允许多个套接字监听同一IP和端口的组合。内核能够在这些套接字中对传入的连接进行负载均衡。
    listen 0.0.0.0:8000 reuseport backlog=16384;
    listen 0.0.0.0:8443 ssl http2 reuseport backlog=16384;

    error_page 400 404 408 411 412 413 414 417 494 /kong_error_handler;
    error_page 500 502 503 504                     /kong_error_handler;

    access_log /dev/stdout;
    error_log  /dev/stderr debug;

    ssl_certificate     /usr/local/kong/ssl/kong-default.crt;
    ssl_certificate_key /usr/local/kong/ssl/kong-default.key;
    ssl_session_cache   shared:SSL:10m;
    
	# 当 Nginx 将要与下游 SSL（https）连接开始 SSL 握手时，运行该指令指定的用户 Lua 代码。
	ssl_certificate_by_lua_block {
        Kong.ssl_certificate()
    }

    # injected nginx_proxy_* directives
    real_ip_header X-Real-IP;
    real_ip_recursive off;


    # 执行rewrite和access阶段，执行kong代码
    rewrite_by_lua_block {
        Kong.rewrite()
    }

    access_by_lua_block {
        Kong.access()
    }

    # 执行content阶段
    header_filter_by_lua_block {
        Kong.header_filter()
    }

    body_filter_by_lua_block {
        Kong.body_filter()
    }

    # log阶段 
    log_by_lua_block {
        Kong.log()
    }

   
    location / {
        default_type                    '';

        set $ctx_ref                    '';
        set $upstream_te                '';
        set $upstream_host              '';
        set $upstream_upgrade           '';
        set $upstream_connection        '';
        set $upstream_scheme            '';
        set $upstream_uri               '';
        set $upstream_x_forwarded_for   '';
        set $upstream_x_forwarded_proto '';
        set $upstream_x_forwarded_host  '';
        set $upstream_x_forwarded_port  '';
        set $kong_proxy_mode            'http';

        proxy_http_version    1.1;
        proxy_set_header      TE                $upstream_te;
        proxy_set_header      Host              $upstream_host;
        proxy_set_header      Upgrade           $upstream_upgrade;
        proxy_set_header      Connection        $upstream_connection;
        proxy_set_header      X-Forwarded-For   $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host  $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port  $upstream_x_forwarded_port;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location @grpc {
        internal;
        default_type         '';
        set $kong_proxy_mode 'grpc';

        grpc_set_header      TE                $upstream_te;
        grpc_set_header      Host              $upstream_host;
        grpc_set_header      X-Forwarded-For   $upstream_x_forwarded_for;
        grpc_set_header      X-Forwarded-Proto $upstream_x_forwarded_proto;
        grpc_set_header      X-Forwarded-Host  $upstream_x_forwarded_host;
        grpc_set_header      X-Forwarded-Port  $upstream_x_forwarded_port;
        grpc_set_header      X-Real-IP         $remote_addr;
        grpc_pass_header     Server;
        grpc_pass_header     Date;
        grpc_pass            grpc://kong_upstream;
    }

    location @grpcs {
        internal;
        default_type         '';
        set $kong_proxy_mode 'grpc';

        grpc_set_header      TE                $upstream_te;
        grpc_set_header      Host              $upstream_host;
        grpc_set_header      X-Forwarded-For   $upstream_x_forwarded_for;
        grpc_set_header      X-Forwarded-Proto $upstream_x_forwarded_proto;
        grpc_set_header      X-Forwarded-Host  $upstream_x_forwarded_host;
        grpc_set_header      X-Forwarded-Port  $upstream_x_forwarded_port;
        grpc_set_header      X-Real-IP         $remote_addr;
        grpc_pass_header     Server;
        grpc_pass_header     Date;
        grpc_ssl_name        $upstream_host;
        grpc_ssl_server_name on;
        grpc_pass            grpcs://kong_upstream;
    }

    location = /kong_buffered_http {
        internal;
        default_type         '';
        set $kong_proxy_mode 'http';

        rewrite_by_lua_block       {;}
        access_by_lua_block        {;}
        header_filter_by_lua_block {;}
        body_filter_by_lua_block   {;}
        log_by_lua_block           {;}

        proxy_http_version 1.1;
        proxy_set_header      TE                $upstream_te;
        proxy_set_header      Host              $upstream_host;
        proxy_set_header      Upgrade           $upstream_upgrade;
        proxy_set_header      Connection        $upstream_connection;
        proxy_set_header      X-Forwarded-For   $upstream_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $upstream_x_forwarded_proto;
        proxy_set_header      X-Forwarded-Host  $upstream_x_forwarded_host;
        proxy_set_header      X-Forwarded-Port  $upstream_x_forwarded_port;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_pass_header     Server;
        proxy_pass_header     Date;
        proxy_ssl_name        $upstream_host;
        proxy_ssl_server_name on;
        proxy_pass            $upstream_scheme://kong_upstream$upstream_uri;
    }

    location = /kong_error_handler {
        internal;
        default_type                 '';

        uninitialized_variable_warn  off;

        rewrite_by_lua_block {;}
        access_by_lua_block  {;}

        content_by_lua_block {
            Kong.handle_error()
        }
    }
}

# kong 的admin api定义
server {
    server_name kong_admin;
    listen 0.0.0.0:8001;

    access_log /dev/stdout;
    error_log  /dev/stderr debug;

    client_max_body_size    10m;
    client_body_buffer_size 10m;


    # injected nginx_admin_* directives

    location / {
        default_type application/json;
        content_by_lua_block {
            Kong.admin_content()
        }
        header_filter_by_lua_block {
            Kong.admin_header_filter()
        }
    }

    location /nginx_status {
        internal;
        access_log off;
        stub_status;
    }

    location /robots.txt {
        return 200 'User-agent: *\nDisallow: /';
    }
}
```
以上即为kong的核心nginx.conf配置，从中可以看到其基于openresty。具体为，**在openresty的处理请求的几个阶段中，定义了kong的具体实现。因此，除了使用kong网关，也可以将kong嵌入到已部署的openresty中**。

总的来说，执行 kong start 启动 Kong 之后（或者如上，先执行Kong prepare 后执行nginx), Kong 会将解析之后的配置文件保存在 $prefix/.kong_env，同时生成 $prefix/nginx.conf、$prefix/nginx-kong.conf 供 OpenResty 的使用。需要注意的是，这三个配置文件在每次 Kong 启动后均会被覆盖，所以这里是不能修改自定义配置的。如果需要自定义 OpenResty 配置，需要自己准备配置模板，然后启动的时候调用：kong start -c kong.conf --nginx-conf custom_nginx.template 即可。


附，openresry的处理阶段图
![image](../images/kong/openresty-phases.png)

参考：
[1](https://github.com/openresty/lua-nginx-module)
[2](https://cloud.tencent.com/developer/article/1489439)
