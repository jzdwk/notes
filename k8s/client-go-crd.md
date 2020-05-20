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
- 定义crd struct/yaml，并将其下发至k8s对象
- 定义crd相关的Informer controller等组件，具体来说：
1. 根据kubeconfig创建CRD的client set
2. 构建CRD **informerFactory，informer**
3. 根据informerFactory创建controller,controller中封装了：`client set`,`lister`,`synced`,**`workqueue`**,`recorder`，同时添加CRD informer的**Resource Event Handlers**，当有对应事件，处理一部分业务逻辑，并将key放入work queue
4. controller创建完成后，实现Run方法，启动n个**process item**，从work queue中不断取出key，通过key去执行一个sync逻辑，保证k8s中资源对象的状态(通过**lister**获取，其实就是informer的local store)=spec的状态




