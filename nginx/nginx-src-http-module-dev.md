# http module demo

编写一个简单的HTTP模块插件

## 编写module涉及的核心接口


nginx的主框架只有少量核心源代码，大量强大功能都是在各个模块中实现的。

众多模块共分为五个大类：核心模块、HTTP模块、Event模块、Mail模块、配置模块。

而所有这些模块都遵循一个统一的接口设计规范：**ngx_module_t**

在**ngx_module_t**中，又有两项最为重要，分别为
- **ctx**: ctx为ngx_module_t与各个模块(core/event/http等)的纽带，也可以说是具体模块的公共接口。对于HTTP模块，ctx必须指向ngx_http_module_t接口。
- **commands**：用于定义模块的配置文件参数，每一个元素都是ngx_command_t类型，结尾用ngx_nul_command表示。nginx在解析配置文件中的配置项时，首先会遍历各模块，对于一个模块，则遍历其commands数据进行

### ngx_module_t

其定义位于`src/core/ngx_core.h`中：
```c
typedef struct ngx_module_s          ngx_module_t;
```
而ngx_module_s的定义如下，位于`src/core/ngx_module.h`：
```c
struct ngx_module_s {
    ngx_uint_t            ctx_index;    //是该模块在同一类模块中的序号，通常用NGX_MODULE_V1初始化为NGX_MODULE_UNSET_INDEX（-1）
    
    ngx_uint_t            index;    //该模块在所有Nginx模块中的序号， 即在ngx_modules数组里的唯一索引，通常用NGX_MODULE_V1初始化为NGX_MODULE_UNSET_INDEX（-1）
    
    char                 *name; // 模块的名字，用NGX_MODULE_V1初始化为NULL
    ngx_uint_t            spare0; //保留字段，用NGX_MODULE_V1初始化为0
    ngx_uint_t            spare1; //保留字段，用NGX_MODULE_V1初始化为0
    
    ngx_uint_t            version; // 模块版本号
    
    const char           *signature; // 模块的二进制兼容性签名，即NGX_MODULE_SIGNATURE
     
	//因为通常情况下，都不需要设置以上值，故在src/core/ngx_module.h中定义了一个宏，用来初始化上面这些字段：
    /*#define NGX_MODULE_V1                                                         
        NGX_MODULE_UNSET_INDEX, NGX_MODULE_UNSET_INDEX,                           
        NULL, 0, 0, nginx_version, NGX_MODULE_SIGNATURE
	*/
    
	
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
  

     // 以下7个函数指针，俗称钩子函数，会在程序启动、结束等不同阶段被调用
	 // 注意，这些方法是被nginx框架调用的，和是否提供HTTP服务无关，故即使nginx.conf中没有http{...}块，也会被调用
    ngx_int_t           (*init_master)(ngx_log_t *log);//主进程初始化时调用
    ngx_int_t           (*init_module)(ngx_cycle_t *cycle);//模块初始化时调用（在ngx_init_cycle里被调用）
    ngx_int_t           (*init_process)(ngx_cycle_t *cycle);//工作进程初始化时调用
    ngx_int_t           (*init_thread)(ngx_cycle_t *cycle);//线程初始化时调用
    void                (*exit_thread)(ngx_cycle_t *cycle);//线程退出时调用
    void                (*exit_process)(ngx_cycle_t *cycle);//工作进程退出时调用（在ngx_worker_process_exit调用）
    void                (*exit_master)(ngx_cycle_t *cycle);//主进程退出时调用（在ngx_master_process_exit调用）
    
    // 下面八个预留字段，用NGX_MODULE_V1_PADDING宏全部初始化为0
    //#define NGX_MODULE_V1_PADDING  0, 0, 0, 0, 0, 0, 0, 0
    uintptr_t             spare_hook0;
    uintptr_t             spare_hook1;
    uintptr_t             spare_hook2;
    uintptr_t             spare_hook3;
    uintptr_t             spare_hook4;
    uintptr_t             spare_hook5;
    uintptr_t             spare_hook6;
    uintptr_t             spare_hook7;
};
```
综上，在结构体初始化时，通常情况下需要用到2个宏定义：
```c
//前七个成员的初始化
#define NGX_MODULE_V1          0, 0, 0, 0,  NGX_DSO_ABI_COMPATIBILITY, NGX_NUMBER_MAJOR, NGX_NUMBER_MINOR   
//后八个成员的初始化
#define NGX_MODULE_V1_PADDING  0, 0, 0, 0, 0, 0, 0, 0   
```

### ngx_http_module_t

当编写的模块为HTTP模块，则ngx_module_t中的ctx指向了ngx_http_module_t。ngx_http_module_t所有的属性都是回调函数，职责为处理各级的conf配置，函数描述了8个阶段，会在HTTP框架在读取/重载配置文件时调用。

其定义位于`src/http/ngx_http_config.h`

```c
typedef struct {
    /**
     * 在解析配置文件中http{}配置块前调用
     */
    ngx_int_t   (*preconfiguration)(ngx_conf_t *cf);

    /**
     * 在解析配置文件中http{}配置块后调用
     */
    ngx_int_t   (*postconfiguration)(ngx_conf_t *cf);

    /**
     * 当需要创建数据结构来存储main级别(直属于http{...}块的配置项)的全局配置项时，使用此回调创建存储main级配置的结构体
	 * 注意，该函数的返回值可以作为ngx_http_conf_get_module_main_conf和ngx_http_get_module_main_conf的结果
     */
    void       *(*create_main_conf)(ngx_conf_t *cf);
    
    /**
     * 初始化http模块的main级别配置项
     */
    char       *(*init_main_conf)(ngx_conf_t *cf, void *conf);

    /**
     * 当需要创建数据结构来存储server级别(直属于server{...}块的配置项)的配置项时，使用此回调创建存储server配置的结构体
	 * 注意，该函数的返回值可以作为ngx_http_conf_get_module_srv_conf和ngx_http_get_module_srv_conf的结果
     */
    void       *(*create_srv_conf)(ngx_conf_t *cf);
    
    /**
     * 合并http模块中main级与server级的同名配置，实现main到server的指令的继承、覆盖
     */
    char       *(*merge_srv_conf)(ngx_conf_t *cf, void *prev, void *conf);

    /**
     * 当需要创建数据结构来存储location级别(直属于location{...}块的配置项)的配置项时，使用此回调创建存储location配置的结构体
	 * 注意，该函数的返回值可以作为ngx_http_conf_get_module_loc_conf和ngx_http_get_module_loc_conf的结果
     */
    void       *(*create_loc_conf)(ngx_conf_t *cf);
    
    /**
     * 合并http模块中server级与location级的同名配置，实现server到location的指令的继承、覆盖
     */
    char       *(*merge_loc_conf)(ngx_conf_t *cf, void *prev, void *conf);
} ngx_http_module_t

```
### ngx_command_t

commands数组定义模块的配置文件参数，每一个数组元素都是一个ngx_command_t类型，该类型在`src/core/ngx_core.h`中声明：
```c
typedef struct ngx_command_s         ngx_command_t;
```
后者定义位于`src/core/ngx_conf_file.h`
```c
struct ngx_command_s {
    ngx_str_t             name;		//配置项名称
	
    //配置项类型，即可以出现在nginx.conf中哪个块，比如server/location。
	//具体值由src/http/ngx_http_config.h中定义的宏确定
	/**
	*	#define NGX_HTTP_MAIN_CONF        0x02000000        //可以直接出现在http配置指令里
	*	#define NGX_HTTP_SRV_CONF         0x04000000         //可以出现在http里面的server配置指令里
	*	#define NGX_HTTP_LOC_CONF         0x08000000         //可以出现在http server块里面的location配置指令里
	*	#define NGX_HTTP_UPS_CONF         0x10000000          //可以出现在http里面的upstream配置指令里
	*	#define NGX_HTTP_SIF_CONF         0x20000000           //可以出现在http里面的server配置指令里的if语句所在的block中
	*	#define NGX_HTTP_LIF_CONF         0x40000000           //可以出现在http server块里面的location配置指令里的if语句所在的block中
	*	#define NGX_HTTP_LMT_CONF         0x80000000         //可以出现在http里面的limit_except指令的block中
	*/
	ngx_uint_t            type;		
	
    char               *(*set)(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);	//当出现name中指定的配置项，则调用set方法处理配置项的参数
    //下面两个偏移量用于定位该配置的存储地址
	ngx_uint_t            conf;		
    ngx_uint_t            offset;	//
    void                 *post;		//配置项读取后的处理方法，必须是ngx_conf_post_t结构的指针
};
```
