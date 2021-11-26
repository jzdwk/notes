# upstream

当nginx需要访问第三方服务时，如果自己进行socket编程实现，将会破坏nginx优秀的全异步架构。因此，nginx提供了两种全异步方式的通信模块：
- **upstream**：主要负责直接访问上游服务器，比如高效透传的场景。
- **subrequest**：主要负责子请求的处理，当nginx接收客户端请求后，需要发一些子请求获取某些信息，再进行响应处理。
此处主要记录**upstream**，注意，此处的upstream是nginx的处理模块，属于HTTP框架的一部分，与nginx.conf中的upstream{}块是两码事（虽然后者也由前者实现）。

## 场景

以之前实现的mytest模块为例，设计场景。当nginx扫描到mytest配置项后，将携带客户端请求的URL的参数，访问baidu，并发结果返回给客户端：
```
//1. nginx.conf配置
location /test {
	mytest;
}
//2. 访问nginx服务
curl localhost:80/test?lumia
//3. nginx向baidu异步转发实际请求
curl http://www.baidu.com/s?wd=lumia
```

## upstream的使用

upstream使用时，本质还是访问第三方服务，那么就需要：
1. 确定访问时机，即接收客户端请求解析后何时进行访问
2. 确定访问对象
3. 构造请求并建立TCP
4. 处理返回并关闭TCP连接
5. 访问策略的配置
只是与socket编程不同，其实现上需要遵循nginx的架构，定义数据结构并实现一些回调函数，注册这些钩子到nginx的处理流程中

### ngx_http_upstream_t

首先介绍ngx_http_upstream_t，该结构体是upstream模块的核心，这里指介绍与上文实现mytest相关的项的定义：
```c
typedef struct ngx_http_upstream_s    ngx_http_upstream_t;

struct ngx_http_upstream_s {
    ...
	ngx_chain_t *request_bufs;                          // 用链表将ngx_buf_t缓冲区链接起来，表示所有需要发送到上游的请求内容，在实现create_request方法时需要设置
                                                   
    ...
    ngx_http_upstream_conf_t *conf;                     // upstream相关的配置信息，即上节的第5条，比如第三方访问时的过期时间等
	...
    ngx_http_upstream_resolved_t *resolved;             // 解析主机域名，或设置上游服务器的地址，即上节的第2条

	...
	// 主要用于接收上游服务器的响应内容，此时根据有两种方式，一种全接收后缓存，另一种为部分接收部分转发，故buffer的使用具体包括
	//1. 使用process_header方法解析上游响应包头时，buffer中保存完整包头		
	//2. 如果buffering=1，且此时upstream是向下游转发上游的包体时，buffer无意义
	//3. 如果buffering=0，buffer会反复接收上游包体并向下游转发
	//4. 当upstream不用于转发上游包体时，会被用于反复接收上游的包体，与HTTP模块实现的input_filter方法相关
    ngx_buf_t buffer;                                   
	
	...
	//以下为8个回调方法，其中create_request、process_header、finalize_request是必须实现的：
	
	//1. 用于构造发往上游服务器的请求，即上节第3条
    ngx_int_t (*create_request)(ngx_http_request_t *r); 
	//2. 解析上游服务器返回响应的包头，即上节第4条：
	// 返回NGX_OK，说明解析到完整包头
	// 返回NGX_AGAIN，说明接收不完整，继续调用process_header，直到收到非NGX_AGAIN
    ngx_int_t (*process_header)(ngx_http_request_t *r);
	//3. 请求结束时会调用，即第5条
    void (*finalize_request)(ngx_http_request_t *r,     
                                         ngx_int_t rc);
	
	//其他可选的回调
    ngx_int_t (*input_filter_init)(void *data);         // 处理包体前的初始化方法 其中data用于传递用户数据结构 即下方的input_filter_ctx
    ngx_int_t (*input_filter)(void *data, ssize_t bytes)// 处理包体的方法 bytes表示本次接收到的包体长度 data同上
	
	ngx_int_t (*reinit_request)(ngx_http_request_t *r); // 与上游通讯失败 需要重新发起连接时 用该方法重新初始化请求信息
	void (*abort_request)(ngx_http_request_t *r);       // 暂时没有用到	
    ngx_int_t (*rewrite_redirect)(ngx_http_request_t *r,// 上游返回响应中含Location或Refresh时 process_header会调用http模块实现的该方法
                     ngx_table_elt_t *h, size_t prefix);	
	ngx_int_t (*rewrite_cookie)(ngx_http_request_t *r,  // 同上 当响应中含Set-Cookie时 会调用http模块实现的该方法
                               ngx_table_elt_t *h);
	...
	// 向下游转发响应包体时，是否开启更大内存及临时磁盘文件用于缓存来不及发送到下游的响应包体
    unsigned buffering:1;                              
    ...
}
```


### demo实现

1. **前置结构体定义**
定义mytest的ngx_module_t/ngx_http_module_t/ngx_command_t，此处的写法与conf解析等代码一直，不再赘述：
```c
//mytest   HTTP模块
ngx_module_t  ngx_http_mytest_module =
{
    NGX_MODULE_V1,
    &ngx_http_mytest_module_ctx,           /* module context */
    ngx_http_mytest_commands,              /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};

//command定义，解析配置
static ngx_command_t  ngx_http_mytest_commands[] =
{

    {
        ngx_string("mytest"),
        NGX_HTTP_MAIN_CONF | NGX_HTTP_SRV_CONF | NGX_HTTP_LOC_CONF | NGX_HTTP_LMT_CONF | NGX_CONF_NOARGS,
        ngx_http_mytest,
        NGX_HTTP_LOC_CONF_OFFSET,
        0,
        NULL
    },

    ngx_null_command
};
//ctx定义，设置回调，init/merge配置项
static ngx_http_module_t  ngx_http_mytest_module_ctx =
{
    NULL,                              /* preconfiguration */
    NULL,                  		/* postconfiguration */

    NULL,                              /* create main configuration */
    NULL,                              /* init main configuration */

    NULL,                              /* create server configuration */
    NULL,                              /* merge server configuration */

    ngx_http_mytest_create_loc_conf,       			/* create location configuration */
    ngx_http_mytest_merge_loc_conf         			/* merge location configuration */
};

```


2. **设置upstream配置项**

每一个HTTP请求都会有一个独立的ngx_http_upstream_conf_t结构体。出于简单考虑，这里将所有的HTTP请求共享一个ngx_http_upstream_conf_t，因此，结合nginx.conf中对于mytest配置项解析的流程，定义mytest的配置项存储结构：
```c
//ngx_http_mytest_conf_t为mytest配置项存储
typedef struct
{	//将conf直接使用配置项存储
    ngx_http_upstream_conf_t upstream;
} ngx_http_mytest_conf_t;
```
相应的，通过实现create_loc_conf回调来**初始化**参数值：
```c
static void* ngx_http_mytest_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_mytest_conf_t  *mycf;
	//初始化mytest的配置项存储
    mycf = (ngx_http_mytest_conf_t  *)ngx_pcalloc(cf->pool, sizeof(ngx_http_mytest_conf_t));
	...
    //以下简单的硬编码ngx_http_upstream_conf_t结构中的各成员，例如
	//超时时间都设为1分钟。这也是http反向代理模块的默认值
    mycf->upstream.connect_timeout = 60000;
    mycf->upstream.send_timeout = 60000;
    mycf->upstream.read_timeout = 60000;
    mycf->upstream.store_access = 0600;
	//buffering=0，说明使用固定大小的内存作为缓冲区来转发上游的响应包体
    mycf->upstream.buffering = 0;
	//如果buffering为1就会使用更多的内存缓存来不及发往下游的响应
	//其配置如下，比如最多使用bufs.num个，每个缓冲区大小为bufs.size，另外还会使用临时文件，临时文件的最大长度为max_temp_file_size
    mycf->upstream.bufs.num = 8;
    mycf->upstream.bufs.size = ngx_pagesize;
    mycf->upstream.buffer_size = ngx_pagesize;
    mycf->upstream.busy_buffers_size = 2 * ngx_pagesize;
    mycf->upstream.temp_file_write_size = 2 * ngx_pagesize;
    mycf->upstream.max_temp_file_size = 1024 * 1024 * 1024;

    //upstream模块要求hide_headers成员必须要初始化（upstream在解析
	//完上游服务器返回的包头时，会调用
	//ngx_http_upstream_process_headers方法按照hide_headers成员将
	//本应转发给下游的一些http头部隐藏），这里将它赋为
	//NGX_CONF_UNSET_PTR ，是为了在merge合并配置项方法中使用
	//upstream模块提供的ngx_http_upstream_hide_headers_hash
	//方法初始化hide_headers 成员
    mycf->upstream.hide_headers = NGX_CONF_UNSET_PTR;
    mycf->upstream.pass_headers = NGX_CONF_UNSET_PTR;

    return mycf;
}
```
nginx的hide_headers成员不能为NULL，必须初始化，且nginx提供了ngx_http_upstream_hide_headers_hash方法，但只能在merge中使用“
```c
static char *ngx_http_mytest_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_mytest_conf_t *prev = (ngx_http_mytest_conf_t *)parent;
    ngx_http_mytest_conf_t *conf = (ngx_http_mytest_conf_t *)child;

    ngx_hash_init_t             hash;
    hash.max_size = 100;
    hash.bucket_size = 1024;
    hash.name = "proxy_headers_hash";
    if (ngx_http_upstream_hide_headers_hash(cf, &conf->upstream,
                                            &prev->upstream, ngx_http_proxy_hide_headers, &hash)
        != NGX_OK){
        return NGX_CONF_ERROR;
    }
    return NGX_CONF_OK;
}
```

3. **设置请求上下文**

nginx中，对于请求的操作是异步的，所以一个请求不会在epoll的一次调度中处理完成，换句话说，需要有一个*变量*来保存每个HTTP模块对于请求的处理状态信息：nginx处理某请求时，将信息写入该变量，当nginx处理其他请求时，把之前的信息存储。当nginx回过头再次调用时，从该变量中取出上一次处理的状态。

与上下文相关的宏定义有：
```c
//定义位于ngx_http.h中

//从请求r中返回模块module的上下文，其中r为ngx_http_request的指针，module为HTTP的模块对象
#define ngx_http_get_module_ctx(r, module)  (r)->ctx[module.ctx_index]
//将上下文写入请求中，其中r为ngx_http_request的指针，c为上下文结构体的指针，module为HTTP模块
#define ngx_http_set_ctx(r, c, module)      r->ctx[module.ctx_index] = c;
```
nginx对于上下文的定义如下：
```c
struct ngx_http_request_s {
	...
	//一个指向void*指针的指针数组，保存所有HTTP模块上下文结构体
	void **ctx;
	...
};
```
因此，设置upstream相关上下文：
```c
//上下文解析定义如下
typedef struct{
	//ngx_http_status_t为nginx提供，可用于解析HTTP响应行
    ngx_http_status_t           status;
    ngx_str_t					backendServer;
} ngx_http_mytest_ctx_t;
```


4. **启动upstream**

当nginx接收到客户端的请求后，会根据请求url匹配到HTTP模块内具体的某个location。根据demo场景，当配置项为mytest时，将由mytest模块来处理业务。因此。启动upstream的时机将由配置项解析函数完成：
```c
//commands定义
static ngx_command_t  ngx_http_mytest_commands[] ={
	{
		//set方法，执行配置项的解析
        ngx_http_mytest,
        ....
    },
    ngx_null_command
};
//set方法定义
static char *ngx_http_mytest(ngx_conf_t *cf, ngx_command_t *cmd, void *conf){
    ngx_http_core_loc_conf_t  *clcf;

	//这里注意，ngx_http_conf_get_module_loc_conf的宏定义如下：
	//#define ngx_http_conf_get_module_loc_conf(cf, module) ((ngx_http_conf_ctx_t *) cf->ctx)->loc_conf[module.ctx_index]  
	//结合nginx的conf解析笔记，可以看到，其实现即为从ngx_http_conf_ctx_t中，取出对应模块的loc_conf数据
	//所以，此处为获取ngx_http_core_module模块的loc_conf数据
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);

    //http框架在处理用户请求进行到NGX_HTTP_CONTENT_PHASE阶段时，如果
	//请求的主机域名、URI与mytest配置项所在的配置块相匹配，就将调用我们
	//实现的ngx_http_mytest_handler方法处理这个请求
    clcf->handler = ngx_http_mytest_handler;

    return NGX_CONF_OK;
}
```
在介绍handler方法之前，首先看下**nginx接收客户端请求以及构造upstream，创建访问第三方请求的步骤**：

1) nginx主循环定期调用事件模块，检查是否有网络事件
2) 接收到HTTP请求后，调用HTTP框架处理。此时比如匹配到了location块，发现其中有mytest配置项，则交给mytest模块。
**3) 调用mytest的配置项解析函数(即handler方法)，设置upstram限制参数、回调函数(process_header等)与第三方的服务地址(resolved)**
**4) 调用ngx_http_upstream_init启动upstream**
5) 如果使用了反向代理文件缓存，则检查，如果有合适响应包，则返回；如果没有，继续。
6) 回调mytest的create_request方法
7) mytest设置r->upstream->request_bufs确定要发送给上游服务器的具体信息
8) upstream模块检查resolved成员，设置上游服务器的地址r->upstream->peer。
9) 使用无阻塞方法connect建立TCP套接字连接，建立后即可返回
10) ngx_http_upstream_init返回
11) mytest模块的ngx_http_mytest_handler返回NGX_DONE
12) 事件模块处理完该网络事件后，控制权交还给nginx主循环。

以上步骤由2个部分，1是解析配置项，设置限制参数、回调、resolverd等，2是构造请求。其中1的工作即由handler实现：
```c
//handler方法
static ngx_int_t ngx_http_mytest_handler(ngx_http_request_t *r){
    //首先建立ngx_http_mytest_module的上下文myctx
	ngx_http_mytest_ctx_t* myctx = ngx_http_get_module_ctx(r, ngx_http_mytest_module);
    if (myctx == NULL)
    {
        myctx = ngx_palloc(r->pool, sizeof(ngx_http_mytest_ctx_t));
        if (myctx == NULL)
        {
            return NGX_ERROR;
        }
        //将新建的上下文写入请求的ngx_http_mytest_module模块
        ngx_http_set_ctx(r, myctx, ngx_http_mytest_module);
    }
    //对每1个要使用upstream的请求，必须调用且只能调用1次
	//ngx_http_upstream_create方法，它会初始化r->upstream成员
    if (ngx_http_upstream_create(r) != NGX_OK){
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0, "ngx_http_upstream_create() failed");
        return NGX_ERROR;
    }

	//1. 设置upstream的限制参数
	
    //宏定义为：#define ngx_http_get_module_loc_conf(r, module)  (r)->loc_conf[module.ctx_index] 
	//ngx_http_request_t中保存了模块所对应的上下文结构体指针：
	/* struct  ngx_http_request_s  {
	 *	...
	 *	以下四个保存的是模块所对应的上下文结构体的指针。
	 *	其中ctx对应于自定义的上下文结构体指针
	 *	main_conf对应于main的上下文结构体指针
	 *	loc_conf对应于loc的上下文结构体指针
	 *	src_conf对应于srv的上下文结构体指针
     *  void                             **  ctx ;
     *  void                             **  main_conf ;
     *  void                             **  srv_conf ;
     *  void                             **  loc_conf ;
	 */	
	 //故http根据nginx对于配置项的解析，在调用handler时已扫描到了具体的块(http/server/location)，
	 //从对应的ngx_http_conf_ctx_t取出ngx_http_mytest_module模块的loc_conf配置项，也就是由ngx_http_mytest_create_loc_conf创建的配置项
    ngx_http_mytest_conf_t  *mycf = (ngx_http_mytest_conf_t  *) ngx_http_get_module_loc_conf(r, ngx_http_mytest_module);
    ngx_http_upstream_t *u = r->upstream;
    //这里用配置文件中的结构体来赋给r->upstream->conf成员
    u->conf = &mycf->upstream;
    //决定转发包体时使用的缓冲区
    u->buffering = mycf->upstream.buffering;

    //2. 设置resolved
	//初始化resolved结构体，用来保存上游服务器的地址
    u->resolved = (ngx_http_upstream_resolved_t*) ngx_pcalloc(r->pool, sizeof(ngx_http_upstream_resolved_t));
    ...
    //这里的上游服务器就是www.baidu.com
    static struct sockaddr_in backendSockAddr;
    struct hostent *pHost = gethostbyname((char*) "www.baidu.com");
    ...

    //访问上游服务器的80端口
    backendSockAddr.sin_family = AF_INET;
    backendSockAddr.sin_port = htons((in_port_t) 80);
    char* pDmsIP = inet_ntoa(*(struct in_addr*) (pHost->h_addr_list[0]));
    backendSockAddr.sin_addr.s_addr = inet_addr(pDmsIP);
    myctx->backendServer.data = (u_char*)pDmsIP;
    myctx->backendServer.len = strlen(pDmsIP);

    //将地址设置到resolved成员中
    u->resolved->sockaddr = (struct sockaddr *)&backendSockAddr;
    u->resolved->socklen = sizeof(struct sockaddr_in);
    u->resolved->naddrs = 1;

    //3. 设置三个必须实现的回调方法
    u->create_request = mytest_upstream_create_request;
    u->process_header = mytest_process_status_line;
    u->finalize_request = mytest_upstream_finalize_request;

    //这里必须将count成员加1，理由见5.1.5节
    r->main->count++;
    //启动upstream
    ngx_http_upstream_init(r);
    //必须返回NGX_DONE
    return NGX_DONE;
}
```
下面，看下几个回调函数的实现：

 1. **create_request**
	
根据上节的创建upstream请求，create_request接下来的工作主要为设置r->upstream->request_bufs，来确定发送什么样的请求到上游服务器。
```c
static ngx_int_t mytest_upstream_create_request(ngx_http_request_t *r){
    //发往www.baidu上游服务器的请求很简单，就是模仿正常的搜索请求，
	//以/s?wd=…的URL来发起搜索请求。backendQueryLine中的%V等转化
	//格式的用法，请参见4.4节中的表4-7
    static ngx_str_t backendQueryLine =
        ngx_string("GET /s?wd=%V HTTP/1.1\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n");
    ngx_int_t queryLineLen = backendQueryLine.len + r->args.len - 2;
    
	//必须从内存池中申请内存，这有两点好处：
	//1. 在网络情况不佳的情况下，向上游服务器发送请求时，可能需要epoll多次调度send发送才能完成，这时必须保证这段内存不会被释放；
	//2. 请求结束时，这段内存会被自动释放，降低内存泄漏的可能
    ngx_buf_t* b = ngx_create_temp_buf(r->pool, queryLineLen);
    if (b == NULL) return NGX_ERROR;
	
    //last要指向请求的末尾
    b->last = b->pos + queryLineLen;

    //格式话字符串，backendQueryLine是fmt，r->args是参数，将其写入b->pos
    ngx_snprintf(b->pos, queryLineLen ,
                 (char*)backendQueryLine.data, &r->args);
				 
    // r->upstream->request_bufs是一个ngx_chain_t结构，它包含着要发送给上游服务器的请求
    r->upstream->request_bufs = ngx_alloc_chain_link(r->pool);
    if (r->upstream->request_bufs == NULL)
        return NGX_ERROR;

    // request_bufs这里只包含1个ngx_buf_t缓冲区
    r->upstream->request_bufs->buf = b;
    r->upstream->request_bufs->next = NULL;

    r->upstream->request_sent = 0;
    r->upstream->header_sent = 0;
    // header_hash不可以为0
    r->header_hash = 1;
    return NGX_OK;
}
```

 2. **process_header**

第2个必须实现的回调为process_header函数。它负责解析上游服务器响应的基于TCP的包头，即HTTP的响应行(主要描述HTTP协议版本、状态码)和HHTP头信息。

其中，解析HTTP响应行使用`mytest_process_status_line`方法，解析HTTP响应头使用`mytest_upstream_process_header`。使用两个函数的其原因在于HTTP的响应行和响应头都是不定长的。当nginx接收到TCP流后，通过回调**从上下文中**判断是否接收完成，如果返回NGX_AGAIN，则需要继续。
	
其流程如下：

1) nginx主循环定期调用事件模块，检查是否有网络事件
2) 接收上游服务器的响应后，调用upstream模块处理。后者从套接字缓冲区中读取来自上游的TCP流。
3) 将响应放到r->upstream->buffer指向的内存（即使多次接收TCP流，其上游的响应都会存放到r->upstream->buffer缓冲区中，因此，如果precess_header返回NGX_AGAIN而缓冲区满，则报错）
4) 回调mytest的process_header方法
5) process_header的工作为解析r->upstream->buffer缓冲区，试图读取完整的响应头部(即HTTP头)
6) 如果返回NGX_AGAIN，表示还没有解析到完整的响应头，会继续调用process_header处理
7) upstream模块调用无阻塞的读取套接字接口，如果有值，转3）; 如果为空，说明响应事件处理完毕。
8) 控制权交还给事件模块，处理完本轮网络事件，控制权交还给nginx主循环。

其代码实现如下：

- **mytest_process_status_line**

```c
static	ngx_int_t	mytest_process_status_line(ngx_http_request_t *r){
    size_t                 len;
    ngx_int_t              rc;
    ngx_http_upstream_t   *u;

    //上下文中才会保存多次解析http响应行的状态，首先取出请求的上下文
	//ngx_http_get_module_ctx为获取ngx_http_mytest_module的上下文
	//这里有个疑问，ngx_http_mytest_module中的ctx为ngx_http_mytest_module_ctx，但是返回的ctx是ngx_http_mytest_ctx_t？
    ngx_http_mytest_ctx_t* ctx = ngx_http_get_module_ctx(r, ngx_http_mytest_module);
    if (ctx == NULL){
        return NGX_ERROR;
    }

    u = r->upstream;

    //http框架提供的ngx_http_parse_status_line方法可以解析http响应行，它的输入就是收到的字符流和上下文中的ngx_http_status_t结构
    rc = ngx_http_parse_status_line(r, &u->buffer, &ctx->status);
    //返回NGX_AGAIN表示还没有解析出完整的http响应行，需要接收更多的字符流再来解析
    if (rc == NGX_AGAIN){
        return rc;
    }
    //返回NGX_ERROR则没有接收到合法的http响应行
    if (rc == NGX_ERROR){
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "upstream sent no valid HTTP/1.0 header");

        r->http_version = NGX_HTTP_VERSION_9;
        u->state->status = NGX_HTTP_OK;

        return NGX_OK;
    }

    //当解析到完整的http响应行时，将解析出的信息设置到r->upstream->headers_in结构体中
	//upstream解析完所有的包头时，就会把headers_in中的成员设置到将要向下游发送的r->headers_out结构体中，
	//也就是说，现在我们向headers_in中设置的信息，最终都会发往下游客户端。
	
	//为什么不是直接设置r->headers_out而要这样多此一举呢？这是因为upstream希望能够按照
	//ngx_http_upstream_conf_t配置结构体中的hide_headers等成员对发往下游的响应头部做统一处理
    if (u->state){
        u->state->status = ctx->status.code;
    }

    u->headers_in.status_n = ctx->status.code;

    len = ctx->status.end - ctx->status.start;
    u->headers_in.status_line.len = len;

    u->headers_in.status_line.data = ngx_pnalloc(r->pool, len);
    if (u->headers_in.status_line.data == NULL){
        return NGX_ERROR;
    }
	
    ngx_memcpy(u->headers_in.status_line.data, ctx->status.start, len);

    //解析http头部，设置process_header回调方法为mytest_upstream_process_header，
	//之后再收到的新字符流将由mytest_upstream_process_header解析
    u->process_header = mytest_upstream_process_header;

    //如果本次收到的字符流除了http响应行外，还有多余的字符，将由mytest_upstream_process_header方法解析
    return mytest_upstream_process_header(r);
}
```

- **mytest_upstream_process_header**

```c
static ngx_int_t
mytest_upstream_process_header(ngx_http_request_t *r)
{
    ngx_int_t                       rc;
    ngx_table_elt_t                *h;
    ngx_http_upstream_header_t     *hh;
    ngx_http_upstream_main_conf_t  *umcf;

	//#define ngx_http_get_module_main_conf(r, module) ，根据request和upstream模块得到main配置
	//此处返回ngx_http_upstream_main_conf_t，该结构体中存储了需要做统一处理的http头部名称和回调方法
    umcf = ngx_http_get_module_main_conf(r, ngx_http_upstream_module);

    //对将要转发给下游客户端的http响应头部作统一处理。
    for ( ;; ){
        // http框架提供了基础性的ngx_http_parse_header_line方法，它用于解析http头部
        rc = ngx_http_parse_header_line(r, &r->upstream->buffer, 1);
        //返回NGX_OK表示解析出一行http头部
        if (rc == NGX_OK){
            //向headers_in.headers这个ngx_list_t链表中添加http头部
			//函数ngx_list_push返回值为可添加元素的地址,入参为链表r->upstream->headers_in.headers
            h = ngx_list_push(&r->upstream->headers_in.headers);
            //...err handle
			//添加HTTP头，以下开始构造刚刚添加到headers链表中的http头部
            h->hash = r->header_hash;

            h->key.len = r->header_name_end - r->header_name_start;
            h->value.len = r->header_end - r->header_start;
            //必须由内存池中分配存放http头部的内存
            h->key.data = ngx_pnalloc(r->pool, h->key.len + 1 + h->value.len + 1 + h->key.len);
            //...err handle
            h->value.data = h->key.data + h->key.len + 1;
            h->lowcase_key = h->key.data + h->key.len + 1 + h->value.len + 1;

            ngx_memcpy(h->key.data, r->header_name_start, h->key.len);
            h->key.data[h->key.len] = '\0';
            ngx_memcpy(h->value.data, r->header_start, h->value.len);
            h->value.data[h->value.len] = '\0';

            if (h->key.len == r->lowcase_index){
                ngx_memcpy(h->lowcase_key, r->lowcase_header, h->key.len);
            }else{
                ngx_strlow(h->lowcase_key, h->key.data, h->key.len);
            }

            //upstream模块会对一些http头部做特殊处理
            hh = ngx_hash_find(&umcf->headers_in_hash, h->hash,
                               h->lowcase_key, h->key.len);

            if (hh && hh->handler(r, h, hh->offset) != NGX_OK){
                return NGX_ERROR;
            }
            continue;
        }

        //返回NGX_HTTP_PARSE_HEADER_DONE表示响应中所有的http头部都解析完毕，接下来再接收到的都将是http包体
        if (rc == NGX_HTTP_PARSE_HEADER_DONE){
            //如果之前解析http头部时没有发现server和date头部，以下会根据http协议添加这两个头部
            if (r->upstream->headers_in.server == NULL){
                h = ngx_list_push(&r->upstream->headers_in.headers);
                ...
                h->hash = ngx_hash(ngx_hash(ngx_hash(ngx_hash(ngx_hash('s', 'e'), 'r'), 'v'), 'e'), 'r');
                ngx_str_set(&h->key, "Server");
                ngx_str_null(&h->value);
                h->lowcase_key = (u_char *) "server";
            }

            if (r->upstream->headers_in.date == NULL){
                h = ngx_list_push(&r->upstream->headers_in.headers);
                ...
                h->hash = ngx_hash(ngx_hash(ngx_hash('d', 'a'), 't'), 'e');
                ngx_str_set(&h->key, "Date");
                ngx_str_null(&h->value);
                h->lowcase_key = (u_char *) "date";
            }
            return NGX_OK;
        }

        //如果返回NGX_AGAIN则表示状态机还没有解析到完整的http头部，要求upstream模块继续接收新的字符流再交由process_header回调方法解析
        if (rc == NGX_AGAIN)
        {
            return NGX_AGAIN;
        }

        //其他返回值都是非法的
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "upstream sent invalid header");
        return NGX_HTTP_UPSTREAM_INVALID_HEADER;
    }
}
```

 3. **finalize_request**
  当调用ngx_http_upstream_init启动upstream后，因各种原因导致的请求被销毁前都会调用finalize_request方法。finalize_request方法可以释放我们希望释放的资源，比如打开的句柄等。如果没有资源需要释放，记录日志即可：
```c
static void mytest_upstream_finalize_request(ngx_http_request_t *r, ngx_int_t rc){
    ngx_log_error(NGX_LOG_DEBUG, r->connection->log, 0,
                  "mytest_upstream_finalize_request");
}
```

 4. **其他回调**
	
  其他的回调包括了`reinit_request/rewrite_redirect`，此处略过。



 






