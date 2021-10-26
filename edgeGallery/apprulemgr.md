# app rule manager

app rule manager的主要工作为实现appRule的增删改查，包括了2点

- 调用mepserver服务
- 记录db

## main

main函数的实现如下，这里对api的限流使用了三方件`ulule/limiter`，[地址](https://github.com/ulule/limiter)：
```go
// Start application rule manager application
func main() {
    
	r := &util.RateLimiter{}
	rate, _ := limiter.NewRateFromFormatted("200-S")
	r.GeneralLimiter = limiter.New(memory.NewStore(), rate)

	beego.InsertFilter("/*", beego.BeforeRouter, func(c *context.Context) {
	    //在before的过滤器中使用ratelimit
		util.RateLimit(r, c)
	}, true)

	beego.InsertFilter("*", beego.BeforeRouter,cors.Allow(&cors.Options{
		AllowOrigins: []string{"*"},
		AllowMethods: []string{"PUT", "PATCH", "POST", "GET", "DELETE", "OPTIONS"},
		AllowHeaders: []string{"Origin", "X-Requested-With", "Content-Type", "Accept"},
		ExposeHeaders: []string{"Content-Length"},
		AllowCredentials: true,
	}))
	
	beego.ErrorHandler("429", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		w.Write([]byte("Too Many Requests"))
		return
	})
	if util.GetAppConfig("isHTTPS") == "true" {
		tlsConf, err := util.TLSConfig("HTTPSCertFile")
		if err != nil {
			log.Error("failed to config tls for beego")
			return
		}

		beego.BeeApp.Server.TLSConfig = tlsConf
	}
	beego.ErrorController(&controllers.ErrorController{})
	beego.Run()
}
```
## router

api的定义如下，前缀基于`/apprulemgr/v1/tenants/:tenantId/app_instances/:appInstanceId/appd_configuration`
```
func init() {
	adapter := initDbAdapter()
	beego.Router(RootPath+"/health", &controllers.AppRuleController{Db: adapter}, "get:HealthCheck")
	beego.Router(RootPath+util.AppRuleConfigPath, &controllers.AppRuleController{Db: adapter}, "post:CreateAppRuleConfig")
	beego.Router(RootPath+util.AppRuleConfigPath, &controllers.AppRuleController{Db: adapter}, "put:UpdateAppRuleConfig")
	beego.Router(RootPath+util.AppRuleConfigPath, &controllers.AppRuleController{Db: adapter}, "delete:DeleteAppRuleConfig")
	beego.Router(RootPath+util.AppRuleConfigPath, &controllers.AppRuleController{Db: adapter}, "get:GetAppRuleConfig")
	beego.Router(RootPath+util.AppRuleSyncPath+"/sync_updated", &controllers.AppRuleController{Db: adapter}, "get:SynchronizeUpdatedRecords")
	beego.Router(RootPath+util.AppRuleSyncPath+"/sync_deleted", &controllers.AppRuleController{Db: adapter}, "get:SynchronizeDeletedRecords")
}
```

### post

以新增appRule记录为例，其主要分为了2步:
1. 调用mepserver接口
2. 记录db
```go
// Handle app rule configuration
// CRUD操作的统一封装，这里入参的method = POST
func (c *AppRuleController) handleAppRuleConfig(method string) {
	//param parse
	...
	restClient, err := createRestClient(util.CreateAppdRuleUrl(appInstanceId), method, appRuleConfig)
	...
	// POST /mepcfg/app_lcm/v1/applications/{appInstanceId}/appd_configuration
	appRuleFacade := createAppRuleFacade(restClient, appInstanceId)
	response, err := appRuleFacade.handleAppRuleRequest()
	...
	origin := c.Ctx.Request.Header.Get("origin")
	originVar, err := util.ValidateName(origin, util.NameRegex)
	...
	// 如果请求来自MEPM，则sync标志位false，存疑
	syncStatus := true
	if origin == "MEPM" {
		syncStatus = false
	}
	// Add all UUID
	tenantId := c.Ctx.Input.Param(util.TenantId)
	...
	// 写DB
	appdRuleRecord := &models.AppdRuleRec{
		AppdRuleId: tenantId+appInstanceId,
	}

	_ = c.Db.DeleteData(appdRuleRecord, appdRuleId)

	appdRuleRec := &models.AppdRuleRec{
		AppdRuleId: tenantId + appInstanceId,
		TenantId: tenantId,
		AppInstanceId: appInstanceId,
		AppName:  appRuleConfig.AppName,
		AppSupportMp1: appRuleConfig.AppSupportMp1,
		SyncStatus: syncStatus,
		Origin     : origin,
	}

	err = c.Db.InsertOrUpdateData(appdRuleRec, "appd_rule_id")
	...
	err = c.insertOrUpdateAppTrafficRuleRec(appRuleConfig, appdRuleRec, appInstanceId)
	...
	err = c.insertOrUpdateAppDnsRuleRec(appRuleConfig, appdRuleRec, appInstanceId)
	//...resp
}
```