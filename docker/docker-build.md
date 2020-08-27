# docker build

[docker build](https://docs.docker.com/engine/reference/commandline/build/) 的作用为根据dockerfile文件，创建镜像。

其中dockerfile的位置可以位于当前目录/指定目录/URL，具体的语法[参考官方](https://docs.docker.com/engine/reference/builder/) 

## client 

docker build同样是C/S方式实现，client端的主要作用就是根据命令，通过不同方式获取dockerfile文件以及其他配置信息。获取的方式有指定目录、指定URL和标准输入。获取文件后，在根据配置信息对dockerfile以及相关的目录进行压缩，成tar包后传输。

client端的代码位于`components/cli/cli/command/commands/commands.go`的`image.NewBuildCommand(dockerCli)`函数，最终进入`runBuild`函数：

```go
func runBuild(dockerCli command.Cli, options buildOptions) error {
	//buildkit工具的判断
	buildkitEnabled, err := command.BuildKitEnabled(dockerCli.ServerInfo())
	...
	if buildkitEnabled {
		return runBuildBuildKit(dockerCli, options)
	}
	...
```
上述代码首先判断是否使用了[build kit](https://docs.docker.com/develop/develop-images/build_enhancements/) 作为构建工具，改工具在18.09版本后支持。用于更高性能的镜像build。使用buildkit的构建将执行`runBuildBuildKit`,这里暂时忽略。

```go
	//变量定义
	...
	//如果dockerfile来自标准输入，从stdin读取，命令上要以“-”开头
	if options.dockerfileFromStdin() {
		if options.contextFromStdin() {
			return errStdinConflict
		}
		dockerfileCtx = dockerCli.In()
	}
	//buff初始化
	...
	//build后如果需要将imageId写入文件，先检查，对应 --iidfile选项
	if options.imageIDFile != "" {
		// Avoid leaving a stale file if we eventually fail
		if err := os.Remove(options.imageIDFile); err != nil && !os.IsNotExist(err) {
			return errors.Wrap(err, "Removing image ID file")
		}
	}
	...
	//不同的dockerfile获取方式
	switch {
	case options.contextFromStdin():
		// buildCtx is tar archive. if stdin was dockerfile then it is wrapped
		buildCtx, relDockerfile, err = build.GetContextFromReader(dockerCli.In(), options.dockerfileName)
	case isLocalDir(specifiedContext):
		contextDir, relDockerfile, err = build.GetContextFromLocalDir(specifiedContext, options.dockerfileName)
		if err == nil && strings.HasPrefix(relDockerfile, ".."+string(filepath.Separator)) {
			// Dockerfile is outside of build-context; read the Dockerfile and pass it as dockerfileCtx
			dockerfileCtx, err = os.Open(options.dockerfileName)
			if err != nil {
				return errors.Errorf("unable to open Dockerfile: %v", err)
			}
			defer dockerfileCtx.Close()
		}
	case urlutil.IsGitURL(specifiedContext):
		tempDir, relDockerfile, err = build.GetContextFromGitURL(specifiedContext, options.dockerfileName)
	case urlutil.IsURL(specifiedContext):
		//URL 方式，返回的是一个tar包，需要额外处理
		buildCtx, relDockerfile, err = build.GetContextFromURL(progBuff, specifiedContext, options.dockerfileName)
	default:
		return errors.Errorf("unable to prepare context: path %q not found", specifiedContext)
	}
```
接下来主要是对dockerfile文件进行操作，并最终封装为buildctx进行post提交：
```go
	//buildctx为空表示从目录读取，同时读取ignore文件，并在最终压缩为tar包时忽略。
	//注意buildctx表示dockerfile对应的tar包，dockerfileCtx表示dockerfile文件
	// read from a directory into tar archive
	if buildCtx == nil {
		excludes, err := build.ReadDockerignore(contextDir)
		...
		if err := build.ValidateContextDirectory(contextDir, excludes); err != nil {
			return errors.Errorf("error checking context: '%s'.", err)
		}
		// And canonicalize dockerfile name to a platform-independent one
		relDockerfile = archive.CanonicalTarNameForPath(relDockerfile)
		excludes = build.TrimBuildFilesFromExcludes(excludes, relDockerfile, options.dockerfileFromStdin())
		buildCtx, err = archive.TarWithOptions(contextDir, &archive.TarOptions{
			ExcludePatterns: excludes,
			ChownOpts:       &idtools.Identity{UID: 0, GID: 0},
		})
		...
	}

	//将dockerfile的名称增加随机数,即.dockerfile.xxx,以及.dockerignore.xxxx，同时并返回新的tar包
	// replace Dockerfile if it was added from stdin or a file outside the build-context, and there is archive context
	if dockerfileCtx != nil && buildCtx != nil {
		buildCtx, relDockerfile, err = build.AddDockerfileToBuildContext(dockerfileCtx, buildCtx)
		...
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	//如果dockerfile中依赖的image为untrusted，即以image:tag方式声明，则替换为digest
	var resolvedTags []*resolvedTag
	if !options.untrusted {
		translator := func(ctx context.Context, ref reference.NamedTagged) (reference.Canonical, error) {
			return TrustedReference(ctx, dockerCli, ref, nil)
		}
		// if there is a tar wrapper, the dockerfile needs to be replaced inside it
		if buildCtx != nil {
			// Wrap the tar archive to replace the Dockerfile entry with the rewritten
			// Dockerfile which uses trusted pulls.
			buildCtx = replaceDockerfileForContentTrust(ctx, buildCtx, relDockerfile, translator, &resolvedTags)
		} else if dockerfileCtx != nil {
			// if there was not archive context still do the possible replacements in Dockerfile
			newDockerfile, _, err := rewriteDockerfileFromForContentTrust(ctx, dockerfileCtx, translator)
			...
			dockerfileCtx = ioutil.NopCloser(bytes.NewBuffer(newDockerfile))
		}
	}
	//压缩，如果option指定的话
	if options.compress {
		buildCtx, err = build.Compress(buildCtx)
		...
	}

	...
	//最终封装为一个body,这个body中其实就是dockerfile的内容
	var body io.Reader
	if buildCtx != nil {
		body = progress.NewProgressReader(buildCtx, progressOutput, 0, "", "Sending build context to Docker daemon")
	}
	//build的配置信息
	configFile := dockerCli.ConfigFile()
	creds, _ := configFile.GetAllCredentials()
	authConfigs := make(map[string]types.AuthConfig, len(creds))
	for k, auth := range creds {
		authConfigs[k] = types.AuthConfig(auth)
	}
	buildOptions := imageBuildOptions(dockerCli, options)
	buildOptions.Version = types.BuilderV1
	buildOptions.Dockerfile = relDockerfile
	buildOptions.AuthConfigs = authConfigs
	buildOptions.RemoteContext = remote
	//发送http请求
	response, err := dockerCli.Client().ImageBuild(ctx, body, buildOptions)
	if err != nil {
		if options.quiet {
			fmt.Fprintf(dockerCli.Err(), "%s", progBuff)
		}
		cancel()
		return err
	}
	defer response.Body.Close()
	...
}
```
可以看到client端的所有操作都是围绕dockerfile，并最终将dockerfile内容以及build的选项一起post给daemon。其中的build的选项在http头的`X-Registry-Config`,dockerfile在http body，类型为`headers.Set("Content-Type", "application/x-tar")`。

## daemon

daemon对于docker build的api入口位于`engine/api/server/router/build/build.go`中的`initRoutes的`方法。进入执行函数：
```go
func (br *buildRouter) postBuild(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	var (
		notVerboseBuffer = bytes.NewBuffer(nil)
		version          = httputils.VersionFromContext(ctx)
	)

	w.Header().Set("Content-Type", "application/json")
	//body里为dockerfile
	body := r.Body
	var ww io.Writer = w
	...
	output := ioutils.NewWriteFlusher(ww)
	defer output.Close()
	errf := func(err error) error {
		...error handler
	}
	//根据client请求中携带的build option，封装到buildOptions结构体。
	buildOptions, err := newImageBuildOptions(ctx, r)
	...
	//output progress等处理
	...
	//核心调用
	imgID, err := br.backend.Build(ctx, backend.BuildConfig{
		Source:         body,  //dockerfile
		Options:        buildOptions, //build option
		ProgressWriter: buildProgressWriter(out, wantAux, createProgressReader), //stdout
	})
	...
	// Everything worked so if -q was provided the output from the daemon
	// should be just the image ID and we'll print that to stdout.
	if buildOptions.SuppressOutput {
		fmt.Fprintln(streamformatter.NewStdoutWriter(output), imgID)
	}
	return nil
}
```

### requset handler

上述代码主要对req请求中的body和header里携带的build option进行解析，最终调用`backend`的`Build`函数：
```go
//config中封装了body,option
func (b *Backend) Build(ctx context.Context, config backend.BuildConfig) (string, error) {
	options := config.Options
	useBuildKit := options.Version == types.BuilderBuildKit
	tagger, err := NewTagger(b.imageComponent, config.ProgressWriter.StdoutFormatter, options.Tags)
	...
	var build *builder.Result
	if useBuildKit {
		build, err = b.buildkit.Build(ctx, config)
		if err != nil {
			return "", err
		}
	} else {
		//核心逻辑
		build, err = b.builder.Build(ctx, config)
		...
	}
	...
	//处理imageID
	var imageID = build.ImageID
	if options.Squash {
		if imageID, err = squashBuild(build, b.imageComponent); err != nil {
			return "", err
		}
		if config.ProgressWriter.AuxFormatter != nil {
			if err = config.ProgressWriter.AuxFormatter.Emit("moby.image.id", types.BuildResult{ID: imageID}); err != nil {
				return "", err
			}
		}
	}
	if !useBuildKit {
		stdout := config.ProgressWriter.StdoutFormatter
		fmt.Fprintf(stdout, "Successfully built %s\n", stringid.TruncateID(imageID))
	}
	if imageID != "" {
		err = tagger.TagImages(image.ID(imageID))
	}
	return imageID, err
}
```
上述代码的核心逻辑就是`build, err = b.builder.Build(ctx, config)`,

### build

```go
func (bm *BuildManager) Build(ctx context.Context, config backend.BuildConfig) (*builder.Result, error) {
	...
	//根据config从网络或者本地目录等获取dockerfile内容
	source, dockerfile, err := remotecontext.Detect(config)
	...
	//io close
	...
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	...
	//
	builderOptions := builderOptions{
		Options:        config.Options,
		ProgressWriter: config.ProgressWriter,
		Backend:        bm.backend,
		PathCache:      bm.pathCache,
		IDMapping:      bm.idMapping,
	}
	//builder结构体封装
	b, err := newBuilder(ctx, builderOptions)
	...
	//builder构造
	return b.build(source, dockerfile)
}
```
整体逻辑就是首先new一个builder对象，然后调用builder的build方法，其中builder的定义如下：
```go
// Builder is a Dockerfile builder
// It implements the builder.Backend interface.
type Builder struct {
	options *types.ImageBuildOptions //docker build的option命令集合，即buildOptions

	Stdout io.Writer	//I/O相关，用于在std打印
	Stderr io.Writer
	Aux    *streamformatter.AuxFormatter
	Output io.Writer

	docker    builder.Backend
	clientCtx context.Context

	idMapping        *idtools.IdentityMapping
	disableCommit    bool
	imageSources     *imageSources
	pathCache        pathCache
	containerManager *containerManager
	imageProber      ImageProber
	platform         *specs.Platform
}
```
继续进入` b.build(source, dockerfile)`方法：
```go
// Build runs the Dockerfile builder by parsing the Dockerfile and executing
// the instructions from the file.
//source即dockerfile内容  dockerfile即文件名
func (b *Builder) build(source builder.Source, dockerfile *parser.Result) (*builder.Result, error) {
	defer b.imageSources.Unmount()
	//首先，对docker build的ARG命令进行解析，返回一个dockerfile中的阶段集合stages和ARG的参数metaArgs
	stages, metaArgs, err := instructions.Parse(dockerfile.AST)
	...
	//对应docker build --target命令，如果target不为空，取出在dockerfile中对应的阶段，并对stages剪裁
	if b.options.Target != "" {
		targetIx, found := instructions.HasStage(stages, b.options.Target)
		if !found {
			buildsFailed.WithValues(metricsBuildTargetNotReachableError).Inc()
			return nil, errdefs.InvalidParameter(errors.Errorf("failed to reach build target %s in Dockerfile", b.options.Target))
		}
		stages = stages[:targetIx+1]
	}
	//docker build --label的处理，将label加入最后一个阶段的stage的command中
	// Add 'LABEL' command specified by '--label' option to the last stage
	buildLabelOptions(b.options.Labels, stages)
	//执行构建
	dispatchState, err := b.dispatchDockerfileWithCancellation(stages, metaArgs, dockerfile.EscapeToken, source)
	...
	if dispatchState.imageID == "" {
		buildsFailed.WithValues(metricsDockerfileEmptyError).Inc()
		return nil, errors.New("No image was generated. Is your Dockerfile empty?")
	}
	return &builder.Result{ImageID: dispatchState.imageID, FromImage: dispatchState.baseImage}, nil
}
```
其中docker build target的作用为执行[多阶段build](https://docs.docker.com/develop/develop-images/multistage-build/) 这里暂时不考虑。

#### stage&command parse

上述代码首先解析dockerfile的内容，并返回一个**stages**数组，这个数组的每一个元素代表了build的一个*阶段*，那么这个阶段是什么东西？具体来看parse函数：
```go
stage的结构定义如下，可以看到
// Stage represents a single stage in a multi-stage build
type Stage struct {
	Name       string //阶段名称
	Commands   []Command //携带的命令
	BaseName   string 
	SourceCode string
	Platform   string
}

/ Parse a Dockerfile into a collection of buildable stages.
// metaArgs is a collection of ARG instructions that occur before the first FROM.
func Parse(ast *parser.Node) (stages []Stage, metaArgs []ArgCommand, err error) {
	for _, n := range ast.Children {
		//解析每一个节点，解析过程为一个switch-case，每一个case就是dockerfile里的一个关键字
		cmd, err := ParseInstruction(n)
		...
		//先把ARG加进去，他位于FROM之前
		if len(stages) == 0 {
			// meta arg case
			if a, isArg := cmd.(*ArgCommand); isArg {
				metaArgs = append(metaArgs, *a)
				continue
			}
		}
		//根据cmd的类型构造stage
		switch c := cmd.(type) {
		case *Stage:
			stages = append(stages, *c)
		case Command:
			stage, err := CurrentStage(stages)
			...
			stage.AddCommand(c)
		default:
			return nil, nil, errors.Errorf("%T is not a command type", cmd)
		}

	}
	return stages, metaArgs, nil
}
```
上述代码遍历了dockerfile的每小节（即每一个dockerfile命令），经过`ParseInstruction`的解析，返回stage或者command接口，`ParseInstruction`的功能就是解析过程为一个switch-case，每一个case就是dockerfile里的一个关键字,以`FROM`和`COPY`为例：

1. FROM 

```go
// ParseInstruction converts an AST to a typed instruction (either a command or a build stage beginning when encountering a FROM statement)
//各种关键字的处理，有些表示Command，有些表示了一个阶段stage
func ParseInstruction(node *parser.Node) (interface{}, error) {
	req := newParseRequestFromNode(node)
	switch node.Value {
	...
	case command.From:
		return parseFrom(req)
	...
	}
	return nil, &UnknownInstruction{Instruction: node.Value, Line: node.StartLine}
}

func parseFrom(req parseRequest) (*Stage, error) {
	stageName, err := parseBuildStageName(req.args)
	if err != nil {
		return nil, err
	}

	flPlatform := req.flags.AddString("platform", "")
	if err := req.flags.Parse(); err != nil {
		return nil, err
	}

	code := strings.TrimSpace(req.original)
	return &Stage{
		BaseName:   req.args[0],
		Name:       stageName,
		SourceCode: code,
		Commands:   []Command{},
		Platform:   flPlatform.Value,
	}, nil

}
```
FROM的解析返回的是一个**stage**，其中`parseBuildStageName`返回了stage的name，回忆在`FROM`的[语法](https://docs.docker.com/engine/reference/builder/#from) 中，后跟image name，因此该stage的名称就是image name或自定义的image name。

2. COPY
```go
// ParseInstruction converts an AST to a typed instruction (either a command or a build stage beginning when encountering a FROM statement)
//各种关键字的处理，有些表示Command，有些表示了一个阶段stage
func ParseInstruction(node *parser.Node) (interface{}, error) {
	req := newParseRequestFromNode(node)
	switch node.Value {
	...
	case command.Copy:
		return parseCopy(req)
	...
	}
	return nil, &UnknownInstruction{Instruction: node.Value, Line: node.StartLine}
}

func parseCopy(req parseRequest) (*CopyCommand, error) {
	if len(req.args) < 2 {
		return nil, errNoDestinationArgument("COPY")
	}
	flChown := req.flags.AddString("chown", "")
	flFrom := req.flags.AddString("from", "")
	if err := req.flags.Parse(); err != nil {
		return nil, err
	}
	return &CopyCommand{
		SourcesAndDest:  SourcesAndDest(req.args),
		From:            flFrom.Value,
		withNameAndCode: newWithNameAndCode(req),
		Chown:           flChown.Value,
	}, nil
}
```
COPY的解析返回了一个Command接口，`COPY`的[主要作用](https://docs.docker.com/engine/reference/builder/#copy) 就是将源目录的内容CPOY进容器的目标目录，最终返回的`CopyCommand`包含了源、目的目录，以及COPY使用到的可选的`chown`等功能。

通过查看`func Parse(ast *parser.Node) (stages []Stage, metaArgs []ArgCommand, err error)`的所有case，发现**stage**表示了一个`FROM`的操作，而**command**表示了再FROM之后，dockerfile中的各个关键字`CPOY`、`ADD`、`LABEL`等等命令的描述，因此`func Parse(ast *parser.Node) (stages []Stage, metaArgs []ArgCommand, err error)`的最终返回为一个包含了多个Command的Stage以及通过ARG配置的metaArgs。

#### build impl

因此回到函数`func (b *Builder) build(source builder.Source, dockerfile *parser.Result) (*builder.Result, error) `:
```go
func (b *Builder) build(source builder.Source, dockerfile *parser.Result) (*builder.Result, error) {
	defer b.imageSources.Unmount()
	...
	//构建的具体实现
	dispatchState, err := b.dispatchDockerfileWithCancellation(stages, metaArgs, dockerfile.EscapeToken, source)
	if err != nil {
		return nil, err
	}
	if dispatchState.imageID == "" {
		buildsFailed.WithValues(metricsDockerfileEmptyError).Inc()
		return nil, errors.New("No image was generated. Is your Dockerfile empty?")
	}
	return &builder.Result{ImageID: dispatchState.imageID, FromImage: dispatchState.baseImage}, nil
}
```
进入build的实现函数`dispatchDockerfileWithCancellation`:
```go
//入参中，parseResult 即stage对象，metaArgs为ARG参数，source为dockerfile内容
func (b *Builder) dispatchDockerfileWithCancellation(parseResult []instructions.Stage, metaArgs []instructions.ArgCommand, escapeToken rune, source builder.Source) (*dispatchState, error) {
	dispatchRequest := dispatchRequest{}
	buildArgs := NewBuildArgs(b.options.BuildArgs)
	//要处理的command数，stage为FROM，即len为1,如果没有ARG，此时的total为1
	totalCommands := len(metaArgs) + len(parseResult)
	currentCommandIndex := 1
	//遍历stage中的Command,即那些COPY/ADD命令
	for _, stage := range parseResult {
		totalCommands += len(stage.Commands)
	}
	//shelx，shell的执行器
	shlex := shell.NewLex(escapeToken)
	//处理ARG参数
	for _, meta := range metaArgs {
		currentCommandIndex = printCommand(b.Stdout, currentCommandIndex, totalCommands, &meta)

		err := processMetaArg(meta, shlex, buildArgs)
		if err != nil {
			return nil, err
		}
	}
	//stagesResults内部封装了一个map[string]*container.Config类型的indexed
	stagesResults := newStagesBuildResults()
	//遍历stage，即每一个FROM的段
	for _, stage := range parseResult {
		//首先check各个stage的Name是否已经在stagesResults的map中，即stage重名
		if err := stagesResults.checkStageNameAvailable(stage.Name); err != nil {
			return nil, err
		}
		//封装一个dispatchRequst，内部即入参定义
		dispatchRequest = newDispatchRequest(b, escapeToken, source, buildArgs, stagesResults)

		currentCommandIndex = printCommand(b.Stdout, currentCommandIndex, totalCommands, stage.SourceCode)
		//initializeStage，根据dispatchRequest中封装的builder，得到baseImage，并调用Get获取这个image,返回的是封装了各种Image属性的build.Image,之后将这个image赋值给stage
		if err := initializeStage(dispatchRequest, &stage); err != nil {
			return nil, err
		}
		dispatchRequest.state.updateRunConfig()
		fmt.Fprintf(b.Stdout, " ---> %s\n", stringid.TruncateID(dispatchRequest.state.imageID))
		//处理各个command
		for _, cmd := range stage.Commands {
			select {
			case <-b.clientCtx.Done():
				logrus.Debug("Builder: build cancelled!")
				fmt.Fprint(b.Stdout, "Build cancelled\n")
				buildsFailed.WithValues(metricsBuildCanceled).Inc()
				return nil, errors.New("Build cancelled")
			default:
				// Not cancelled yet, keep going...
			}
			//当前待执行commandIndex
			currentCommandIndex = printCommand(b.Stdout, currentCommandIndex, totalCommands, cmd)
			//
			if err := dispatch(dispatchRequest, cmd); err != nil {
				return nil, err
			}
			dispatchRequest.state.updateRunConfig()
			fmt.Fprintf(b.Stdout, " ---> %s\n", stringid.TruncateID(dispatchRequest.state.imageID))

		}
		if err := emitImageID(b.Aux, dispatchRequest.state); err != nil {
			return nil, err
		}
		buildArgs.MergeReferencedArgs(dispatchRequest.state.buildArgs)
		if err := commitStage(dispatchRequest.state, stagesResults); err != nil {
			return nil, err
		}
	}
	buildArgs.WarnOnUnusedBuildArgs(b.Stdout)
	return dispatchRequest.state, nil
}
```
上述代码中，主要做了以下几步：

1. 处理ARG参数，ARG主要就是给FROM提供值

2. 遍历Stage,处理每一个Stage

3. 对于每一个Stage，首先调用`func initializeStage(d dispatchRequest, cmd *instructions.Stage) error`，这函数的主要作用是初始化`base image`

4. 在一个stage中，遍历各个command，执行`func dispatch(d dispatchRequest, cmd instructions.Command) (err error)`

因此，进入`func dispatch(d dispatchRequest, cmd instructions.Command) (err error)`:
```go
func dispatch(d dispatchRequest, cmd instructions.Command) (err error) {
	//check platform
	runConfigEnv := d.state.runConfig.Env
	//添加ENV设置
	envs := append(runConfigEnv, d.state.buildArgs.FilterAllowed(runConfigEnv)...)

	if ex, ok := cmd.(instructions.SupportsSingleWordExpansion); ok {
		err := ex.Expand(func(word string) (string, error) {
			return d.shlex.ProcessWord(word, envs)
		})
		if err != nil {
			return errdefs.InvalidParameter(err)
		}
	}

	defer func() {
		//resource clean
		...
	}()
	//重要，各个命令的处理函数
	switch c := cmd.(type) {
	...
	case *instructions.MaintainerCommand:
		return dispatchMaintainer(d, c)
	...
	case *instructions.AddCommand:
		return dispatchAdd(d, c)
	...
	case *instructions.RunCommand:
		return dispatchRun(d, c)
	case *instructions.CmdCommand:
		return dispatchCmd(d, c)
	...
	case *instructions.VolumeCommand:
		return dispatchVolume(d, c)
	...
	}
	return errors.Errorf("unsupported command type: %v", reflect.TypeOf(cmd))
}
```
由上述代码可以看到，dispatcher最主要的功能就是通过switch-case去处理各个命令。以几个典型的命令为例

- **MAINTAINER**：简单的添加一个image作者的注释，其处理函数`dispatchMaintainer(d, c)`内部调用了`d.builder.commit(d.state, "MAINTAINER "+c.Maintainer)`:
```go
func (b *Builder) commit(dispatchState *dispatchState, comment string) error {
	...
	//对dispatchState中的runConfig进行值copy，并返回，copy的runConfig中内容都是在执行命令时需要的
	runConfigWithCommentCmd := copyRunConfig(dispatchState.runConfig, withCmdComment(comment, dispatchState.operatingSystem))
	...
	//创建
	id, err := b.probeAndCreate(dispatchState, runConfigWithCommentCmd)
	//error handler 
	...
	return b.commitContainer(dispatchState, id, runConfigWithCommentCmd)
}
```
继续进入`probeAndCreate`函数：
```go
func (b *Builder) probeAndCreate(dispatchState *dispatchState, runConfig *container.Config) (string, error) {
	//首先查看缓存，如果有在之前相同的构建，则直接返回
	if hit, err := b.probeCache(dispatchState, runConfig); err != nil || hit {
		return "", err
	}
	//否则，根据runConfig创建
	return b.create(runConfig)
}
```
这个函数中的两步，主要先关注create逻辑，docker对于build过程中的缓存后面分析。继续进入`create`:
```go
func (b *Builder) create(runConfig *container.Config) (string, error) {
	//build info print
	...
	//window flag
	...
	//配置要build的container的配置
	hostConfig := hostConfigFromOptions(b.options, isWCOW)
	//创建container，关键
	container, err := b.containerManager.Create(runConfig, hostConfig)
	...
	return container.ID, nil
}
```