# nginx架构

nginx架构概述笔记

## 模块化设计

nginx最核心的数据结构`ngx_moudle_t`诠释了模块化的设计思路，回顾[nginx-src-http-moudle-dev.md](./nginx-src-http-moudle-dev.md)：
```c
struct ngx_module_s {
    //..这里只关注模块化相关内容	
	
	/* ctx为ngx_module_s与各个模块的纽带，也可以说是具体模块的公共接口。
     * 下文中我们会以核心模块为例说明下这个字段 */
    void                 *ctx;

    ngx_command_t        *commands;   // 模块支持的指令集，数组形式，最后用空对象表示结束
	
	/* 模块的类型标识，可选值如下
     * #define NGX_CORE_MODULE      0x45524F43  核心模块 
     * #define NGX_CONF_MODULE      0x464E4F43  配置模块 
     * #define NGX_EVENT_MODULE     0x544E5645  event模块 
     * #define NGX_HTTP_MODULE      0x50545448  http模块 
     * #define NGX_MAIL_MODULE      0x4C49414D  mail模块 
    */  
    ngx_uint_t            type; 
  
    //...
};
```
上面定义了**5种类型**的模块，每一种
1. **配置类型模块**
nginx配置类型的模块只有唯一一个，定义在`/src/core/ngx_conf_file.c`
```c
//ngx_module_t类型的ngx_conf_module，ctx为NULL
ngx_module_t  ngx_conf_module = {
    NGX_MODULE_V1,
    NULL,                                  /* module context */
    ngx_conf_commands,                     /* module directives */
    NGX_CONF_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    ngx_conf_flush_files,                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};
```
属于最底层模块，其作用顾名思义，提供配置项相关操作。
	
2. **核心类型模块**

对于核心模块，`ngx_moudle_t`中的ctx指向类型为`ngx_core_module_t`的结构体，其定义：
```c
//位于/src/core/ngx_module.h
typedef struct {
	//核心模块名称
    ngx_str_t             name;
    //解析配置项前，nginx框架调用create_conf创建存储配置项的数据结构
	//并根据ngx_command_t把解析出的配置项存入这个数据结构
	void               *(*create_conf)(ngx_cycle_t *cycle);
	//解析配置项完成后，nginx框架调用init_conf
    char               *(*init_conf)(ngx_cycle_t *cycle, void *conf);
} ngx_core_module_t;
```
目前官方的核心类型模块共有6个模块, 为 `ngx_core_module, ngx_errlog_module, ngx_events_module, ngx_openssl_module, ngx_http_module, ngx_mail_module`。注意，这里的模块均为核心模块，比如`ngx_http_module`，该模块将具体负责解析所有的http module，即ngx_http_moudle_t类型的模块，其定义位于`/src/http/ngx_http.c`：
```c
//command定义，解析http配置项
static ngx_command_t  ngx_http_commands[] = {
 
    { ngx_string("http"),
      NGX_MAIN_CONF|NGX_CONF_BLOCK|NGX_CONF_NOARGS,
      ngx_http_block,
      0,
      0,
      NULL },
 
      ngx_null_command
};
//ngx_core_module_t类型的ctx定义
static ngx_core_module_t  ngx_http_module_ctx = {
    ngx_string("http"),
    NULL,
    NULL
};
//ngx_module_t定义
ngx_module_t  ngx_http_module = {
    NGX_MODULE_V1,
    &ngx_http_module_ctx,                  /* module context */
    ngx_http_commands,                     /* module directives */
    NGX_CORE_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};
```
那么，比如这个`ngx_http_module`与对应的http类型的模块又有啥关系呢？可以看到其command定义中的set方法使用了`ngx_http_block`，该函数为HTTP模块的初始化入口，从代码中可以看到[nginx-src-http-conf.md](./nginx-src-http-conf.md)中描述的解析配置的流程:
```c
/**
 *HTTP模块初始化的入口函数，只简单说明，不具体展开
 */
static char *ngx_http_block(ngx_conf_t *cf, ngx_command_t *cmd, void *conf){
    ...
 
    /* the main http context */
 
    /* 1. 分配一块内存，存放http配置上下文 */
    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_conf_ctx_t));
    ...
    *(ngx_http_conf_ctx_t **) conf = ctx;
    /* count the number of the http modules and set up their indices */
    /* 计算http模块个数 */
    ngx_http_max_module = ngx_count_modules(cf->cycle, NGX_HTTP_MODULE);
    
	//上下文赋值main/sercer/location配置指针
    ctx->main_conf = ngx_pcalloc(cf->pool, sizeof(void *) * ngx_http_max_module);
	...
    ctx->srv_conf = ngx_pcalloc(cf->pool, sizeof(void *) * ngx_http_max_module);
    ...
    ctx->loc_conf = ngx_pcalloc(cf->pool, sizeof(void *) * ngx_http_max_module);
	...
    
    // 3. 依次调用每个http模块的：create_main_conf、create_srv_conf、create_loc_conf创建配置
    for (m = 0; cf->cycle->modules[m]; m++) {
        if (cf->cycle->modules[m]->type != NGX_HTTP_MODULE) {
            continue;
        }
        module = cf->cycle->modules[m]->ctx;
        mi = cf->cycle->modules[m]->ctx_index; 
        if (module->create_main_conf) {
            ...
        } 
        if (module->create_srv_conf) {
            ...
        } 
        if (module->create_loc_conf) {
            ...
        }
    }
 
    pcf = *cf;
    cf->ctx = ctx;
	
    //4. preconfiguration 预先初始化配置信息   
    for (m = 0; cf->cycle->modules[m]; m++) {
        ...
        if (module->preconfiguration) {
           ...
        }
    } 
    ...
}
```
可以看到，核心模块`ngx_http_module`完成了框架性的http模块配置解析与加载。

3. **http类型模块**

各种http模块的具体工作由`ngx_http_module_t`作为`ngx_module_t`的ctx来完成，即笔记中记录的http模块开发那样。那么http模块与核心模块的联系点在哪？

nginx为http模块定义了一个`ngx_http_module_t`类型的`ngx_http_core_module_ctx`，作为http模块中的**核心模块**，根据[nginx-src-http-conf.md](./nginx-src-http-conf.md)中描述的解析配置的流程，在第12步，其工作将交给`ngx_http_core_module_ctx`：
```c
//http core 处理的配置项
static ngx_command_t  ngx_http_core_commands[] = {
    //...具体省略
    { ngx_string("server"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_BLOCK|NGX_CONF_NOARGS,
      ngx_http_core_server,
      0,
      0,
      NULL },
    //...
    { ngx_string("location"),
      NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_BLOCK|NGX_CONF_TAKE12,
      ngx_http_core_location,
      NGX_HTTP_SRV_CONF_OFFSET,
      0,
      NULL },
    //...
    ngx_null_command
};

static ngx_http_module_t  ngx_http_core_module_ctx = {
    ngx_http_core_preconfiguration,        /* preconfiguration */
    ngx_http_core_postconfiguration,       /* postconfiguration */

    ngx_http_core_create_main_conf,        /* create main configuration */
    ngx_http_core_init_main_conf,          /* init main configuration */

    ngx_http_core_create_srv_conf,         /* create server configuration */
    ngx_http_core_merge_srv_conf,          /* merge server configuration */

    ngx_http_core_create_loc_conf,         /* create location configuration */
    ngx_http_core_merge_loc_conf           /* merge location configuration */
};

ngx_module_t  ngx_http_core_module = {
    NGX_MODULE_V1,
    &ngx_http_core_module_ctx,             /* module context */
    ngx_http_core_commands,                /* module directives */
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
```
4. **event类型模块**

与http模块类似，不再赘述

5. **mail类型模块**

与http模块类似，不再赘述


## nginx的异步

## 关键结构体
### ngx_cycle_t
### ngx_listening_t
## work进程
### 信号量
### 主循环
## master进程