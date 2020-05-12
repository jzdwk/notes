# kong ingress controller

这里尝试对kong ingress controller的实现进行分析，代码基于[0.8.x版本](https://github.com/Kong/kubernetes-ingress-controller/tree/0.8.x)

kong ingress controller的最主要作用就是在api server监听各种k8s资源对象，包括crd，当遇到策略下发时，通过kong sdk调用api admin去执行策略下发。




