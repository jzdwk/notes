# http module demo

编写一个简单的HTTP模块插件

## 目标

在nginx.conf文件中的http/server或者location块内**定义mydemo配置项**。

当一个请求到达nginx后匹配上了相应的配置块，且块内有mydemo配置项，则调用编写的demo module处理请求。

## conf解析逻辑

因为要设置mydemo配置项，故定义ngx_command_t来设置解析逻辑：
```c
static ngx_command_t ngx_http_mydemo_commands[] = {  
    {  
		/*配置项名称*/
        ngx_string("mydemo"),  
		/*可出现的模块*/
        NGX_HTTP_MAIN_CONF | NGX_HTTP_SRV_CONF | NGX_HTTP_LOC_CONF | NGX_HTTP_LMT_CONF | NGX_CONF_NOARGS, 
		/*set方法定义*/
        ngx_http_mydemo,  
        NGX_HTTP_LOC_CONF_OFFSET,  
        0,  
        NULL  
    },  
	/*结束符*/
    ngx_null_command      
};

//command的set接口实现，真正的执行委托给handler
static char* ngx_http_mydemo(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)  
{  
    ngx_http_core_loc_conf_t *clcf;
	//ngx_http_conf_get_module_loc_conf为main/http/server/location块的数据结构
    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
	//注册handler方法，当请求进行到NGX_HTTP_CONTENT_PHASE阶段时调用
    clcf->handler = ngx_http_mydemo_handler;
    return NGX_CONF_OK;
} 

//handler的具体实现
static ngx_int_t ngx_http_mydemo_handler(ngx_http_request_t *r)  
{  
    if (!(r->method & (NGX_HTTP_GET | NGX_HTTP_HEAD))) {  
        return NGX_HTTP_NOT_ALLOWED; 
    }
    // Discard request body  
    ngx_int_t rc = ngx_http_discard_request_body(r);  
    if (rc != NGX_OK) {  
        return rc;  
    }  
  
    // Send response header  
	//输出一个hello world
    ngx_str_t type = ngx_string("text/plain");  
    ngx_str_t response = ngx_string("Hello World!");  
    r->headers_out.status = NGX_HTTP_OK;  
    r->headers_out.content_length_n = response.len;  
    r->headers_out.content_type = type;  

    rc = ngx_http_send_header(r);  
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {  
        return rc;  
    }  
    // Send response body  
    ngx_buf_t *b;  
    b = ngx_create_temp_buf(r->pool, response.len);  
    if (b == NULL) {  
        return NGX_HTTP_INTERNAL_SERVER_ERROR;  
    }  
    ngx_memcpy(b->pos, response.data, response.len);  
    b->last = b->pos + response.len;  
    b->last_buf = 1;  
  
    ngx_chain_t out;  
    out.buf = b;  
    out.next = NULL;  

    return ngx_http_output_filter(r, &out);  
}  
```

## ngx_module_t定义

定义ngx_http_module_t的8个回调方法，用于在HTTP框架初始化时对main/http/server/location块内的配置进行处理。这里因为没有需要完成的工作，所以为NULL：
```c
static ngx_http_module_t ngx_http_mydemo_module_ctx = {  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL  
}; 
```
定义mydemo模块：
```c
ngx_module_t ngx_http_mydemo_module = {  
	NGX_MODULE_V1,  
    &ngx_http_mydemo_module_ctx,  
    ngx_http_mydemo_commands,  
    NGX_HTTP_MODULE,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NULL,  
    NGX_MODULE_V1_PADDING  
};  
```

## 编写config文件

```c
ngx_addon_name=ngx_http_mydemo_module
HTTP_MODULES="$HTTP_MODULES ngx_http_mydemo_module"
NGX_ADDON_SRCS="$NGX_ADDON_SRCS $ngx_addon_dir/ngx_http_mydemo_module.c"
```

## 安装与测试
```
./configure --add-module=/root/nginx/
make
make install
```