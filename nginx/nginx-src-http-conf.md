# conf文件解析

以http模块为例，记录nginx的nginx.conf解析流程

## 回顾

每个模块都要定义自己的ngx_module_t结构。

在涉及nginx解析nginx.conf文件的工作中，有两个定义在`ngx_module_t`中的数据结构较为重要，[详见](nginx-src-http-moudle-dev.md)：
- **ngx_http_module_t**: 定义回调函数，处理不同模块的配置信息
- **ngx_command_t**:定义解析方法，解析具体配置项的值

```c
//1. ngx_module_t类型定义
struct ngx_module_s {
    NGX_MODULE_V1;  
	
    //指向ngx_http_module_t
    void                 *ctx;
	//指向ngx_command_t
    ngx_command_t        *commands;   // 模块支持的指令集，数组形式，最后用空对象表示结束
		//类型，说明该模块所属，忽略
    ngx_uint_t            type; 
  
    //NULL钩子，省略
    //...
	NGX_MODULE_V1_PADDING;
};

//2. ngx_http_module_t定义回调函数，在解析http{}等块时，执行回调，主要用于对配置项所占存储进行init操作
//这里需要注意参数ngx_conf_t cf，该结构用于存储nginx的各配置项，此处猜测为nginx框架调用init后，将其关联到cf，待后续验证
typedef struct {  
    ngx_int_t   (*preconfiguration)(ngx_conf_t *cf);
    ngx_int_t   (*postconfiguration)(ngx_conf_t *cf);
    void       *(*create_main_conf)(ngx_conf_t *cf);  
    char       *(*init_main_conf)(ngx_conf_t *cf, void *conf);  
    void       *(*create_srv_conf)(ngx_conf_t *cf); 
    char       *(*merge_srv_conf)(ngx_conf_t *cf, void *prev, void *conf);
	void       *(*create_loc_conf)(ngx_conf_t *cf);
    char       *(*merge_loc_conf)(ngx_conf_t *cf, void *prev, void *conf);
} ngx_http_module_t

//3. ngx_command_t定义对各个配置项的解析操作
struct ngx_command_s {
    ngx_str_t             name;		//配置项名称
    //配置项类型，即可以出现在nginx.conf中哪个块，比如server/location。
	//具体值由src/http/ngx_http_config.h中定义的宏确定
	ngx_uint_t            type;		
    char               *(*set)(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);	//当出现name中指定的配置项，则调用set方法处理配置项的参数
    //下面两个偏移量用于定位该配置的存储地址
	ngx_uint_t            conf;		
    ngx_uint_t            offset;	//
    void                 *post;		//配置项读取后的处理方法，必须是ngx_conf_post_t结构的指针
};
```

## 例子

考虑一个如下的nginx.conf配置：
```
http{
	test_str	main;
	server{
		listen	80;
		test_str	server80;
		location	/url1{
			mytest;
			test_str	loc1;
		}
		location	/url2{
			mytest;
			test_str	loc2;
		}
	}
	server{
		listen	8080;
		test_str	server8080;
		location	url3{
			mytest;
			test_str	loc3;
		}
	}

}
```
其解析相关的数据结构定义步骤如下：

1. **定义配置项数据结构**

当nginx解析配置文件时，只要遇到http{}/server{}/location{}块时(无论嵌套与否)，就会为其分配一段内存来存储配置项，具体的流程细节将在后文分析。故需要定义一个数据结构来存储在**不同模块间独立的配置项**
```c
//定义一个用于存储配置项的数据结构
typedef struct
{
    ngx_str_t   	my_str;
    ngx_int_t   	my_num;
    ngx_flag_t   	my_flag;
    size_t		my_size;
    ngx_array_t*  	my_str_array;
    ngx_array_t*  	my_keyval;
    off_t   	my_off;
    ngx_msec_t   	my_msec;
    time_t   	my_sec;
    ngx_bufs_t   	my_bufs;
    ngx_uint_t   	my_enum_seq;
    ngx_uint_t	my_bitmask;
    ngx_uint_t   	my_access;
    ngx_path_t*	my_path;

    ngx_str_t		my_config_str;
    ngx_int_t		my_config_num;
} ngx_http_mytest_conf_t;
```
2. **定义配置项内存分配回调**

nginx使用ngx_http_module_t中的回调函数来管理配置项的存储。当nginx解析配置文件时，遇到配置块后(mian/server/location)，便会根据ngx_module_t中引用的ngx_http_module_t，找到其对应的回调函数，完成内存初始化。

```c
//1.ngx_http_module_t中定义的回调函数，分别在preconfiguration与解析location时调用
static ngx_http_module_t  ngx_http_mytest_module_ctx =
{
    NULL,                              /* preconfiguration */
    ngx_http_mytest_post_conf,      /* postconfiguration */
    NULL,                              /* create main configuration */
    NULL,                              /* init main configuration */

    NULL,                              /* create server configuration */
    NULL,                              /* merge server configuration */
    ngx_http_mytest_create_loc_conf, /* create location configuration */
	//配置项合并在4.中讲解
    ngx_http_mytest_merge_loc_conf   /* merge location configuration */
};
//2.解析location时回调的实现，其实是一个内存分配与init
static void* ngx_http_mytest_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_mytest_conf_t  *mycf;
    mycf = (ngx_http_mytest_conf_t  *)ngx_pcalloc(cf->pool, sizeof(ngx_http_mytest_conf_t));
    //错误处理...
    mycf->my_flag = NGX_CONF_UNSET;
    mycf->my_num = NGX_CONF_UNSET;
    mycf->my_str_array = NGX_CONF_UNSET_PTR;
    mycf->my_keyval = NULL;
    mycf->my_off = NGX_CONF_UNSET;
    mycf->my_msec = NGX_CONF_UNSET_MSEC;
    mycf->my_sec = NGX_CONF_UNSET;
    mycf->my_size = NGX_CONF_UNSET_SIZE;
    return mycf;
}
```

3. **定义配置项解析**

nginx通过使用ngx_command_s来定义配置项的解析逻辑。根据回顾描述，其解析的实现为set方法，可以使用nginx预定义的函数，或自定义实现：
```c
//例子的command实现
static ngx_command_t  ngx_http_mytest_commands[] =
{

    {
		//配置项名称
        ngx_string("test_flag"),
		//该项可配置在哪个配置块中，以及参数个数的约束，"|"表示多个块都可配置
		//配置块的宏定义在ngx_http.h   参数个数约束宏定义在ngx_conf_file.h
        NGX_HTTP_LOC_CONF | NGX_CONF_FLAG,
		//nginx在ngx_conf_file.h预置了14个解析配置的方法，如果配置项的值满足要求，无需自己定义
		//此处为flag类型(on/off)的配置项处理函数
        ngx_conf_set_flag_slot,
		//当某配置项在main/server/location配置块中都出现时，根据ngx_http_module_t的工作机制，将产生3份结构体实例来存储配置项。
		//OFFSET标注此项将解析出的值写入哪个结构体实例
        NGX_HTTP_LOC_CONF_OFFSET,
		//描述当前配置项(my_flag)在整个配置项结构体定义中的便宜位置
        offsetof(ngx_http_mytest_conf_t, my_flag),
        NULL
    },
	//此处为str类型的配置项处理函数
    {
        ngx_string("test_str"),
        NGX_HTTP_MAIN_CONF | NGX_HTTP_SRV_CONF | NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
        ngx_conf_set_str_slot,
        NGX_HTTP_LOC_CONF_OFFSET,
        offsetof(ngx_http_mytest_conf_t, my_str),
        NULL
    },
	//此处为数组类型的配置项处理函数
    {
        ngx_string("test_str_array"),
        NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
        ngx_conf_set_str_array_slot,
        NGX_HTTP_LOC_CONF_OFFSET,
        offsetof(ngx_http_mytest_conf_t, my_str_array),
        NULL
    },
	//省略，其他预置处理函数参考ngx_conf_file.h...
    ngx_null_command
};
```
4. **定义配置项合并**

当nginx解析http{}块内的不同配置项时，一个配置项可以出现在server{}、location{}等不同块中。因此可以通过定义merge函数来完成将父块的配置项合并到子块中，其定义位于ngx_http_module_t中，示例如下：
```c
//parent参数表示解析父块时的结构体，比如location的父为server
//child表示子块，即本身块，比如location
static char *
ngx_http_mytest_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_mytest_conf_t *prev = (ngx_http_mytest_conf_t *)parent;
    ngx_http_mytest_conf_t *conf = (ngx_http_mytest_conf_t *)child;
    ngx_conf_merge_str_value(conf->my_str,
                             prev->my_str, "defaultstr");
	//nginx预设的配置项合并宏
    ngx_conf_merge_value(conf->my_flag, prev->my_flag, 0);
    return NGX_CONF_OK;
}
```

## 解析流程(重要)

根据上节的定义，以上节的nginx.conf为例
```
http{
	test_str	main;
	server{
		listen	80;
		test_str	server80;
		location	/url1{
			mytest;
			test_str	loc1;
		}
		location	/url2{
			mytest;
			test_str	loc2;
		}
	}
	server{
		listen	8080;
		test_str	server8080;
		location	url3{
			mytest;
			test_str	loc3;
		}
	}

}
```
其解析流程如下：

1. 主循环调用配置文件解析器解析nginx.conf文件

2. 当发现配置文件中含有http{}关键字时，HTTP框架开始启动，注意这里的启动由核心模块的`ngx_http_module`完成，详细可参考[nginx-act-main.md](./nginx-act-main.md)

3. 初始化所有HTTP模块的序列号，并创建**ngx_http_conf_ctx_t结构**，该结构用于存储所有HTTP模块的配置项，具体解析下节分析。

4. 依次调用每个HTTP模块的**create_main_conf、create_srv_conf、create_loc_conf方法**：**每个HTTP模块都实现自己的ngx_module_t**。ngx_module_t的**ctx**项中定义了create_main_conf等回调方法，此时，将调用这些方法，并根据模块序号，将返回值写入ngx_http_conf_ctx_t对应数组的项中。因此，上节实现的`ngx_http_mytest_module_ctx`中的`ngx_http_mytest_create_loc_conf`将被调用，被写入`ngx_http_conf_ctx_t->loc_conf[ngx_http_mytest_module_ctx.模块序号]`。

5. 把各HTTP模块上述3个方法返回的地址依次保存到ngx_http_conf_ctx_t结构体的3个数组中(如果某个模块没有定义相应的方法，则为NULL)。

6. 调用每个HTTP模块的**preconfiguration方法**：同样，每个HTTP模块实现的ngx_module_t.ctx都有preconfiguration方法的定义

7. 如果preconfiguration返回失败，那么Nginx进程将会停止。

8. HTTP框架开始循环解析nginx.conf文件中http{...}里面的所有配置项：首先遇到了`test_str`项。

9. 配置文件解析器在检测到一个配置项后，会遍历所有HTTP模块，检查它们的ngx_command_t数组中的name项是否与配置项名相同：此时，遍历到了上节定义的HTTP模块，它的command数组`ngx_http_mytest_commands`中，存在对于`test_str`的解析定义。

10. 如果找到一个HTTP模块对这个配置项感兴趣，就调用ngx_command_t结构中的set方法来处理该配置项：`ngx_http_mytest_commands`数组中第二个元素即满足条件，其代码实现如下：
```c
static ngx_command_t  ngx_http_mytest_commands[] = {
	{
        ngx_string("test_str"),
		//当前配置项位于conf文件的main块，符合NGX_HTTP_MAIN_CONF定义
        NGX_HTTP_MAIN_CONF | NGX_HTTP_SRV_CONF | NGX_HTTP_LOC_CONF | NGX_CONF_TAKE1,
        //nginx的预置set方法
		ngx_conf_set_str_slot,
        NGX_HTTP_LOC_CONF_OFFSET,
        offsetof(ngx_http_mytest_conf_t, my_str),
        NULL
    },
	//...省略
}
```

11. 如果set方法返回失败，那么Nginx进程会停止。

12. 配置文件解析器继续检查配置项。如果发现server{...}配置项，就会调用ngx_http_core_module模块来处理，该模块主要用于处理server{...}块。

13. ngx_http_core_module模块在解析server{...}之前，也会如第三步一样**建立ngx_http_conf_ctx_t结构**，并调用**每个HTTP模块的create_srv_conf、create_loc_conf回调方法**：注意，与第4不的不同在于，这里**不再调用模块的create_main_conf方法**。此时同样调用上节实现的`ngx_http_mytest_module_ctx`中的`ngx_http_mytest_create_loc_conf`。此处会有疑问，*新建立的ngx_http_conf_ctx_t与在解析http块时建立的ngx_http_conf_ctx_t中，都调用create_srv_conf、create_loc_conf方法，他们之间有什么关系么，为何重复调用* 解答将在下文。

14. 将上一步各HTTP模块返回的指针地址保存到ngx_http_core_module模块建立的ngx_http_conf_ctx_t对应的数组中。

15. 开始调用配置文件解析器来处理server{...}里面的配置项：`listen`项由ngx_http_core_module模块处理，此处略过，完毕后又遇到`test_str`项。

16. 继续重复第9步的过程：遍历到了上节定义的HTTP模块，command数组`ngx_http_mytest_commands`中存在对于`test_str`的解析定义，按第10步描述解析之。

17. 配置文件解析器继续解析其他配置项。此时，发现了location{...}块，与之前一样，**建立ngx_http_conf_ctx_t结构，调用模块的create_loc_conf，遍历commands，解析配置项。**如果发现当前server块已经遍历到尾部，则返回ngx_http_core_module模块。

18. 返回配置文件解析器继续解析后面的配置项，流程和前面一样，不再赘述。

19. 配置文件解析器继续解析配置项，如果发现处理到了http{...}的尾部，返回个HTTP框架继续处理。

20. 在第3步、13步以及其他遇到http{...}/server{...}/location{...}块时，nignx都创建了独立的ngx_http_conf_ctx_t数据结构来存储所有HTTP模块的配置项(本质是数组指针)。此时将调用个HTTP模块中ngx_http_module_t中定义的merge_src_conf/merge_loc_conf合并不同块中每个HTTP模块分配的数据结构：在`ngx_http_mytest_module_ctx`中定义了`ngx_http_mytest_merge_loc_conf`，此时将被调用。此处会有疑问，*http块中与server块中存在同名项，server块与location块也有同名项，这个merge调用如何进行的* 解答将在下文

21. HTTP框架处理完毕http配置项，返回给配置文件解析器继续处理其他http{...}外的配置项。

22. 配置文件解析器处理完所有配置项后告诉Nginx主循环配置项解析完毕，这是Nginx才会启动Web服务器。

**注**： 参考《深入理解Nginx》，具体流程图见4.3.1

## ngx_http_conf_ctx_t

上节的流程中，每个配置块(http/server/location)都创建了各自的ngx_http_conf_ctx_t结构，其结构定义如下：
```c
//定义位于src/http/ngx_http_config.h
typedef struct {
　　/* 指针数组，数组中的每个元素指向所有HTTP模块create_main_conf方法产生的结构体*/
　　void **main_conf;
　　/* 指针数组，数组中的每个元素指向所有HTTP模块create_srv_conf方法产生的结构体*/
　　oid **srv_conf;
　　/* 指针数组，数组中的每个元素指向所有HTTP模块create_loc_conf方法产生的结构体*/
　　void **loc_conf;
} ngx_http_conf_ctx_t;
```
针对上节的第13步的疑问，nginx在解析中，对于ngx_http_conf_ctx_t的处理如下：
```
//当nginx解析http块，调用create_main_conf、create_srv_conf、create_loc_conf分别创建HTTP模块各自的配置项存储，返回地址给http块对应的ngx_http_conf_ctx_t	
main_conf_http	 =	{main_point1,main_point2,...,main_pointn}	//main_point2指向第二个HTTP模块调用其create_main_conf返回的指针，下同
srv_conf_http	= 	{srv_point1,srv_point2,...,srv_pointn}	
loc_conf_http	= 	{loc_point1,loc_point2,...,loc_pointn}
//当nginx解析server块，调用create_srv_conf、create_loc_conf分别创建HTTP模块各自的配置项存储，返回地址给server块对应的ngx_http_conf_ctx_t
main_conf_srv	 =	&main_conf_http //注意，因为srver块下没有main块的配置，所以直接指向http块的配置地址
srv_conf_srv	= 	{srv_point1,srv_point2,...,srv_pointn}	//srv_point2指向第二个HTTP模块调用其create_srv_conf返回的指针，下同
loc_conf_srv	= 	{loc_point1,loc_point2,...,loc_pointn}
//当nginx解析location块，调用create_loc_conf创建HTTP模块各自的配置项存储，返回地址给location块对应的ngx_http_conf_ctx_t
main_conf_loc	 =	&main_conf_srv //注意，因为loction块下没有main块的配置，所以直接指向http块的配置地址
srv_conf_loc	= 	&srv_conf_srv	//loction块下没有server块的配置，所以直接指向http块的配置地址
loc_conf_loc	= 	{loc_point1,loc_point2,...,loc_pointn}	//loc_point2指向第二个HTTP模块调用其create_loc_conf返回的指针
```
此处可以看到：
1. nginx.conf中，每次解析http/server/location块时，create_loc_conf方法都会被调用，且init到不同地址并被http/server/location块的ngx_http_conf_ctx_t存储
2. nginx.conf中，每次解析http/server块时，create_server_conf方法都会被调用，且init到不同地址并被http/server块的ngx_http_conf_ctx_t存储
3. nginx.conf中，每次解析http时，会调用一次create_main_conf方法，被http块的ngx_http_conf_ctx_t存储
这种存储设计的原因在于：**nginx配置中，高级别的配置可以对低级别的配置起作用，或提供配置项合并的解决方案**，比如：

*当用户在http{}块中写入一项配置后，希望对http{}块内所有的server{}块都生效，但是当server{}块中定义了同名项，则以server{}块为准。此时，http{}和server{}块对于该配置都进行了独立存储，此时该项只出现在http{}块时，以http块值为准;又出现在server块且与http块值不同时，则执行merge操作*

## merge操作

1. 按序遍历所有的HTTP模块: 比如遍历到了前文定义的mytest模块
2. 遍历该HTTP模块下所有server{}块生成的结构体(因为http块为顶级块，无需与父块合并)，所有server{}块是因为一个http{}块下可包含多个server{}:比如先遍历到了例子中的第一个server{}
3. 针对某server{}块的结构体(存储在ngx_http_conf_ctx_t)，如果该HTTP模块实现了`merge_srv_conf`方法，调用之，从而完成对http{}、server{}块下`create_srv_conf`产生的结构体的合并(即ngx_http_conf_ctx_t.srv_conf)：mytest中均无定义，继续
4. 如果该HTTP模块实现了`merge_loc_conf`方法，调用之，从而完成对http{}、server{}块下`create_loc_conf`产生的结构体(即ngx_http_conf_ctx_t.loc_conf)的合并：mytest中分别定义了`ngx_http_mytest_create_loc_conf`与`ngx_http_mytest_merge_loc_conf`，合并后继续
5. 遍历该HTTP模块的server{}下所有location{}块生成的结构体，同理于，所有location{}块是因为一个server{}块下可包含多个location{}:比如先遍历到了例子中的第一个server{}下的第一个location{}
6. 同步骤4， 如果该HTTP模块实现了`merge_loc_conf`方法，调用之，从而完成对server{}、location{}块下`create_loc_conf`产生的结构体的合并：mytest中分别定义了`ngx_http_mytest_create_loc_conf`与`ngx_http_mytest_merge_loc_conf`，合并后继续
7. 在某location{}块下,继续遍历嵌套的location{}。如果有，调用`merge_loc_conf`方法完成对父location{}、当前location{}中，`create_loc_conf`产生的结构体的合并；如果没有子嵌套，流程转5
























