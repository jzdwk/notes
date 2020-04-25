# kong function

主要记录一些kong的主要功能

## proxy

kong最基本的功能就是实现一个反向代理。从client端来看，kong在其配置的代理端口(默认为8000和8443)上监听HTTP流量，在显式配置的stream_listen端口上侦听4层流量。kong根据配置的route对HTTP请求或TCP/UDP请求进行路由。当请求符合特定路由的规则，kong将处理代理请求，将请求转发到后端的service or upstream。所以，kong的proxy功能涉及到了route/service/upstream，同时，可以通过添加plugin来增强反向代理的功能。详情可参见[proxy说明](https://docs.konghq.com/2.0.x/proxy/)以及[kong的route笔记](https://github.com/jzdwk/notes/blob/master/kong/kong%20object.md)

## authentication

kong可以通过认证插件提供请求的认证功能，其整体的思路是，根据请求者的身份(外部访问时，在header中添加相关信息),进行访问控制。在实现时，需要用到consumer资源对象，整体流程为：

1. 在某个service (或其他资源对象) 上部署一个认证插件
2. 创建一个consumer实体
3. 为consumer提供特定身份验证方法的身份验证凭据，如api-key
4. 当请求进入Kong时，检查所提供的凭据(取决于验证类型)，如果验证失败，请求将阻塞。

## load balance

### dns based

### ring-balancer

## health check



