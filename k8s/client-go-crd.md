# client-go-crd 笔记

## client-go 

client-go是k8s的sdk，整体架构如下图所示：

### client-go component

- **Reflactor**: reflactor用于watch k8s的api，通过指定资源对象(内置orCRDs)，reflactor将新的object对象放入Delta FIFO队列，后者是一个*增量队列* 。

- **Informer**: informer从Delta FIFO队列中取出对象，并进行缓存处理，当使用Informer组件时，后续的list/get将都使用该缓存。

- **Indexer**： Indexer主要将Delta FIFO队列的object以key-value的形式进行线程安全的存储

### Custom Controller

- **Informer reference**: informer对象的引用，用于操作CRD，如果使用了自定义的CRD资源对象，则需要实现一个自定义的Informer

- **Indexer reference**：indexer的对象引用，同上。

- **Resource Event Handlers**： 当informer监听到资源对象的下发时，执行的回调函数。回调的实现逻辑为将资源对象的key写到工作队列，这里的key相当于事件通知，同时也是Indexer中的key。

- **Work queue**： 存放资源对象kv的FIFO队列

- **Process Item**：从工作队列中取出key后进行后续处理，这个组件是真正进行事件处理的。

## sample-controller 示例

[sample-controller](https://github.com/kubernetes/sample-controller) 为client-go给的官方创建crd示例，总体来说，构建定义一个crd需要有两大步：

1. 定义crd struct/yaml，并将其下发至k8s对象

2. 定义crd相关的Informer controller等组件，具体来说：

- 根据kubeconfig创建CRD的client set

- 构建CRD **informerFactory，informer**

- 根据informerFactory创建controller,controller中封装了：`client set`,`lister`,`synced`,**`workqueue`**,`recorder`，同时添加CRD informer的**Resource Event Handlers**，当有对应事件，处理一部分业务逻辑，并将key放入work queue

- controller创建完成后，实现Run方法，启动n个**process item**，从work queue中不断取出key，通过key去执行一个sync逻辑，保证k8s中资源对象的状态(通过**lister**获取，其实就是informer的local store)=spec的状态

### crd定义

[crd](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions/#create-a-customresourcedefinition) 是用于描述k8s的自定义资源对象，定义的模板为：
```
apiVersion: apiextensions.k8s.io/v1  #此处有两个版本，1.16之前为apiextensions.k8s.io/v1beta1
kind: CustomResourceDefinition
metadata:
  # 定义 crd_name.group_name,所以crontabs就是这个crd的kind，而stable.example.com对应于yaml中的spec.group
  name: crontabs.stable.example.com
spec:
  # 这个名称对应了未来的k8s rest api路径: /apis/<group>/<version>
  group: stable.example.com
  # 版本列表，不同的版本中可定义不同属性，同样对应k8s rest api中的version
  versions:
    # 版本名称
    - name: v1
      # 是否启用这个版本的flag
      served: true
      # 是否存储，只能有一个版本被设置为true
      storage: true
	  # 1.16中新增加的属性
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                cronSpec:
                  type: string
                image:
                  type: string
                replicas:
                  type: integer
  # crd的定义范围，ns级还是cluster级
  scope: Namespaced
  # crd的名称
  names:
    # 复数的名称,要求小写
    plural: crontabs
    # 单数的名称,要求小写
    singular: crontab
    # 资源类型名称，首字母大写+驼峰
    kind: CronTab
    # 缩写定义,要求小写
    shortNames:
    - ct
```
因此，crd的定义位于/artifacts/examples/crd.yaml中，内容为：
```
apiVersion: apiextensions.k8s.io/v1beta1 #注意此处的apiVersion
kind: CustomResourceDefinition
metadata:
  name: foos.samplecontroller.k8s.io
spec:
  group: samplecontroller.k8s.io
  version: v1alpha1
  names:
    kind: Foo
    plural: foos
  scope: Namespaced
```




