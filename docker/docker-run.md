# docker run 

## client

当执行`docker run`命令，会执行`.../docker-ce/components/cli/cli/command/container/run.go`中的`func NewRunCommand(dockerCli command.Cli)`,主要看`runRun`函数:
```go
//docker run 后携带的命令主要分为了runOptinos和containerOptiuons
func runRun(dockerCli command.Cli, flags *pflag.FlagSet, ropts *runOptions, copts *containerOptions) error {
	//解析各种config options，这里面的config主要有
	//config ：包含着容器的配置数据，其内容来自于../docker/image/overlay2/imagedb/content/sha256/{iamgeID}中的config段落。比如hostname，user;默认omitempty设置，如果为空置则忽略字段。
    //hostConfig ： 与主机相关的配置，即容器与主键之间的端口映射、日志、volume等等
    //networkingConfig ：容器网络相关的配置。
	...
	//验证api
	if err = validateAPIVersion(containerConfig, dockerCli.Client().ClientVersion()); err != nil {
		...
	}
	return runContainer(dockerCli, ropts, copts, containerConfig)
}
```
上述代码中的opt解析细节暂时不关注，继续:
```go
// nolint: gocyclo
func runContainer(dockerCli command.Cli, opts *runOptions, copts *containerOptions, containerConfig *containerConfig) error {
	...
	createResponse, err := createContainer(ctx, dockerCli, containerConfig, &opts.createOptions)
	...
	// start the container
	if err := client.ContainerStart(ctx, createResponse.ID, types.ContainerStartOptions{}); err != nil {
		...
	}
	... 
	return nil
}
```
这里最关键的就是`createContainer`和`ContainerStart`，也就是说，docker run将分为**create**和**start**两个阶段去做。首先看create的过程：
```go
func createContainer(ctx context.Context, dockerCli command.Cli, containerConfig *containerConfig, opts *createOptions) (*container.ContainerCreateCreatedBody, error) {
	...
	//通过创建一个containerID的文件，检测该containerID是否在运行,这个id即来自前文的config
	containerIDFile, err := newCIDFile(hostConfig.ContainerIDFile)
	...
	ref, err := reference.ParseAnyReference(config.Image)
	...
	//docker trust相关的image验签，详细的docker trust可以参考文档https://docs.docker.com/engine/security/trust/content_trust/
	if named, ok := ref.(reference.Named); ok {
		namedRef = reference.TagNameOnly(named)
		if taggedRef, ok := namedRef.(reference.NamedTagged); ok && !opts.untrusted {
			var err error
			trustedRef, err = image.TrustedReference(ctx, dockerCli, taggedRef, nil)
			...
			config.Image = reference.FamiliarString(trustedRef)
		}
	}
	//定义image pull，如果本地没有run指定的image，则先pull，再create
	pullAndTagImage := func() error {
		if err := pullImage(ctx, dockerCli, config.Image, opts.platform, stderr); err != nil {
			return err
		}
		if taggedRef, ok := namedRef.(reference.NamedTagged); ok && trustedRef != nil {
			return image.TagTrusted(ctx, dockerCli, trustedRef, taggedRef)
		}
		return nil
	}
	//always pull
	if opts.pull == PullImageAlways {
		if err := pullAndTagImage(); err != nil {
			return nil, err
		}
	}

	response, err := dockerCli.Client().ContainerCreate(ctx, config, hostConfig, networkingConfig, opts.name)
	if err != nil {
		// Pull image if it does not exist locally and we have the PullImageMissing option. Default behavior.
		if apiclient.IsErrNotFound(err) && namedRef != nil && opts.pull == PullImageMissing {
			// we don't want to write to stdout anything apart from container.ID
			fmt.Fprintf(stderr, "Unable to find image '%s' locally\n", reference.FamiliarString(namedRef))
			if err := pullAndTagImage(); err != nil {
				return nil, err
			}
			var retryErr error
			//pull完了，create container
			response, retryErr = dockerCli.Client().ContainerCreate(ctx, config, hostConfig, networkingConfig, opts.name)
			...
		}...
	}
	...
	err = containerIDFile.Write(response.ID)
	return &response, err
}
```
在client端大致的过程就是先pull镜像，然后调用ContainerCreate创建容器。这个创建的过程即向daemon发送http请求：
```go
func (cli *Client) ContainerCreate(ctx context.Context, config *container.Config, hostConfig *container.HostConfig, networkingConfig *network.NetworkingConfig, containerName string) (container.ContainerCreateCreatedBody, error) {
	var response container.ContainerCreateCreatedBody
	//version check
	...
	//http query	
	query := url.Values{}
	if containerName != "" {
		query.Set("name", containerName)
	}
	//http body
	body := configWrapper{
		Config:           config,
		HostConfig:       hostConfig,
		NetworkingConfig: networkingConfig,
	}
	//do post
	serverResp, err := cli.post(ctx, "/containers/create", query, body, nil)
	defer ensureReaderClosed(serverResp)
	...
	err = json.NewDecoder(serverResp.body).Decode(&response)
	return response, err
}
```
daemon端的处理随后分析。ContainerCreate的返回中包含了Container的ID，因此，对于下一过程ContainerStart，其主要是向Daemon发送：
```go
func (cli *Client) ContainerStart(ctx context.Context, containerID string, options types.ContainerStartOptions) error {
	query := url.Values{}
	if len(options.CheckpointID) != 0 {
		query.Set("checkpoint", options.CheckpointID)
	}
	if len(options.CheckpointDir) != 0 {
		query.Set("checkpoint-dir", options.CheckpointDir)
	}
	resp, err := cli.post(ctx, "/containers/"+containerID+"/start", query, nil, nil)
	ensureReaderClosed(resp)
	return err
}
```

## daemon

### create

### start