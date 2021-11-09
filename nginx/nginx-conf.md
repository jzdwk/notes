# nginx conf配置笔记

详细参考[官方文档](http://nginx.org/en/docs/beginners_guide.html#conf_structure)

## conf struct
配置文件结构如下：
```
#1 全局块：配置影响nginx全局的指令。一般有运行nginx服务器的用户组，nginx进程pid存放路径，日志存放路径，配置文件引入，允许生成worker process数等。
...              

#2 events块：配置影响nginx服务器或与用户的网络连接。有每个进程的最大连接数，选取哪种事件驱动模型处理连接请求，是否允许同时接受多个网路连接，开启多个网络连接序列化等。
events {         
   ...
}

#3 http块：可以嵌套多个server，配置代理，缓存，日志定义等绝大多数功能和第三方模块的配置。如文件引入，mime-type定义，日志自定义，是否使用sendfile传输文件，连接超时时间，单连接请求数等
http      
{
	#3.1 http全局块
    ...   
	#4 server块：配置虚拟主机的相关参数，一个http中可以有多个server。 
    server        
    { 
		#4.1 server全局块
        ... 
		#5 	location块：配置请求的路由，以及各种页面的处理情况。 
        location [PATTERN]
        {
            ...
        }
        location [PATTERN] 
        {
            ...
        }
    }
    server
    {
      ...
    }
}
```
## conf example

记录一些常用的nginx配置：

```
#配置用户或者组，默认为nobody nobody
user administrator administrators;  

# 默认on，指定了是否以master-worker进程的方式运行，如果设置为off，那么所有的请求将只会由master进程处理
master_process on|off;


# 指定了error日志的目录和日志级别，第二个参数用于指定目录，第三个参数用于指定日志级别.
# 日志级别总共有：debug、info、notice、warn、error、crit、alert、emerg，这些日志级别中，从左往右优先级依次增大，默认为info
# 如果指定为/dev/null，则不会输出日志，即关闭
error_log logs/error.log error;

# 指定调试点，nginx在关键逻辑中设置调试点.
# 当为stop，执行时会发出SIGSTOP信号
# 当为abort，会产生coredump文件
debug_points stop|abort

# 限制coredump出的文件大小
worker_rlimit_core size;
# 指定coredump文件生成目录
working_directory path;
# 设置nginx worker进程优先级，unix进程优先级分静态和动态优先级2种。
# 动态优先级由内核决定，此处设置的nice是静态，范围-20-+19；越小越高。一般设置为比内核进程(通常为-5)大的值。
# worker_priority nice;


# 嵌入其他conf文件
include pathfile;

# 执行nginx 主进程的pid文件位置
#pid        logs/nginx.pid;

#允许生成的进程数，默认为1
worker_processes 2;  
# worker进程是否绑定某cpu
worker_cpu_affinity 0001 0010 0100 1000;

#指定nginx进程运行文件存放地址
pid /nginx/pid/nginx.pid;   

# 是否后台运行，默认on。
daemon on|off;

# nginx worker进程可以打开的最大句柄数
worker_rlimit_nofile limit;
# 设置每个worker发往nginx的信号队列大小，如果队满，新产生的信号量将被丢掉
worker_rlimit_sigpending limit;

# SSL硬件加速，服务器提供SSL硬件加速设备，可通过openssl engine -t查看
ssl_engine_device;

# 事件块
events {
	#设置nginx的负载均衡锁，确保worker进程轮流、序列化的与新client建立tcp连接。默认on
	accept_mutex on;
	#设置accept_mutex锁后，如果worker进程没有得到锁，设置需要再次获取锁的等待时机。默认500ms
	accept_mutex_delay 500ms; 
	#当开启accept_mutex并且由于宿主环境导致nginx不支持原子锁时，使用文件锁。默认logs/nginx.lock
	lock_file path/file; 	

	#当事件模型通知有新连接时，设置一个进程是否同时接受多个网络连接，默认为off
    multi_accept on; 	
 	#选择事件模型，select|poll|kqueue|epoll|resig|/dev/poll|eventport；nginx会自动使用最合格的模型；重点为epoll
    use epoll;  
   	
	#最大连接数，默认为512
    worker_connections  1024;    
}


http {
    ## MIME 相关
	#文件扩展名与文件类型映射表，mime.types文件将在conf/mime.type中体现
    include       mime.types;   
	#在mime.type中找不到映射时，默认文件类型，默认为text/plain
    default_type  application/octet-stream; 
	#使用散列表存储映射文件，与server_name类似
	types_hash_bucket_size 32;
	types_hash_max_size 1024;
	
	
	
    #access_log off; #取消服务日志   
		
    log_format myFormat '$remote_addr–$remote_user [$time_local] $request $status $body_bytes_sent $http_referer $http_user_agent $http_x_forwarded_for'; #自定义格式
    access_log log/access.log myFormat;  #combined为日志格式的默认值
    sendfile on;   #允许sendfile方式传输文件，默认为off，可以在http块，server块，location块。
    sendfile_max_chunk 100k;  #每个进程每次调用传输数量不能大于设定的值，默认为0，即不设上限。
    

    upstream mysvr {   
      server 127.0.0.1:7878;
      server 192.168.10.121:3333 backup;  #热备
    }
   
	
	#ip地址优先，所以一个ip可以由多个域名，对应到多个server上。故每一个server块代表一个虚拟主机，它只处理针对此主机域名的请求
    
	server {
		#监听端口，除了端口，后可跟default等配置。当请求不匹配所有域名，走默认server。不设置时，使用第一个。
		listen       4545 default_server ssl; 
		#主机名称，后可跟多个。nginx取出header头中的host，与每个server的name匹配。
		server_name  www.testweb.com; 
		#使用散列表提高查找server name的能力，设置每个散列通占用的内存大小
		server_names_hash_bucket_size size;
		#设置散列表的大小，越大hash冲突越低
		server_names_hash_max_size 512;
		#请求重定向时，使用server_name中第一项主机名代替原请求Host头部
		server_name_in_redirect on;
		
        keepalive_requests 120; #单连接请求上限次数。
		
		## 以下设置请求时的磁盘 缓存
		# HTTP包体存储到磁盘，一般用于调试 默认off
		client_body_in_file_only on|clean|off；
		# HTTP包体写入一个内存buffer中，默认off，写不下写磁盘
		client_body_in_single_buufer on|off
		# 存储HTTP头部的内存buffer大小，超出将使用large配置
		client_header_buffer_size size
		# 如果这个也超出，返回414 Request URI too large
		large_client_header_buffers size;
		# HTTP包体的内存缓冲区大小，HTTP包体接收到指定缓存，
		client_body_buffer_size 8k;
		# HTTP包体的临时存放目录，如果HTTP包体大于client_body_buffer_size，则存储到此目录
		client_body_temp_path path;	
		#每一个建立成功的TCP预先分配的内存池大小,TCP关闭时销毁
		connection_pool_size 8k;
		#每一个请求分配一个内存池，请求结束时销毁
		request_pool_size 4k;
		
		## 连接处理相关
		#读取HTTP头的超时时间，超时返回408，默认60s
		client_header_timeout 60;
		#读取HTTP包超时时间
		client_body_timeout 60;
		#发送响应的超时时间
		send_timeout 60;
		#当连接超时时，不使用TCP 4次握手关闭，而是向用户发送RST重置包
		reset_timeout_connection on|off;
		
		#关闭用户连接的方式,always为关闭时无条件处理完连接上所有用户的数据，off表示完全不管。默认on
		lingering_close on|off|always;
		#经过该时间，将直接断掉client的请求，多用于上传大文件时的超时处理
		lingering_time 60;
		#lingering_close生效后，超过timeout的时间还没有可读数据，才关闭连接
		lingering_timeout 5s;
		
		#对某些浏览器禁用keepalive
		keepalive_disable safari;
		#连接超时时间，默认为75s，可以在http，server，location块。
		keepalive_timeout 65;  
		#一个长连接上允许承载的最大请求数
		keepalive_requests 100;
		
		#keepalive是否使用TCP_NODELAY选项
		tcp_nopush off;
		#打开sendfile时，是否开启Linux上的TCP_CORK功能
		tcp_nodelay on;
		
		##请求相关
		#请求包体的最大值
		client_max_body_size 1m;
		#请求限速
		limit_rate 0;
		#请求限速
		limit_rate 0;
		#nginx响应的长度超过设置时，启用限速
		limit_rate_after 1m;
		
		##文件操作
		#从磁盘读取文件后，直接在内核态发送到网卡设备
		snedfile off;
		#启用内核级异步I/O功能，与sendfile互斥
		aio off;
		#使用O_DIRECT选项读取文件
		directio off;
		#在directio读取文件时，设置对齐方式
		directio_alignment 512；
		#打开文件缓存，max表示内存中存储元素的最大个数，达到阈值采用LRU；inactive表示在该时间段内没有被访问过的元素。默认为off
		open_file_cache max=1024 inactive=20s;
		#是否缓存错误文件，如鉴权失败
		open_file_cache_errors off;
		#不被淘汰的最小访问次数，与open_file_cache的inactive配合，即使达到inactive，但是次数没到，也不淘汰
		open_file_cache_min_uses 1;
		#缓存有效性检查频率，默认60s检查一次
		open_file_cache_valid 60s;
		
		##Client特殊处理
		# 忽略不合法HTTP头，如果为off，当HTTP头有不合法信息时，返回400，默认On
		ignore_invalid_headers on;
		# HTTP头是否允许下划线，默认off
		underscores_in_headers off;
		# 浏览器为优化访问，会有本地缓存。请求时HTTP携带If-Modified-Since头，其中携带资源上次的获取时间
		# 可选off，忽略请求，直接返回
		# exact：与将要返回的文件的上一次修改时间做对比，如果相等，说明缓存是新的，返回304告知。此时浏览器读本地缓存
		# defore：同上，时间比对上，修改时间如果早于请求，说明缓存是新的，返回304
		if_modified_since exact;
		# 文件没有找到时，是否记录error日志，默认on
		log_not_found on;
		# 是否合并相邻的"/"，比如/test///index.html => /test/index.html 默认on
		merge_slashes on;
		# 返回错误页面时，是否标注nginx版本
		server_token on;
		
		## DNS解析
		#设置DNS服务器地址
		resolver 127.0.0.1 8.8.8.8;
		#DNS解析超时时间
		resolver_timeout 30s;
		
		
		#重要，匹配请求的URI，其优先级
        location  ~*^.+$ { 
			#定义资源文件相对于HTTP请求的根目录，比如有请求为/download/test.conf,则返回服务器上/root/test/download/test.conf下的资源
			root /root/test;
			#只能放到location块中，当匹配location定义的前缀时，将其请求替换为alias描述的路径
			alias path;
			#定义首页，站点首页的URI一般是/
			index index.html htmlindex.php;  
			#错误页，可以通过"="来重新制定错误码，比如error_page 404 =200 404.html
			error_page 404 404.html
			error_page 502 503 504 50x.html
			#匹配location后，尝试访问path1-pathn的资源，成功直接返回，失败则重定向到uri参数路径
			try_files path1 path2 $uri $uri/index.html;
			
			#基于方法名的用户请求限制
			limit_except GET {
				allow 192.168.1.0/32;
				deny all;
			}
			
			
           proxy_pass  http://mysvr;  #请求转向mysvr 定义的服务器列表
           deny 127.0.0.1;  #拒绝的ip
           allow 172.18.5.54; #允许的ip           
        } 
    }
}

```

## 常用变量

在conf文件中，`ngx_http_core_module`在处理请求时，提供了常用变量供业务逻辑，access.log等读取：
```
$args                    #请求中的参数值
$query_string            #同 $args
$arg_NAME                #GET请求中NAME的值
$is_args                 #如果请求中有参数，值为"?"，否则为空字符串
$uri                     #请求中的当前URI(不带请求参数，参数位于$args)
$document_uri            #同 $uri
$document_root           #当前请求的文档根目录或别名
$host                    #优先级：HTTP请求行的主机名>"HOST"请求头字段>符合请求的服务器名.请求中的主机头字段，如果请求中的主机头不可用，则为服务器处理请求的服务器名称
$hostname                #主机名
$https                   #如果开启了SSL安全模式，值为"on"，否则为空字符串。
$binary_remote_addr      #客户端地址的二进制形式，固定长度为4个字节
$body_bytes_sent         #传输给客户端的字节数，响应头不计算在内；这个变量和Apache的mod_log_config模块中的"%B"参数保持兼容
$bytes_sent              #传输给客户端的字节数
$connection              #TCP连接的序列号
$connection_requests     #TCP连接当前的请求数量
$content_length          #"Content-Length" 请求头字段
$content_type            #"Content-Type" 请求头字段
$cookie_name             #cookie名称
$limit_rate              #用于设置响应的速度限制
$msec                    #当前的Unix时间戳
$nginx_version           #nginx版本
$pid                     #工作进程的PID
$pipe                    #如果请求来自管道通信，值为"p"，否则为"."
$proxy_protocol_addr     #获取代理访问服务器的客户端地址，如果是直接访问，该值为空字符串
$realpath_root           #当前请求的文档根目录或别名的真实路径，会将所有符号连接转换为真实路径
$remote_addr             #客户端地址
$remote_port             #客户端端口
$remote_user             #用于HTTP基础认证服务的用户名
$request                 #代表客户端的请求地址
$request_body            #客户端的请求主体：此变量可在location中使用，将请求主体通过proxy_pass，fastcgi_pass，uwsgi_pass和scgi_pass传递给下一级的代理服务器
$request_body_file       #将客户端请求主体保存在临时文件中。文件处理结束后，此文件需删除。如果需要之一开启此功能，需要设置client_body_in_file_only。如果将次文件传 递给后端的代理服务器，需要禁用request body，即设置proxy_pass_request_body off，fastcgi_pass_request_body off，uwsgi_pass_request_body off，or scgi_pass_request_body off
$request_completion      #如果请求成功，值为"OK"，如果请求未完成或者请求不是一个范围请求的最后一部分，则为空
$request_filename        #当前连接请求的文件路径，由root或alias指令与URI请求生成
$request_length          #请求的长度 (包括请求的地址，http请求头和请求主体)
$request_method          #HTTP请求方法，通常为"GET"或"POST"
$request_time            #处理客户端请求使用的时间,单位为秒，精度毫秒； 从读入客户端的第一个字节开始，直到把最后一个字符发送给客户端后进行日志写入为止。
$request_uri             #这个变量等于包含一些客户端请求参数的原始URI，它无法修改，请查看$uri更改或重写URI，不包含主机名，例如："/cnphp/test.php?arg=freemouse"
$scheme                  #请求使用的Web协议，"http" 或 "https"
$server_addr             #服务器端地址，需要注意的是：为了避免访问linux系统内核，应将ip地址提前设置在配置文件中
$server_name             #服务器名
$server_port             #服务器端口
$server_protocol         #服务器的HTTP版本，通常为 "HTTP/1.0" 或 "HTTP/1.1"
$status                  #HTTP响应代码
$time_iso8601            #服务器时间的ISO 8610格式
$time_local              #服务器时间（LOG Format 格式）
$cookie_NAME             #客户端请求Header头中的cookie变量，前缀"$cookie_"加上cookie名称的变量，该变量的值即为cookie名称的值
$http_NAME               #匹配任意请求头字段；变量名中的后半部分NAME可以替换成任意请求头字段，如在配置文件中需要获取http请求头："Accept-Language"，$http_accept_language即可
$http_cookie
$http_host               #请求地址，即浏览器中你输入的地址（IP或域名）
$http_referer            #url跳转来源,用来记录从那个页面链接访问过来的
$http_user_agent         #用户终端浏览器等信息
$http_x_forwarded_for
$sent_http_NAME          #可以设置任意http响应头字段；变量名中的后半部分NAME可以替换成任意响应头字段，如需要设置响应头Content-length，$sent_http_content_length即可
$sent_http_cache_control 
$sent_http_connection
$sent_http_content_type
$sent_http_keep_alive
$sent_http_last_modified
$sent_http_location
$sent_http_transfer_encoding
```

## 负载均衡与反向代理

### 负载均衡

Nginx作为负载均衡器的常见配置如下：
```
upstream backend {
	# server 后跟上游服务器的地址，可以是域名、ip、unix套接字
	# 地址后可跟参数
	# weight=num 权重，默认1   max_fails=num/fail_timeout=time 在fail_timeout时间内，如果失败次数超过max_fails 则不可用。
	# down 表示服务器下线，在ip_hash配置项时才有用
	# backup 在非ip_hash模式下启用，作为备用server，只有所有的server不可用后，才接收请求
	server backend1.example.com
	server backend2.example.com
	# 根据client端ip算key 根据upstream内服务数量取模，保证同一客户端只发指定backend。
	# 和权重模式不可同时使用；服务器下线不能删除配置，使用down标识；
	ip_hash；
}
```
在upstream块中，可使用如下变量：
```
$upstream_addr 处理请求的上游服务器地址
$upstream_cache_status 是否命中缓存
$upstream_status 上游服务器返回的HTTP响应码
$upstream_response_time 上游服务器响应时间，单位ms
$upstream_http_$HEADER 返回的HTTP头部，如upsteam_http_host
```


### 反向代理
```
server{

	listen 80;

	server_name b.com;

	location / {
		 
		# 将当前请求代理到指定服务器上，可以是upstream/ip/unix套接字
		proxy_pass http://backend;
		# 转发时方法名
		proxy_method POST;
		# 指定哪些HTTP头不能被转发
		proxy_hide_header Cache-Control;
		# 指定哪些http头可以被转发，nginx默认不转发Date,Server,X-Accel-*等头
		proxy_pass_header X-Accel-Redirect；
		# 是否向upstream转发body，默认On
		proxy_pass_request_body on;
		# 是否转发http头部 默认on
		proxy_pass_request_headers on;
		# 当上游的返回是一个重定向，则重设其HTTP头部的location或者refresh字段
		# 比如上游返回location为 http://localhost/a/b 则实际返回http://frontend/uri
		# 使用off表示维持原Location不变
		proxy_redirect  http://localhost/a/b http://frontend/uri
		# 当向某一上游server转发请求出错时，继续换一台处理请求
		proxy_next_upstream error timeout;
		# 设置转发时增加的http头
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

	}
}
···











