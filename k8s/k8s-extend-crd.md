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
模板编写后，可以通过kubectl在k8s集群上创建资源类型：
```
[root@master134 crd]# kubectl apply -f crd.yaml 
customresourcedefinition.apiextensions.k8s.io/foos.samplecontroller.k8s.io created
[root@master134 crd]# kubectl get crd
NAME                           CREATED AT
foos.samplecontroller.k8s.io   2022-07-27T06:58:25Z
[root@master134 crd]# kubectl api-resources |grep foo
foos                                           samplecontroller.k8s.io/v1alpha1       true         Foo
```

接下来，便可以根据crd的模板定义资源对象的定义，定义位于`/artifacts/examples/example-foo.yaml`中，内容为：
```
apiVersion: samplecontroller.k8s.io/v1alpha1
kind: Foo
metadata:
  name: example-foo
spec:
  deploymentName: example-foo
  replicas: 1
```
通过kubectl进行资源对象的创建：
```
[root@master134 crd]# kubectl get foo
NAME          AGE
example-foo   69s
[root@master134 crd]# kubectl describe foo example-foo 
Name:         example-foo
Namespace:    default
Labels:       <none>
Annotations:  <none>
API Version:  samplecontroller.k8s.io/v1alpha1
Kind:         Foo
Metadata:
  Creation Timestamp:  2022-07-27T07:07:08Z
  Generation:          1
  Managed Fields:
    API Version:  samplecontroller.k8s.io/v1alpha1
    Fields Type:  FieldsV1
    fieldsV1:
      f:metadata:
        f:annotations:
          .:
          f:kubectl.kubernetes.io/last-applied-configuration:
      f:spec:
        .:
        f:deploymentName:
        f:replicas:
    Manager:         kubectl-client-side-apply
    Operation:       Update
    Time:            2022-07-27T07:07:08Z
  Resource Version:  1188243
  UID:               d667dd2a-adb4-4427-86da-53c5de8ff955
Spec:
  Deployment Name:  example-foo
  Replicas:         1
Events:             <none>
```


### CRD控制器实现

上文在k8s上创建一个用户定义的资源对象，但它仅仅是在etcd上新增了一条记录，本质上并没有什么意义。多数情况下，还要针对CRD定义提供对应的CRD控制器（CRD Controller），用来完成CRD资源被创建后，执行的后续业务操作，比如pod被创建后执行的调度等。CRD控制器只需要遵循Kubernetes的控制器开发规范，并基于client-go进行调用，并实现 Informer、ResourceEventHandler、Workqueue等组件逻辑即可。


#### 控制器原理

CRD控制器的工作流，可分为监听(watch & delta FIFO )、同步(local store)、触发(event handler)三个步骤：

![image](../images/k8s/k8s-custom-controller.png)

1. Controller首先会通过Informer，从K8s的API Server中获取它所关心的对象，比如这里的Foo对象。而Informer在初始化时，会使用我们生成的k8s client透过Reflector的List&Watch机制跟API Server建立连接，不断地监听Foo对象实例的变化。一旦APIServer端有新的Foo 实例被创建、删除或者更新，Reflector都会收到*事件通知*。该事件及它对应的 API对象会被放进一个Delta FIFO Queue中。

2. Informer 根据这些事件的类型，**触发我们编写并注册的ResourceEventHandler事件回调**，完成业务动作的触发。

3. LocalStore的作用主要用于缓存APIServer中的对象信息，并定期进行资源同步，供Informer查询调用，降低APIServer的访问压力。

综上，对于开发者而言，我们只需要关心事件回调的具体实现。


#### sample-controller分析

1. 目录结构说明

对于CRD控制器实现，需要自定义的核心实现目录如下，主要是/pkg/apis中字段对象的定义：
```
└── controller.go 					# 核心业务，需要自行编写
└── main.go 						# crd程序的启动函数
└── pkg
	└── generated 					# 可以通过k8s工具，根据apis目录中的定义生成
        ...							# k8s自动生成代码，省略，包括了client set/informers/listers	
    └── apis
        └── sample-controller
            ├── register.go  		# 全局变量
            └── v1alpha1			# 版本号
                ├── doc.go  		# 代码自动生成注释
                ├── register.go 	# 
                ├── types.go 		# 重要，定义资源对象的struct
			
```

- `/pkg/apis/sample-controller/register.go`主要用来存放全局变量，比如定义了api组：
```
package samplecontroller

// GroupName is the group name used in this package
const (
	GroupName = "samplecontroller.k8s.io"
)
```

- `/pkg/apis/sample-controller/v1alpha1/doc.go`主要通过注释(前两行，Kubernetes进行代码生成要用的Annotation 风格的注释)定义代码生成时所需的信息
```
// +k8s:deepcopy-gen=package  意思是，请为整个包里的所有类型定义自动生成 DeepCopy 方法；
// +groupName=samplecontroller.k8s.io 定义了这个包对应的crddemo API 组的名字

// Package v1alpha1 is the v1alpha1 version of the API.
package v1alpha1 // import "k8s.io/sample-controller/pkg/apis/samplecontroller/v1alpha1"
```

- `/pkg/apis/sample-controller/v1alpha1/types.go`则定义了字段对象对应的struct结构体，同样这里也用到了k8s的注释：

```
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)
// 意思是：请为下面资源类型生成对应的 Client 代码。
// +genclient  
// 意思是：请在生成 DeepCopy 的时候，实现 Kubernetes 提供的 runtime.Object 接口。否则，在某些版本的 Kubernetes 里，你的这个类型定义会出现编译错误。
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object 

// Foo is a specification for a Foo resource
type Foo struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   FooSpec   `json:"spec"`
	Status FooStatus `json:"status"`
}

// FooSpec is the spec for a Foo resource
type FooSpec struct {
	DeploymentName string `json:"deploymentName"`
	Replicas       *int32 `json:"replicas"`
}

// FooStatus is the status for a Foo resource
type FooStatus struct {
	AvailableReplicas int32 `json:"availableReplicas"`
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// FooList is a list of Foo resources
// 复数形式，用来描述一组 Foo对象应该包括哪些字段。
// 之所以需要这样一个类型，是因为在 Kubernetes 中，获取所有某对象的 List() 方法，返回值都是List 类型，
// 而不是某类型的数组。所以代码上一定要做区分
type FooList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata"`
	Items []Foo `json:"items"`
}
```

- `/pkg/apis/sample-controller/v1alpha1/register.go`，作用是注册一个类型（Type）给 APIServer，这里除了addKnowTypes方法需根据实际情况微调，其他方法都是固定实现：
```
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"

	samplecontroller "k8s.io/sample-controller/pkg/apis/samplecontroller"
)

// SchemeGroupVersion is group version used to register these objects
var SchemeGroupVersion = schema.GroupVersion{Group: samplecontroller.GroupName, Version: "v1alpha1"}

// Kind takes an unqualified kind and returns back a Group qualified GroupKind
func Kind(kind string) schema.GroupKind {
	return SchemeGroupVersion.WithKind(kind).GroupKind()
}

// Resource takes an unqualified resource and returns a Group qualified GroupResource
func Resource(resource string) schema.GroupResource {
	return SchemeGroupVersion.WithResource(resource).GroupResource()
}

var (
	// SchemeBuilder initializes a scheme builder
	SchemeBuilder = runtime.NewSchemeBuilder(addKnownTypes)
	// AddToScheme is a global function that registers this API group & version to a scheme
	AddToScheme = SchemeBuilder.AddToScheme
)

// Adds the list of known types to Scheme.
// Foo 资源类型在服务器端的注册的工作，APIServer 会自动帮我们完成
// 但与之对应的，我们还需要Kubernetes在后面生成客户端的时候，知道Foo以及FooList类型的定义
func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(SchemeGroupVersion,
		&Foo{},
		&FooList{},
	)
	metav1.AddToGroupVersion(scheme, SchemeGroupVersion)
	return nil
}
```

接下来，通过官方提供的代码生成工具`k8s.io/code-generator`，就能补全剩下的informer/lister/clientset实现，比如参考如下脚本：
```
#!/bin/bash

set -x

ROOT_PACKAGE="./sample-controller"
CUSTOM_RESOURCE_NAME="foo"
CUSTOM_RESOURCE_VERSION="v1alpha1"
GO111MODULE=off

# 安装k8s.io/code-generator
[[ -d $GOPATH/src/k8s.io/code-generator ]] || go get -u k8s.io/code-generator/...

# 执行代码自动生成，其中pkg/client是生成目标目录，pkg/apis是类型定义目录
cd $GOPATH/src/k8s.io/code-generator && ./generate-groups.sh all "$ROOT_PACKAGE/pkg/client" "$ROOT_PACKAGE/pkg/apis" "$CUSTOM_RESOURCE_NAME:$CUSTOM_RESOURCE_VERSION"
```


2. 接下来分析sample-controller的main函数：

```
func main(){
	...
	klog.InitFlags(nil)
	flag.Parse()
	//一个无缓冲的channel作为开关
	stopCh := signals.SetupSignalHandler()
	//kubeconfig实体，主要就是封装了kubeconfig
	//sample-controller程序编译后，拉起时提供了2个参数，一个是kubeconfig文件路径，另一个就是apiserver地址
	cfg, err := clientcmd.BuildConfigFromFlags(masterURL, kubeconfig)
	...
	//原生kubeClient，这里定义此client主要是用于后续监听deloyment对象以及与Foo对象做联动使用
	kubeClient, err := kubernetes.NewForConfig(cfg)
	...
	//定制client
	exampleClient, err := clientset.NewForConfig(cfg)
	...
}
```

其中`clientset.NewForConfig(cfg)`函数为自动实现，主要逻辑如下：

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


回到main函数，client set定义完毕后，创建informerFactory，之前定义的client-set作为入参:
```
	kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, time.Second*30)
	
	//informerFactory工厂类， 这里注入我们通过代码生成的client
    //clent主要用于和API Server 进行通信，实现ListAndWatch
	//informers.NewSharedInformerFactory为自动生成实现
	exampleInformerFactory := informers.NewSharedInformerFactory(exampleClient, time.Second*30)
```
其中exampleInformerFactory为自定义sharedInformerFactory，实现了自定义的SharedInformerFactory接口，这个接口提供了所有k8s资源对象的informer，这里使用了[工厂模式](https://books.studygolang.com/go-patterns/)：
```// SharedInformerFactory provides shared informers for resources in all known
// API group versions.
type SharedInformerFactory interface {
	internalinterfaces.SharedInformerFactory
	ForResource(resource schema.GroupVersionResource) (GenericInformer, error)
	WaitForCacheSync(stopCh <-chan struct{}) map[reflect.Type]bool

	Samplecontroller() samplecontroller.Interface
}

```
继承关系为：sharedInformerFactory-实现->SharedInformerFactory-继承->internalinterfaces.SharedInformerFactory

回到main函数，接下来**根据clientset自定义crd的controller**，controller中主要完成了对于事件监听回调函数的定义:
```
	//自定义控制器,具体实现下文说明
	controller := NewController(kubeClient, exampleClient,
		kubeInformerFactory.Apps().V1().Deployments(),
		exampleInformerFactory.Samplecontroller().V1alpha1().Foos())
		
	kubeInformerFactory.Start(stopCh)
	exampleInformerFactory.Start(stopCh)

	if err = controller.Run(2, stopCh); err != nil {
		klog.Fatalf("Error running controller: %s", err.Error())
	}		
```

controller创建完成后，启动informer:
```
	kubeInformerFactory.Start(stopCh)
	exampleInformerFactory.Start(stopCh)
	if err = controller.Run(2, stopCh); err != nil {
		...
	}
```

最后，调用controller的Run函数，去处理k8s的资源变化。


3. Controller的实现

Controller的定义如下：
```
type Controller struct {
	//k8s client set，用于后续的deployment对象处理
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
进入New函数内部，主要工作就是创建controller，添加一个work queue, 并向informer中添加even handler，具体实现如下：
```
func NewController(
	kubeclientset kubernetes.Interface,
	sampleclientset clientset.Interface,
	deploymentInformer appsinformers.DeploymentInformer,
	fooInformer informers.FooInformer) *Controller {

	utilruntime.Must(samplescheme.AddToScheme(scheme.Scheme))
    ...
	eventBroadcaster := record.NewBroadcaster()
	eventBroadcaster.StartLogging(klog.Infof)
	eventBroadcaster.StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: kubeclientset.CoreV1().Events("")})
	recorder := eventBroadcaster.NewRecorder(scheme.Scheme, corev1.EventSource{Component: controllerAgentName})

	//使用client和前面创建的 Informer，初始化了自定义控制器
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

	...
	// 定义不同informer的eventhandler函数，此处将事件写入到了工作队列中
	fooInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		//简单的将资源对象入队
		AddFunc: controller.enqueueFoo,
		UpdateFunc: func(old, new interface{}) {
			controller.enqueueFoo(new)
		},
	})
	//这里主要用于演示deployment与foo对象的联动
	deploymentInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		//handleObject会根据depolyment的owner reference来判断
		//假如创建的deployment中从属于某个foo对象，则通过lister查找出该foo对象后，再次对其进行入队处理
		//再次入队的目的是为了保证foo与deployment的动态稳定，将在后续分析
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

Run函数的实现为，开启N个work process去处理work queue中的消息：
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
	//获取foo中定义的deployment名称
	deploymentName := foo.Spec.DeploymentName
	// Get the deployment with the name specified in Foo.spec
	//查询apiserver是否有此deployment的定义
	deployment, err := c.deploymentsLister.Deployments(foo.Namespace).Get(deploymentName)
	//如果没有，就新建一个deployment，并将其OwnerReferences.Kind指定为Foo
	if errors.IsNotFound(err) {
		deployment, err = c.kubeclientset.AppsV1().Deployments(foo.Namespace).Create(context.TODO(), newDeployment(foo), metav1.CreateOptions{})
	}
	...
	if !metav1.IsControlledBy(deployment, foo) {
		msg := fmt.Sprintf(MessageResourceExists, deployment.Name)
		c.recorder.Event(foo, corev1.EventTypeWarning, ErrResourceExists, msg)
		return fmt.Errorf(msg)
	}
	...
	//同步更新副本数量
	if foo.Spec.Replicas != nil && *foo.Spec.Replicas != *deployment.Spec.Replicas {
		klog.V(4).Infof("Foo %s replicas: %d, deployment replicas: %d", name, *foo.Spec.Replicas, *deployment.Spec.Replicas)
		deployment, err = c.kubeclientset.AppsV1().Deployments(foo.Namespace).Update(context.TODO(), newDeployment(foo), metav1.UpdateOptions{})
	}
	...
	//当一切就绪后，更新资源状态，这里会调用foo的client set去创建foo类型的资源对象
	err = c.updateFooStatus(foo, deployment)
	...
	//发布状态事件，供kubectl describe查看
	c.recorder.Event(foo, corev1.EventTypeNormal, SuccessSynced, MessageResourceSynced)
	return nil
}
```

4. Foo与Deployment的动态平衡

从上文分析中可以看到，当创建一个foo资源对象，会执行以下动作：
- 



