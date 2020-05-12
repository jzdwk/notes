# docker client

docker client的入口函数位于docker-ce/components/cli/cmd/docker/docker.go，主要作用就是**接收docker client**命令，并封装为http请求发送给docker daemon.

## docker cli

首先就是docker cli的创建，```dockerCli, err := command.NewDockerCli()```,DockerCli封装了命令行客户端，其内容如下：

```
type DockerCli struct {
	configFile         *configfile.ConfigFile  //配置文件
	in                 *streams.In //标准输入
	out                *streams.Out //标准输出
	err                io.Writer 
	client             client.APIClient  //client接口，和daemon通信
	serverInfo         ServerInfo 
	clientInfo         *ClientInfo
	contentTrust       bool  
	contextStore       store.Store //client端环境？
	currentContext     string
	dockerEndpoint     docker.Endpoint //TLS相关数据封装
	contextStoreConfig store.Config
}
```

newDockerCli()函数主要用于封装dockercli，包括了stdin/stdout以及contextStore字段的默认设置。之后直接执行runDocker，此函数为client的核心函数，代码如下：

```
	tcmd := newDockerCommand(dockerCli)
	cmd, args, err := tcmd.HandleGlobalFlags()
	...
	if err := tcmd.Initialize(); err != nil 
	...
	args, os.Args, err = processAliases(dockerCli, cmd, args, os.Args)
	...
	if len(args) > 0 {
		if _, _, err := cmd.Find(args); err != nil {
			err := tryPluginRun(dockerCli, cmd, args[0])
			if !pluginmanager.IsNotFound(err) {
				return err
			}
			// For plugin not found we fall through to
			// cmd.Execute() which deals with reporting
			// "command not found" in a consistent way.
		}
	}
	cmd.SetArgs(args)
	return cmd.Execute()
```

## docker command

进入newDockerCommand函数，首先，通过cobra库定义了docker client的模板，可以看到Use项中的命令行定义 docker \[options\]...，cmd的最终执行也是通过cobra操作。cmd的定义如下：

```
cmd := &cobra.Command{
		Use:              "docker [OPTIONS] COMMAND [ARG...]",
		Short:            "A self-sufficient runtime for containers",
		SilenceUsage:     true,
		SilenceErrors:    true,
		TraverseChildren: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return command.ShowHelp(dockerCli.Err())(cmd, args)
			}
			return fmt.Errorf("docker: '%s' is not a docker command.\nSee 'docker --help'", args[0])

		},
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			return isSupported(cmd, dockerCli)
		},
		Version:               fmt.Sprintf("%s, build %s", version.Version, version.GitCommit),
		DisableFlagsInUseLine: true,
	}
```

cobra中，将命令按层级进行了划分，如docker是docker pull的父命令，在加载docker pull时，首先对docker进行了加载。另外，Command中定义了一些**类似java的切片函数**，用于执行前后以及错误的处理，注意RunE的定义，意思为执行这个函数定义，并将err返回，后面的所有命令都将通过这个函数具体执行：

```
	// PersistentPreRun: children of this command will inherit and execute.
	PersistentPreRun func(cmd *Command, args []string)
	// PersistentPreRunE: PersistentPreRun but returns an error.
	PersistentPreRunE func(cmd *Command, args []string) error
	// PreRun: children of this command will not inherit.
	PreRun func(cmd *Command, args []string)
	// PreRunE: PreRun but returns an error.
	PreRunE func(cmd *Command, args []string) error
	// Run: Typically the actual work function. Most commands will only implement this.
	Run func(cmd *Command, args []string)
	// RunE: Run but returns an error.
	RunE func(cmd *Command, args []string) error
	// PostRun: run after the Run command.
	PostRun func(cmd *Command, args []string)
	// PostRunE: PostRun but returns an error.
	PostRunE func(cmd *Command, args []string) error
	// PersistentPostRun: children of this command will inherit and execute after PostRun.
	PersistentPostRun func(cmd *Command, args []string)
	// PersistentPostRunE: PersistentPostRun but returns an error.
	PersistentPostRunE func(cmd *Command, args []string) error
```

接下来，先是加载docker顶层命令，如help等，以及一些error后的处理函数，加载docker命令的函数为`commands.AddCommands(cmd, dockerCli)`，其具体实现如下：

```
cmd.AddCommand(
		...
		// image
		image.NewImageCommand(dockerCli),
		image.NewBuildCommand(dockerCli),
		...
		// legacy commands may be hidden
		hide(system.NewEventsCommand(dockerCli)),
		...
	)
```

篇幅原因，不全部贴出，以NewImage为例子，可以看到其定义为：

```
	cmd := &cobra.Command{
		Use:   "image",
		Short: "Manage images",
		Args:  cli.NoArgs,
		RunE:  command.ShowHelp(dockerCli.Err()),
	}
	cmd.AddCommand(
		...
		NewPushCommand(dockerCli),
		...
	)
	return cmd
```

Use域使用了image，其父命令为docker，因此组成docker image，而image命令下，又定义了如push等命令，push中的代码结构和此类似：

```
	var opts pushOptions
	cmd := &cobra.Command{
		Use:   "push [OPTIONS] NAME[:TAG]",
		Short: "Push an image or a repository to a registry",
		Args:  cli.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.remote = args[0]
			return RunPush(dockerCli, opts)
		},
	}
	flags := cmd.Flags()
	flags.BoolVarP(&opts.quiet, "quiet", "q", false, "Suppress verbose output")
	command.AddTrustSigningFlags(flags, &opts.untrusted, dockerCli.ContentTrustEnabled())
	return cmd
```

其他的命令定义与此类似。最终，DockerCommand创建定义完成并返回。

## client执行

回忆刚才的image push，主要看RunE中的定义，根据传入参数以及cmd本身，调用了RunPush，而RunPush则进行了http请求的具体发送，并将结果返回stdout：

```
	...
	ctx := context.Background()
	...
	responseBody, err := imagePushPrivileged(ctx, dockerCli, authConfig, ref, requestPrivilege)
	if err != nil {
		return err
	}
	...
```

因此，Command命令的RunE中定义了函数的具体执行逻辑。当dockerDeamon返回后，执行的逻辑如下：

```
	tcmd := newDockerCommand(dockerCli)
	...
	cmd, args, err := tcmd.HandleGlobalFlags()
	...
	if err := tcmd.Initialize(); err != nil {
		return err
	}
	args, os.Args, err = processAliases(dockerCli, cmd, args, os.Args)
	if len(args) > 0 {
		if _, _, err := cmd.Find(args); err != nil {
			err := tryPluginRun(dockerCli, cmd, args[0])
			if !pluginmanager.IsNotFound(err) {
				return err
			}
		}
	}
	cmd.SetArgs(args)
	return cmd.Execute()
```

其核心代码为cmd.Execute()，进入代码即cmd的实际执行流程，这段代码是cobra实现的，大致流程为首先执行parent命令的定义，最终执行自己（有点像java spring的IOC中的引用链处理），若RunE定义不为空，执行RunE定义的函数。