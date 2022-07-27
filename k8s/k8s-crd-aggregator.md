# k8s 定制资源 与 api聚合

定制资源与聚合api都是扩展kubernetes API的一种方式。

(CustomResourceDefinition)[https://kubernetes.io/zh-cn/docs/concepts/extend-kubernetes/api-extension/custom-resources/] API通过**设定名字和Schema**，来自定义创建一个新的k8s资源。Kubernetes API负责为你的定制资源提供存储和访问服务。CRD使得在扩展k8s api时，不必编写自己的 API 服务器来处理定制资源，不过其背后实现的通用性也意味着，其所获得的灵活性要比 API 服务器聚合少很多。

通常，Kubernetes API 中的每个资源都需要处理 REST请求和管理对象持久性存储的代码。 Kubernetes API主服务器能够处理诸如pods和services这些内置资源，也可以按通用的方式通过CRD来处理定制资源。

而(API聚合)[https://kubernetes.io/zh-cn/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/] 使得你可以通过编写和部署你自己的 API 服务器来为定制资源提供特殊的实现。 主API 服务器将**针对你要处理的定制资源的请求全部委托给你自己的API服务器来处理，同时将这些资源提供给其所有客户端**。

因此，当需要扩展k8s api时，需要从易用性、灵活性等方面考虑，去选择使用CRD还是API聚合，官方给出的比较建议如下：

https://kubernetes.io/zh-cn/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/

## CRD

下面以官方的[sample-controller](https://github.com/kubernetes/sample-controller) 为例对crd的定义和controller的编写进行说明。

### CRD模板定义

首选，需要定义资源的模板，即资源的名称、类型、可选字段等等，模板定义位于`artifacts/examples/crd.yml`
```
apiVersion: apiextensions.k8s.io/v1  #CRD模板本身也是k8s资源，版本apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  # 定义 kind.group_name,所以foos就是这个crd的kind，而samplecontroller.k8s.io对应于yaml中的spec.group
  name: foos.samplecontroller.k8s.io
spec:
  # 这个名称对应了未来的k8s rest api路径: /apis/<group>/<version>
  group: samplecontroller.k8s.io
  # 版本列表，不同的版本中可定义不同属性，同样对应k8s rest api中的version
  versions:
    # 版本名称
    - name: v1alpha1
      # 是否启用这个版本的flag
      served: true
      # 是否存储，只能有一个版本被设置为true
      storage: true
	  # 1.16中新增加的属性
      schema: # 重点，这里便是资源的字段定义模板,
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                deploymentName:
                  type: string
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 10
            status:
              type: object
              properties:
                availableReplicas:
                  type: integer
  # crd的定义范围，ns级还是cluster级
  scope: Namespaced
  # crd的名称
  names:
    # 复数的名称,要求小写
    plural: foos
    # 单数的名称,要求小写
    singular: foo
    # 资源类型名称，首字母大写+驼峰
    kind: Foo
    # 缩写定义,要求小写
    shortNames:
    - fo
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

