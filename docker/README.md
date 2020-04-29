# docker source code analysis

docker的代码分为两部分，分别为docker client和docker engine，其中client表示docker客户端，向docker daemon发送请求;engine表示服务端，接收http请求后执行相应操作。

代码参考[docker 19.0版本](https://github.com/docker/docker-ce/tree/19.03)
