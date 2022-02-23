# nginx event 
nginx事件学习与epoll模块解析

## nginx event 

与http模块类似，nginx解析事件时，也是通过core类型模块的ngx_events_module与事件类型模块的ngx_event_core_module配合完成。在初始化时，首先初始化核心模块，其流程与http相同：
```c

ngx_module_t  ngx_events_module = {
    NGX_MODULE_V1,
    &ngx_events_module_ctx,                /* module context */
    ngx_events_commands,                   /* module directives */
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
//commands中为nginx配置中events{}块的解析
static ngx_command_t  ngx_events_commands[] = {

    { ngx_string("events"),
      NGX_MAIN_CONF|NGX_CONF_BLOCK|NGX_CONF_NOARGS,
      ngx_events_block,
      0,
      0,
      NULL },
      ngx_null_command
};
//ngx_events_block会初始化每一个event类型的模块，首先将会是ngx_event_core_module
static char *
ngx_events_block(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ...
    ngx_event_max_module = ngx_count_modules(cf->cycle, NGX_EVENT_MODULE);
    ctx = ngx_pcalloc(cf->pool, sizeof(void *));
    ...
    *ctx = ngx_pcalloc(cf->pool, ngx_event_max_module * sizeof(void *));
    ...
    *(void **) conf = ctx;
	//调用每个events模块的create_conf，初始化配置项结构体
    for (i = 0; cf->cycle->modules[i]; i++) {
        if (cf->cycle->modules[i]->type != NGX_EVENT_MODULE) {
            continue;
        }
        m = cf->cycle->modules[i]->ctx;
        if (m->create_conf) {
            (*ctx)[cf->cycle->modules[i]->ctx_index] =
                                                     m->create_conf(cf->cycle);
            if ((*ctx)[cf->cycle->modules[i]->ctx_index] == NULL) {
                return NGX_CONF_ERROR;
            }
        }
    }

    pcf = *cf;
    cf->ctx = ctx;
    cf->module_type = NGX_EVENT_MODULE;
    cf->cmd_type = NGX_EVENT_CONF;
	//为event模块解析nginx.conf配置
    rv = ngx_conf_parse(cf, NULL);
    *cf = pcf;
    ...
	//调用每个events模块的init_conf，完成参数整合
    for (i = 0; cf->cycle->modules[i]; i++) {
        if (cf->cycle->modules[i]->type != NGX_EVENT_MODULE) {
            continue;
        }

        m = cf->cycle->modules[i]->ctx;
        if (m->init_conf) {
            rv = m->init_conf(cf->cycle,
                              (*ctx)[cf->cycle->modules[i]->ctx_index]);
            if (rv != NGX_CONF_OK) {
                return rv;
            }
        }
    }

    return NGX_CONF_OK;
}
```