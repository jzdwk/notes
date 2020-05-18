# client-go-crd 笔记

## client-go 

client-go是k8s的sdk，整体架构如下图所示：

### client-go component

- **Reflactor**: reflactor用于watch k8s的api，通过指定资源对象(内置orCRDs)，reflactor将新的object对象放入Delta FIFO队列，后者是一个*增量队列* 。

- **Informer**: informer从Delta FIFO队列中取出对象，并进行缓存处理，当使用Informer组件时，后续的list/get将都使用该缓存。

- **Indexer**： Indexer主要将Delta FIFO队列的object以key-value的形式进行线程安全的存储

### Custom Controller

- **Informer reference**: 