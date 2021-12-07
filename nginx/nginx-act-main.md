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
	// 	  cf->cycle即为ngx_cycle_t，将在下文说明
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

与http模块类似，但稍有差别，暂不赘述

5. **mail类型模块**

与http模块类似，不再赘述

## 事件驱动

张三吩咐李四做一件事，这时的场景有三种；
```
1. 李四手里没活在摸鱼，张三把任务交给李四，李四接到后就去忙了。张三在原地等着，直到李四搞完事回来把结果告诉他。
2. 李四手里没活在摸鱼，张三把任务交给李四，顺带告诉自己的手机号，李四接到后就去忙了。张三去忙别的事，李四搞完事打电话给张三，张三回来取结果。
3. 李四在忙别的事，张三有李四的手机号，张三打电话，把任务交给李四，顺带告诉自己的手机号，李四接到后就去忙了。张三去忙别的事，李四搞完事打电话给张三，张三回来取结果。
```
显然，第三种的效率更高，对张三和李四的压榨更狠。这就是`异步与事件驱动`，`事件`就是“打电话做事”，张三与李四都是`事件的消费者与产生者`，`事件的 注册、分发`即电话的运营商。从编码角度，张三告诉李四任务以及自己电话，李四完事回拨，这个动作叫`回调`。

### 概述

传统Web服务器，采用的事件驱动往往局限在TCP连接建立、关闭事件上，一个连接建立后，在其关闭之前所有的操作都不再是事件驱动，这时就会退化成按序执行每个操作的批处理模式，这样每个请求在连接建立后都将始终占用着系统资源，直到连接关闭才会释放资源。如果整个事件消费者进程只是等待某个条件而已，则会造成服务器资源的极大浪费，影响了系统可以处理的并发连接数

Nginx不会使用进程或线程来作为事件消费者，所谓的事件消费者只能是某个模块。只有事件收集、分发器才会占用进程资源，在分发某个事件时调用事件消费者模块使用当前占用的进程资源。具体来说：
```
1. 由网卡、磁盘等产生事件
2. 事件模块将负责事件的收集、分发操作
3. nginx的其他模块向事件模块注册感兴趣的事件类型，事件产生时，事件模块会把事件分发到相应的模块中进行处理
```
### 多阶段异步处理

多阶段异步处理就是把一个任务的处理过程按照事件的触发方式划分为多个阶段，每个阶段都可以由事件收集、分发器来触发。

异步处理和多阶段是相辅相成的，对于http请求，只有把请求分为多个阶段，才有所谓的异步处理。当一个时间被分发到事件消费者中进行处理时，事件消费者处理完这个事件只相当于处理完1个请求的某个阶段。什么时候可以处理下一个阶段呢？这只能等待内核的通知，即当下一次事件出现时，epoll等事件分发器将会获取到通知，然后去调用事件消费者进行处理。

对于阶段的划分原则，一般有(概念举例，不深入)：
1. 将阻塞方法按照相关的触发事件分为2个阶段：使用非阻塞socket句柄
2. 将阻塞方法按照按照调用时间分为多个阶段的方法调用：比如10MB的I/O拆分成1000个10KB的I/O
3. 对于必须等待的方法调用，使用定时器划分阶段
4. 如果实在无法划分，使用独立进程

## 核心结构体

nginx核心的框架代码围绕着一个结构体展开，即`ngx_cycle_t`，master进程与worker进程在初始化、正常运行时，都是以该结构体为核心的。因此，结构体中肯定需要涵盖nginx配置与module等相关的信息。

### ngx_cycle_t

首先看下定义:
```c
//位于/src/core/ngx_core.h
typedef struct ngx_cycle_s           ngx_cycle_t;

//位于/src/core/ngx_cycle.(c/h)
struct ngx_cycle_s {
    /*
     * 保存着所有模块存储配置项的结构体的指针，这是一个四级指针。
	 * 它首先是一个数组，每个数组成员又是一个指针，这个指针指向另一个存储着指针的数组
	 * p->[p1,...,pn]：conf_ctx指向一个数组，数组中的元素p1,...,pn都是指针
	 * p1->[m1,...,mn]：每个px指向一个数组，数组中的元素m1,...,mn也是指针
	 * m1->data：每个mx指向实际数据
     */
    void                  ****conf_ctx;
    /*
     * 用于该 ngx_cycle_t 的内存池
     */
    ngx_pool_t               *pool;

    /*
     * 日志模块中提供了生成基本ngx_lot_t日志对象的功能，这里的log实际上是在还没有执行
     * ngx_init_cycle 方法前，也就是还没有解析配置前，如果有信息需要输出到日志，就会
     * 暂时使用log对象，它会输出到屏幕。在ngx_init_cycle方法执行后，将会根据nginx.conf
     * 配置文件中的配置项，构造出正确的日志文件，此时会对log重新赋值.
     */
    ngx_log_t                *log;
    /* 
     * 由 nginx.conf 配置文件读取到日志文件路径后，将开始初始化 error_log 日志文件，
     * 由于 log 对象还在用于输出日志到屏幕，这时会用new_log对象暂时性地替代log日志，
     * 待初始化完成后，会用 new_log 的地址覆盖上面的log指针 
     */
    ngx_log_t                 new_log;

    ngx_uint_t                log_use_stderr;  /* unsigned  log_use_stderr:1; */

    /*
     * 对于 poll、rtsig 这样的事件模块，会以有效文件句柄数来预先建立这些 ngx_connection_t
     * 结构体，以加速事件的收集、分发。这时 files 就会保存所有 ngx_connection_t 的指针
     * 组成的数组，files_n 就是指针的总数，而文件句柄的值用来访问 files 数组成员
     */
    ngx_connection_t        **files;
    /*
     * 可用连接池
     */
    ngx_connection_t         *free_connections;
    /*
     * 可用连接池中连接的总数
     */
    ngx_uint_t                free_connection_n;

    /*
     * 保存着当前 Nginx 所编译进来的所有模块 ngx_module_t 结构体的指针
     * 它是一个数组，每个数组元素是指向 ngx_module_t 的指针
     */
    ngx_module_t            **modules;
    /* modules 数组中元素的个数 */
    ngx_uint_t                modules_n;
    ngx_uint_t                modules_used;    /* unsigned  modules_used:1; */

    ngx_queue_t               reusable_connections_queue;
    ngx_uint_t                reusable_connections_n;

    /*
     * 动态数组，每个数组元素存储着 ngx_listening_t 成员，表示监听端口及相关的参数
     */
    ngx_array_t               listening;
    /*
     * 动态数组容器，它保存着 Nginx 所要操作的目录。如果有目录不存在，则会试图创建，
     * 而创建目录失败将会导致 Nginx 启动失败。例如，上传文件的临时目录也在 pathes
     * 中，如果没有权限创建，则会导致 Nginx 无法启动.
     */
    ngx_array_t               paths;

    ngx_array_t               config_dump;
    ngx_rbtree_t              config_dump_rbtree;
    ngx_rbtree_node_t         config_dump_sentinel;

    /*
     * 单链表容器，元素类型是 ngx_open_file_t 结构体，它表示 Nginx 已经打开的所有
     * 文件。事实上，Nginx 框架不会向 open_files 链表中添加文件，而是由对此感兴趣
     * 的模块向其中添加文件路径名，Nginx 框架会在 ngx_init_cycle 方法中打开这些
     * 文件.
     */
    ngx_list_t                open_files;
    /*
     * 单链表容器，元素类型是 ngx_shm_zone_t 结构体，每个元素表示一块共享内存
     */
    ngx_list_t                shared_memory;

    /*
     * 当前进程中所有连接对象的总数
     */
    ngx_uint_t                connection_n;
    ngx_uint_t                files_n;

    /*
     * 指向当前进程中的所有连接对象
     */
    ngx_connection_t         *connections;
    /*
     * 指向当前进程中的所有读事件对象，connection_n 同时表示所有读事件的总数
     */
    ngx_event_t              *read_events;
    /*
     * 指向当前进程中的所有写事件对象，connection_n 同时表示所有写事件的总数
     */
    ngx_event_t              *write_events;

    /*
     * 旧的 ngx_cycle_t 对象用于引用上一个 ngx_cycle_t 对象中的成员。例如
     * ngx_init_cycle 方法，在启动初期，需要建立一个临时的 ngx_cycle_t 对象
     * 保存一些变量，再调用 ngx_init_cycle 方法时就可以把旧的 ngx_cycle_t
     * 对象传进去，而这时 old_cycle 对象就会保存这个前期的 ngx_cycle_t 对象
     */
    ngx_cycle_t              *old_cycle;

    /*
     * 配置文件相对于安装目录的路径名称
     */
    ngx_str_t                 conf_file;
    /* 
     * Nginx 处理配置文件时需要特殊处理的在命令行携带的参数，一般是 
     * -g 选项携带的参数
     */
    ngx_str_t                 conf_param;
    /*
     * Nginx 配置文件所在目录的路径
     */
    ngx_str_t                 conf_prefix;
    /*
     * Nginx 安装目录的路径
     */
    ngx_str_t                 prefix;
    /*
     * 用于进程间同步的文件锁名称
     */
    ngx_str_t                 lock_file;
    /*
     * 使用 gethostname 系统调用得到的主机名
     */
    ngx_str_t                 hostname;
};
```
### ngx_listening_t
## work进程
### 信号量
### 主循环
## master进程