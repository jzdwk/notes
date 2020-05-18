# client-go informer 笔记

## 概念

在获取/监控一个k8s资源对象时，可以直接调用k8s apiserver,如当我们要watch pod的资源状态并做处理时：

```
	resp, err := http.Get("http://apiserver:port/api/v1/watch/pods?watch=yes")
	...
    decoder := json.NewDecoder(resp.Body)
    for {
        var event Event
        err = decoder.Decode(&event)
        if err != nil {
            // ...
        }
        switch event.Type {
        case ADDED, MODIFIED:
            // ...
        case DELETED:
            // ...
        case ERROR:
            // ...
        }
    }
```

但这种做法的直接结果是api server的qps增加，所以，client-go除了提供基本的k8s操作封装，也引入了informer工具。 informer中文意思就是"通知者"，是一个带有**本地缓存和索引机制的、可以注册EventHandler的client端**，可以把informer当做一个client端的cache。client对k8s对象的List/Get  操作都通过本地informer进行。除List/Get外，Informer 还可以监听事件并触发回调函数等，以实现更加复杂的业务逻辑。所以，informer的关键点有2：

- **依赖List/Watch的List/Get**： Informer在初始化的时，先调用Kubernetes List API获得定义的k8s资源对象的全部Object，缓存在内存中; 然后，调用 Watch API去watch这类对象，从而维护缓存。所有的Get/List均走这个cache。

- **ResourceEventHandler**:  通过添加ResourceEventHandler回调函数，并实现 OnAdd(obj interface{}) OnUpdate(oldObj, newObj interface{}) 和 OnDelete(obj interface{}) 三个方法，便可以在资源对象被操作时，加入需要的业务逻辑。

## 使用

client-go informer的使用场景有两个，一个是作为k8s client的cache使用，主要是完成资源对象的watch。另一个为自定义CRD：

1. client cache角色

```
	//k8s kubeconfig 文件获取
	var kubeconfig *string
    if home := homedir.HomeDir(); home != "" {
        kubeconfig = flag.String("kubeconfig", filepath.Join(home, ".kube", "config"), "(optional) absolute path to the kubeconfig file")
    } else {
        kubeconfig = flag.String("kubeconfig", "", "absolute path to the kubeconfig file")
    }
    flag.Parse()
	
    config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
    if err != nil {
        panic(err)
    }

    // 初始化 client-set
    clientset, err := kubernetes.NewForConfig(config)
    if err != nil {
        log.Panic(err.Error())
    }
	//定义一个stopper开关，通过close这个channel，informer将执行一些清理操作
    stopper := make(chan struct{})
    defer close(stopper)
    
    //初始化 informer，推荐使用的是SharedInformerFactory，Shared 指的是在多个Informer中共享一个本地cache。
    factory := informers.NewSharedInformerFactory(clientset, 0)
	//定义watch node资源对象的informer
    nodeInformer := factory.Core().V1().Nodes()
    informer := nodeInformer.Informer()
    defer runtime.HandleCrash()
    
    // 启动 informer，list & watch
    go factory.Start(stopper)
    
    // 从 apiserver 同步资源，即 list 
    if !cache.WaitForCacheSync(stopper, informer.HasSynced) {
        runtime.HandleError(fmt.Errorf("Timed out waiting for caches to sync"))
        return
    }
	
    // 使用自定义 handler
    informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc:    func...,
        UpdateFunc: func..., 
        DeleteFunc: func...,
    })
    
    // 创建 lister
    nodeLister := nodeInformer.Lister()
    // 从 lister 中获取所有 items
    nodeList, err := nodeLister.List(labels.Everything())
    if err != nil {
        fmt.Println(err)
    }
    fmt.Println("nodelist:", nodeList)
    <-stopper
```

2. controller角色

具体请参考[sample-controller示例](https://github.com/kubernetes/sample-controller)

## 代码分析

### 整体流程

