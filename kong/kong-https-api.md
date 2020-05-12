# https 保护

当k8s通过ingress暴露的api是http时，可以通过*kongIngress*为其重定向到https服务，此时client->api gateway将使用https。具体操作为：

1. 首先创建一个kongIngress，其声明的协议为https：

```
apiVersion: configuration.konghq.com/v1
kind: KongIngress
metadata:
    name: https-only
route:
  protocols:
  - https
  https_redirect_status_code: 302
```

2. 将其应用到需要https服务的k8s ingress上

```
kubectl patch ingress demo -p '{"metadata":{"annotations":{"konghq.com/override":"https-only"}}}'
```

此时，使用http访问ingress定义的服务的path，则得到302重定向码，使用https时，需要证书认证。

# k8s cert-manager


在k8s中，提供了一套证书管理工具cert-manager，需要一些CRD定义，安装[cert-manager组件](https://cert-manager.io/docs/installation/kubernetes/)
具体的安装步骤为：

1. 安装需要的crd，使用kubectl：
```kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v0.15.0/cert-manager.crds.yaml```

2. 使用helm进行安装，将cert-manager安装至cert-manager的ns下：
```helm install cert-manager jetstack/cert-manager --namespace cert-manager --version v0.15.0```

3. 查看是否成功：
```kubectl get all -n cert-manager```

4. ##todo##


