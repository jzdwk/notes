# HTTP 过滤模块开发

## 与HTTP模块的关系

HTTP模块更倾向于完成一个请求的核心功能，过滤模块则处理一些附加功能。当普通HTTP模块调用`ngx_http_send_header`发送HTTP头部，或者`ngx_http_output_filter`发送HTTP包体时，才会由这两个方法**依次调用所有的HTTP过滤模块**来处理请求。因此，HTTP过滤模块**只处理服务器发往客户端的响应，而不处理客户端发往服务器的请求**。

## 数据结构

1. **2种过滤**

从功能上，nginx将HTTP响应分为了2个部分：HTTP头与HTTP包。因此，过滤模块也分别对头过滤与包体过滤进行了相应的定义：
```c
//定义位于ngx_http_core_module.h中

//请求头过滤模块，参数r为当前请求
typedef ngx_int_t (*ngx_http_output_header_filter_pt)(ngx_http_request_t *r);
//请求包体过滤模块，参数r为当前请求，chain为要发送的HTTP包体
typedef ngx_int_t (*ngx_http_output_body_filter_pt)(ngx_http_request_t *r, ngx_chain_t *chain);
```
所有的HTTP模块都需要实现以上2个，或者其中1个方法(取决于过滤的目标)。

2. **链表结构**

上节说的*依次调用*，说明过滤模块组成了一个**过滤链**，有点像设计模式中的责任链，其组成为一个单向链表，而链表元素指针指向了每个过滤模块的核心实现(这个核心实现即上文中需要实现那两个方法)，链表间通过next指针项链。每当添加一个新的过滤模块到链表是，都使用**头插法**进行操作。当然，这里会有两个链表，即头过滤链表与包过滤链表，nginx分别在发送响应头与响应包体的函数中调用：
```c
ngx_int_t ngx_http_send_header(ngx_http_request_t *r){
	//...
	return ngx_http_top_header_filter(r);
}
ngx_int_t ngx_http_output_filter(ngx_http_request_t *r, ngx_chain_t *in){
	//...
	rc = ngx_http_top_body_filter(r,in);
	//..
	return rc;
}
```
3. **链表操作**

以内置过滤模块`ngx_http_chunked_filter_module.c`的实现为例，将其添加入过滤链的操作如下：
```c
//定义两个方法的next指针
static ngx_http_output_header_filter_pt  ngx_http_next_header_filter;
static ngx_http_output_body_filter_pt    ngx_http_next_body_filter;

static ngx_int_t ngx_http_chunked_header_filter(ngx_http_request_t *r){...}
static ngx_int_t ngx_http_chunked_body_filter(ngx_http_request_t *r, ngx_chain_t *in){...}

//头插法的操作
static ngx_int_t ngx_http_chunked_filter_init(ngx_conf_t *cf){
	//保存目前链表的头指针给next指针，因此每个模块的next指针都指向了原模块的头指针，而自己则位于链表的头部
    ngx_http_next_header_filter = ngx_http_top_header_filter;
	//将链表头指针指向当前模块的实现
    ngx_http_top_header_filter = ngx_http_chunked_header_filter;
	
	//同上
    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_chunked_body_filter;

    return NGX_OK;
}
```
4. **链表顺序**

HTTP过滤模块的顺序也是由configure命令生成的，保存在ngx_module.c文件中。对于官方提供的过滤模块，configure则从nginx安装包的auto目录下的modules脚本中读取顺序：
```
[root@VM-24-5-centos auto]# pwd
/root/nginx/nginx-1.20.1/auto
...
    ngx_module_order="ngx_http_static_module \
                      ngx_http_gzip_static_module \
                      ngx_http_dav_module \
                      ngx_http_autoindex_module \
                      ngx_http_index_module \
                      ngx_http_random_index_module \
                      ngx_http_access_module \
                      ngx_http_realip_module \
                      ngx_http_write_filter_module \
                      ngx_http_header_filter_module \
                      ngx_http_chunked_filter_module \
                      ngx_http_v2_filter_module \
                      ngx_http_range_header_filter_module \
                      ngx_http_gzip_filter_module \
                      ngx_http_postpone_filter_module \
                      ngx_http_ssi_filter_module \
                      ngx_http_charset_filter_module \
                      ngx_http_xslt_filter_module \
                      ngx_http_image_filter_module \
                      ngx_http_sub_filter_module \
                      ngx_http_addition_filter_module \
                      ngx_http_gunzip_filter_module \
                      ngx_http_userid_filter_module \
                      ngx_http_headers_filter_module \
                      ngx_http_copy_filter_module \
                      ngx_http_range_body_filter_module \
                      ngx_http_not_modified_filter_module \
                      ngx_http_slice_filter_module"
...
```
而第三方模块则位于`ngx_http_headers_filter_module`与`ngx_http_userid_filter_module`之间。
```c
ngx_http_headers_filter_module  -> 第三方模块 -> ngx_http_userid_filter_module`
```
另外需要说明，因为链表为头插法，所以，在顺序定义上**越靠后的模块，在实际执行时则约靠前**。

## 开发示例

示例的场景为：用户请求一个位于服务器的静态文件，nginx接收后通过静态文件模块处理，并将文件返回给用户。通过自定义的过滤模块，在其响应包体前增加一段字符串`[my filter prefix]`
这里需要注意，当返回的HTTP头中`Content-Type`为文件类型后，才会对返回包体进行处理。
其nginx.conf文件内容大致为：
```c
#user  nobody;
worker_processes  1;

error_log  logs/error.log  debug;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    #log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
    #                  '$status $body_bytes_sent "$http_referer" '
    #                  '"$http_user_agent" "$http_x_forwarded_for"';

    #access_log  logs/access.log  main;

    keepalive_timeout  65;

    server {
    	listen 8080;

		location / {
			root /;
			add_prefix on;
		}
    }
}

```

1. **模块源码文件**

源码文件名称为`ngx_http_xxx_module.c`，这里定义`ngx_http_myfilter_module.c`

2. **config脚本**

创建config文件:
```c
ngx_addon_name=ngx_http_myfilter_module

HTTP_FILTER_MODULES="$HTTP_FILTER_MODULES ngx_http_myfilter_module"
NGX_ADDON_SRCS="$NGX_ADDON_SRCS $ngx_addon_dir/ngx_http_myfilter_module.c"
```

3. **配置项数据结构**
```c
//配置项的数据结构存储
typedef struct{
    ngx_flag_t		enable;
} ngx_http_myfilter_conf_t;

//上下文数据结构
typedef struct{
    ngx_int_t   	add_prefix;
} ngx_http_myfilter_ctx_t;

```
4. **HTTP模块三板斧**

定义ngx_module_t、ngx_http_module_t、ngx_command_t：
```c
//command定义，解析add_prefix配置项
static ngx_command_t  ngx_http_myfilter_commands[] ={
    {
        ngx_string("add_prefix"),
        NGX_HTTP_MAIN_CONF | NGX_HTTP_SRV_CONF | NGX_HTTP_LOC_CONF | NGX_HTTP_LMT_CONF | NGX_CONF_FLAG,
        ngx_conf_set_flag_slot,	//因为配置项的值为on/off，所以直接使用预定义的宏
        NGX_HTTP_LOC_CONF_OFFSET,
        offsetof(ngx_http_myfilter_conf_t, enable),
        NULL
    },

    ngx_null_command
};

//ngx_http_module_t定义
static ngx_http_module_t  ngx_http_myfilter_module_ctx ={
    NULL,                                  /* preconfiguration方法  */
	//注意，这里实现了模块的init方法，主要作用是使用头插法更新过滤模块链表
    ngx_http_myfilter_init,            /* postconfiguration方法 */

    NULL,                                  /*create_main_conf 方法 */
    NULL,                                  /* init_main_conf方法 */

    NULL,                                  /* create_srv_conf方法 */
    NULL,                                  /* merge_srv_conf方法 */
	//配置项初始化与merge
    ngx_http_myfilter_create_conf,    /* create_loc_conf方法 */
    ngx_http_myfilter_merge_conf      /*merge_loc_conf方法*/
};

//ngx_module_t模块定义，依旧属于NGX_HTTP_MODULE模块
ngx_module_t  ngx_http_myfilter_module ={
    NGX_MODULE_V1,
    &ngx_http_myfilter_module_ctx,     /* module context */
    ngx_http_myfilter_commands,        /* module directives */
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

//create_conf与merge_conf的实现，没啥说的
static void* ngx_http_myfilter_create_conf(ngx_conf_t *cf){
    ngx_http_myfilter_conf_t  *mycf;
    //创建存储配置项的结构体
    mycf = (ngx_http_myfilter_conf_t  *)ngx_pcalloc(cf->pool, sizeof(ngx_http_myfilter_conf_t));
    ...
    //ngx_flat_t类型的变量，如果使用预设函数ngx_conf_set_flag_slot解析配置项参数，必须初始化为NGX_CONF_UNSET
    mycf->enable = NGX_CONF_UNSET;
    return mycf;
}

static char * ngx_http_myfilter_merge_conf(ngx_conf_t *cf, void *parent, void *child){
    ngx_http_myfilter_conf_t *prev = (ngx_http_myfilter_conf_t *)parent;
    ngx_http_myfilter_conf_t *conf = (ngx_http_myfilter_conf_t *)child;
	//合并ngx_flat_t类型的配置项enable
    ngx_conf_merge_value(conf->enable, prev->enable, 0);
    return NGX_CONF_OK;
}

```
5. **实现初始化方法**

初始化方法被引用在ngx_http_module_t中的postconfiguration回调函数，用于向过滤链表中加入ngx_http_myfilter_header_filter
```c
static ngx_http_output_header_filter_pt ngx_http_next_header_filter;
static ngx_http_output_body_filter_pt    ngx_http_next_body_filter;


static ngx_int_t ngx_http_myfilter_init(ngx_conf_t *cf){
    //插入到头部处理方法链表的首部
    ngx_http_next_header_filter = ngx_http_top_header_filter;
    ngx_http_top_header_filter = ngx_http_myfilter_header_filter;

    //插入到包体处理方法链表的首部
    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_myfilter_body_filter;

    return NGX_OK;
}
```

6. **处理http头部方法**

唯一需要注意的两点是：
- 判断该模块是否已经执行
- 只处理Content-Type是"text/plain"类型的http响应并修改Content-Length

```c
//预定义要处理的字符串
static ngx_str_t filter_prefix = ngx_string("[my filter prefix]");

//http头过滤函数实现
static ngx_int_t ngx_http_myfilter_header_filter(ngx_http_request_t *r){
    ngx_http_myfilter_ctx_t   *ctx;
    ngx_http_myfilter_conf_t  *conf;

    //如果不是返回成功，这时是不需要理会是否加前缀的，直接交由下一个过滤模块处理响应码非200的情形
    if (r->headers_out.status != NGX_HTTP_OK){
        return ngx_http_next_header_filter(r);
    }
	
	//获取http上下文
    ctx = ngx_http_get_module_ctx(r, ngx_http_myfilter_module);
    if (ctx){
        //该请求的上下文已经存在，这说明ngx_http_myfilter_header_filter已经被调用过1次，直接交由下一个过滤模块处理
        return ngx_http_next_header_filter(r);
    }

	//获取存储配置项的ngx_http_myfilter_conf_t结构体
    conf = ngx_http_get_module_loc_conf(r, ngx_http_myfilter_module);

	//如果enable成员为0，也就是配置文件中没有配置add_prefix配置项，或者add_prefix配置项的参数值是off，这时直接交由下一个过滤模块处理
    if (conf->enable == 0){
        return ngx_http_next_header_filter(r);
    }

	//构造http上下文结构体ngx_http_myfilter_ctx_t
    ctx = ngx_pcalloc(r->pool, sizeof(ngx_http_myfilter_ctx_t));
    ...

	//add_prefix为0表示不加前缀
    ctx->add_prefix = 0;

	//将构造的上下文设置到当前请求中
    ngx_http_set_ctx(r, ctx, ngx_http_myfilter_module);

	//myfilter过滤模块只处理Content-Type是"text/plain"类型的http响应
    if (r->headers_out.content_type.len >= sizeof("text/plain") - 1
        && ngx_strncasecmp(r->headers_out.content_type.data, (u_char *) "text/plain", sizeof("text/plain") - 1) == 0){
        //1表示需要在http包体前加入前缀
        ctx->add_prefix = 1;
		//如果处理模块已经在Content-Length写入了http包体的长度，由于我们需要在包体加入filter_prefix定义的字符串，所以需要把这个字符串的长度也加入到Content-Length中
        if (r->headers_out.content_length_n > 0)
            r->headers_out.content_length_n += filter_prefix.len;
    }

	//交由下一个过滤模块继续处理
    return ngx_http_next_header_filter(r);
}
```
7. **处理http包体方法**

包体的数据结构为ngx_chain_t，因此需要将filter_prefix字符串创建为ngx_chain_t后加入原来的响应链表：
```c
static ngx_int_t ngx_http_myfilter_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    ngx_http_myfilter_ctx_t   *ctx;
    ctx = ngx_http_get_module_ctx(r, ngx_http_myfilter_module);
	//如果获取不到上下文，或者上下文结构体中的add_prefix为0或不为1时，说明已经执行过过滤，则都不会添加前缀，这时直接交给下一个http过滤模块处理
    if (ctx == NULL || ctx->add_prefix != 1){
        return ngx_http_next_body_filter(r, in);
    }

	//将add_prefix设置为2，这样即使ngx_http_myfilter_body_filter再次回调时，也不会重复添加前缀
    ctx->add_prefix = 2;

	//从请求的内存池中分配内存，用于存储字符串前缀
    ngx_buf_t* b = ngx_create_temp_buf(r->pool, filter_prefix.len);
	//将ngx_buf_t中的指针正确地指向filter_prefix字符串
    b->start = b->pos = filter_prefix.data;
    b->last = b->pos + filter_prefix.len;

	//从请求的内存池中生成ngx_chain_t链表，将刚分配的ngx_buf_t设置到其buf成员中，并将它添加到原先待发送的http包体前面
    ngx_chain_t *cl = ngx_alloc_chain_link(r->pool);
    cl->buf = b;
    cl->next = in;

	//调用下一个模块的http包体处理方法，注意这时传入的是新生成的cl链表
    return ngx_http_next_body_filter(r, cl);
}
```

8. **编译安装**

```
./configure --add-module=/模块路径
make
make install
```

