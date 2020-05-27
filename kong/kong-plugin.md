# kong plugin

kong本身完成的是一个反向代理的功能，通过各种插件实现了api gateway的功能，plugin具体分为六大类：

- Authentication
- Security
- Traffic Control
- Serverless
- Analytics&Monitoring
- Transformations

下面记录了在项目中可能用到的一些插件使用(非Enterprise)，不特殊说明的话，这些插件都可以应用在route/service/consumer

## Transformations

这类plugin主要在req/resp上做文章，当请求到达upstream或返回client之前，对请求/响应的内容进行处理。

### Request&Response Transformer

这个插件主要用于对请求/响应的header/body/querystring上的内容进行增/删/替换，[传送门-req](https://docs.konghq.com/hub/kong-inc/request-transformer/) ,[传送门-resp](https://docs.konghq.com/hub/kong-inc/response-transformer/) 在api产品上，可用于增加api网关到backend的交互内容。

### Inspur Request& Transformer

这个实现了请求各种位置的参数转换和添加。