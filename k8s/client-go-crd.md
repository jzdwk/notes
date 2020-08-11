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
因此，crd的定义位于`/artifacts/examples/crd.yaml`中，内容为：
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

相应的，这个crd的内容校验位于`/artifacts/examples/crd-validation.yaml`。

### crd控制器实现

1. 首先进入sample-controller的main函数，定义stop开关，并定义2个client，一个为kubeclient，另一个exampleclient：

```
func main(){
	...
	klog.InitFlags(nil)
	flag.Parse()
	//一个无缓冲的channel作为开关
	stopCh := signals.SetupSignalHandler()
	//kubeconfig实体，主要就是封装了kubeconfig
	cfg, err := clientcmd.BuildConfigFromFlags(masterURL, kubeconfig)
	...
	//传统kubeClient
	kubeClient, err := kubernetes.NewForConfig(cfg)
	...
	//定制client
	exampleClient, err := clientset.NewForConfig(cfg)
	...
}
```

进入`exampleClient, err := clientset.NewForConfig(cfg)`函数，主要逻辑如下：

```
func NewForConfig(c *rest.Config) (*Clientset, error) {
	configShallowCopy := *c
	//rate limiter config
	...
	//定义Client set
	var cs Clientset
	var err error
	//重要，通过config对象，创建一个samplecontrollerV1alpha1,其中对api group version/api path/user agent域进行了default设置,并最终返回了一个SamplecontrollerV1alpha1Client
	cs.samplecontrollerV1alpha1, err = samplecontrollerv1alpha1.NewForConfig(&configShallowCopy)
	...
	//调用client-go 得到discovery，DiscoveryClient的作用为发现k8s支持的API组的函数，版本和资源
	cs.DiscoveryClient, err = discovery.NewDiscoveryClientForConfig(&configShallowCopy)
	...
	return &cs, nil
}
```

上述代码中自定义了SamplecontrollerV1alpha1Client，这个client用于和samplecontroller.k8s.io.group提供的特性进行交互，即通过FoosGetter的foos函数得到foos实体，调用资源对象操作函数。

```
//实现了clientset.Interface
type Clientset struct {
	*discovery.DiscoveryClient
	//自定义，实现了FoosGetter的方法Foos，这个方法返回的FooInterface定义了对象的所有访问方法:Get/Create/Update/List/Watch/Patch...
	samplecontrollerV1alpha1 *samplecontrollerv1alpha1.SamplecontrollerV1alpha1Client
}

type SamplecontrollerV1alpha1Client struct {
	restClient rest.Interface
}
```
SamplecontrollerV1alpha1Client的继承关系为：struct SamplecontrollerV1alpha1Client-实现->interface SamplecontrollerV1alpha1Interface-继承->interface FoosGetter。


2. client set定义完毕后，创建informerFactory，之前定义的client-set作为其字段:
```
	kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, time.Second*30)
	exampleInformerFactory := informers.NewSharedInformerFactory(exampleClient, time.Second*30)
	
	type sharedInformerFactory struct {
	client           versioned.Interface //client-set
	namespace        string
	tweakListOptions internalinterfaces.TweakListOptionsFunc
	lock             sync.Mutex
	defaultResync    time.Duration
	customResync     map[reflect.Type]time.Duration

	informers map[reflect.Type]cache.SharedIndexInformer
	// startedInformers is used for tracking which informers have been started.
	// This allows Start() to be called multiple times safely.
	startedInformers map[reflect.Type]bool
}
```
其中exampleInformerFactory为自定义sharedInformerFactory，实现了自定义的SharedInformerFactory接口，这个接口提供了所有k8s资源对象的informer，这里使用了[工厂模式](https://books.studygolang.com/go-patterns/)：
```
// SharedInformerFactory provides shared informers for resources in all known
// API group versions.
type SharedInformerFactory interface {
	internalinterfaces.SharedInformerFactory
	ForResource(resource schema.GroupVersionResource) (GenericInformer, error)
	WaitForCacheSync(stopCh <-chan struct{}) map[reflect.Type]bool

	Samplecontroller() samplecontroller.Interface
}
```
继承关系为：sharedInformerFactory-实现->SharedInformerFactory-继承->internalinterfaces.SharedInformerFactory

3. 接下来定义**controller**，controller的入参包括了2个client，通过2个informerFactory创建informer:
```
controller := NewController(kubeClient, exampleClient,
		kubeInformerFactory.Apps().V1().Deployments(),
		exampleInformerFactory.Samplecontroller().V1alpha1().Foos())
```
其中Controller的定义如下：
```
type Controller struct {
	//k8s client set
	kubeclientset kubernetes.Interface
	// 用于自定义对象的client set
	sampleclientset clientset.Interface
	
	//lister & synced
	deploymentsLister appslisters.DeploymentLister
	deploymentsSynced cache.InformerSynced
	foosLister        listers.FooLister
	foosSynced        cache.InformerSynced

	//work queue, 
	workqueue workqueue.RateLimitingInterface
	// 调用k8s api 的事件记录
	recorder record.EventRecorder
}
```
进入函数内部，主要工作就是创建controller，添加一个work queue, 并向informer中添加even handler，具体实现如下：
```
func NewController(
	kubeclientset kubernetes.Interface,
	sampleclientset clientset.Interface,
	deploymentInformer appsinformers.DeploymentInformer,
	fooInformer informers.FooInformer) *Controller {

	//创建事件广播
	utilruntime.Must(samplescheme.AddToScheme(scheme.Scheme))
	klog.V(4).Info("Creating event broadcaster")
	eventBroadcaster := record.NewBroadcaster()
	eventBroadcaster.StartLogging(klog.Infof)
	eventBroadcaster.StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: kubeclientset.CoreV1().Events("")})
	recorder := eventBroadcaster.NewRecorder(scheme.Scheme, corev1.EventSource{Component: controllerAgentName})

	//controller定义
	controller := &Controller{
		kubeclientset:     kubeclientset,
		sampleclientset:   sampleclientset,
		deploymentsLister: deploymentInformer.Lister(),
		deploymentsSynced: deploymentInformer.Informer().HasSynced,
		foosLister:        fooInformer.Lister(),
		foosSynced:        fooInformer.Informer().HasSynced,
		workqueue:         workqueue.NewNamedRateLimitingQueue(workqueue.DefaultControllerRateLimiter(), "Foos"),
		recorder:          recorder,
	}

	klog.Info("Setting up event handlers")
	// 定义不同informer的eventhandler函数，此处将事件写入到了工作队列中
	fooInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: controller.enqueueFoo,
		UpdateFunc: func(old, new interface{}) {
			controller.enqueueFoo(new)
		},
	})
	deploymentInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: controller.handleObject,
		UpdateFunc: func(old, new interface{}) {
			newDepl := new.(*appsv1.Deployment)
			oldDepl := old.(*appsv1.Deployment)
			if newDepl.ResourceVersion == oldDepl.ResourceVersion {
				// Periodic resync will send update events for all known Deployments.
				// Two different versions of the same Deployment will always have different RVs.
				return
			}
			controller.handleObject(new)
		},
		DeleteFunc: controller.handleObject,
	})
	return controller
}
```
controller创建完成后，启动informer:
```
	kubeInformerFactory.Start(stopCh)
	exampleInformerFactory.Start(stopCh)
```

最后，调用controller的Run函数，开启N个work process去处理work queue中的消息：
```
func (c *Controller) Run(threadiness int, stopCh <-chan struct{}) error {
	defer utilruntime.HandleCrash()
	defer c.workqueue.ShutDown()
	...
	if ok := cache.WaitForCacheSync(stopCh, c.deploymentsSynced, c.foosSynced); !ok {
		return fmt.Errorf("failed to wait for caches to sync")
	}
	// 启动N个协程，具体的实现位于runWorker
	for i := 0; i < threadiness; i++ {
		go wait.Until(c.runWorker, time.Second, stopCh)
	}
	klog.Info("Started workers")
	//等待stopCh close后退出
	<-stopCh
	klog.Info("Shutting down workers")

	return nil
}
```
这个处理过程就是从queue中取出ns/name,并从informer的lister中获取spec，根据spec的定义去创建对应的资源对象，具体的函数由`processNextWorkItem()`中的`syncHandler`完成:
```
func (c *Controller) processNextWorkItem() bool {
	obj, shutdown := c.workqueue.Get()
	if shutdown {
		return false
	}
	err := func(obj interface{}) error {
		
		defer c.workqueue.Done(obj)
		var key string
		var ok bool
	
		if key, ok = obj.(string); !ok {
			c.workqueue.Forget(obj)
			utilruntime.HandleError(fmt.Errorf("expected string in workqueue but got %#v", obj))
			return nil
		}
		//实现资源的具体操作
		if err := c.syncHandler(key); err != nil {
			// Put the item back on the workqueue to handle any transient errors.
			c.workqueue.AddRateLimited(key)
			return fmt.Errorf("error syncing '%s': %s, requeuing", key, err.Error())
		}
		
		c.workqueue.Forget(obj)
		klog.Infof("Successfully synced '%s'", key)
		return nil
	}(obj)

	if err != nil {
		utilruntime.HandleError(err)
		return true
	}
	return true
}
```
syncHandler实现：
```
func (c *Controller) syncHandler(key string) error {
	namespace, name, err := cache.SplitMetaNamespaceKey(key)
	...
	foo, err := c.foosLister.Foos(namespace).Get(name)
	...
	deploymentName := foo.Spec.DeploymentName
	// Get the deployment with the name specified in Foo.spec
	deployment, err := c.deploymentsLister.Deployments(foo.Namespace).Get(deploymentName)
	...
	if !metav1.IsControlledBy(deployment, foo) {
		msg := fmt.Sprintf(MessageResourceExists, deployment.Name)
		c.recorder.Event(foo, corev1.EventTypeWarning, ErrResourceExists, msg)
		return fmt.Errorf(msg)
	}
	...
	if foo.Spec.Replicas != nil && *foo.Spec.Replicas != *deployment.Spec.Replicas {
		klog.V(4).Infof("Foo %s replicas: %d, deployment replicas: %d", name, *foo.Spec.Replicas, *deployment.Spec.Replicas)
		deployment, err = c.kubeclientset.AppsV1().Deployments(foo.Namespace).Update(context.TODO(), newDeployment(foo), metav1.UpdateOptions{})
	}
	...
	err = c.updateFooStatus(foo, deployment)
	...
	c.recorder.Event(foo, corev1.EventTypeNormal, SuccessSynced, MessageResourceSynced)
	return nil
}
```




## DIY







