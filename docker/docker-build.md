# docker build

[docker build](https://docs.docker.com/engine/reference/commandline/build/) 的作用为根据dockerfile文件，创建镜像。其中dockerfile的位置可以位于当前目录/指定目录/URL

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
	dockerfile.PrintWarnings(b.Stderr)
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
上述代码首先解析dockerfile的内容，并返回一个**stages**数组，这个数组的每一个元素代表了build的一个阶段，可以简单理解为dockerfile中的每一个小节。`instructions.Parse(dockerfile.AST)`方法比较简单，遍历dockerfile中的各项，并添加command，：
```go
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

// ParseInstruction converts an AST to a typed instruction (either a command or a build stage beginning when encountering a FROM statement)
//各种关键字的处理，有些表示Command，有些表示了一个阶段stage
func ParseInstruction(node *parser.Node) (interface{}, error) {
	req := newParseRequestFromNode(node)
	switch node.Value {
	case command.Env:
		return parseEnv(req)
	case command.Maintainer:
		return parseMaintainer(req)
	case command.Label:
		return parseLabel(req)
	case command.Add:
		return parseAdd(req)
	case command.Copy:
		return parseCopy(req)
	case command.From:
		return parseFrom(req)
	case command.Onbuild:
		return parseOnBuild(req)
	case command.Workdir:
		return parseWorkdir(req)
	case command.Run:
		return parseRun(req)
	case command.Cmd:
		return parseCmd(req)
	case command.Healthcheck:
		return parseHealthcheck(req)
	case command.Entrypoint:
		return parseEntrypoint(req)
	case command.Expose:
		return parseExpose(req)
	case command.User:
		return parseUser(req)
	case command.Volume:
		return parseVolume(req)
	case command.StopSignal:
		return parseStopSignal(req)
	case command.Arg:
		return parseArg(req)
	case command.Shell:
		return parseShell(req)
	}

	return nil, &UnknownInstruction{Instruction: node.Value, Line: node.StartLine}
}
```
stage的结构定义如下，可以看到
```go
// Stage represents a single stage in a multi-stage build
type Stage struct {
	Name       string //阶段名称
	Commands   []Command //携带参数
	BaseName   string //
	SourceCode string
	Platform   string
}

```