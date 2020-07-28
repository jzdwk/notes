# docker build

[docker build](https://docs.docker.com/engine/reference/commandline/build/) 的作用为根据dockerfile文件，创建镜像。其中dockerfile的位置可以位于当前目录/指定目录/URL

## client 

docker build 同样是C/S方式实现，client端的代码位于`components/cli/cli/command/commands/commands.go`的`image.NewBuildCommand(dockerCli)`函数，最终进入`runBuild`函数：

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
```

上面的代码没有核心逻辑，唯一注意的是`imageIDFile`以及`--iidfile`的*使用场景*。 通过不同途径去获取dockerfile，然后进行build的核心逻辑使用了switch-case实现：

```go
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
		buildCtx, relDockerfile, err = build.GetContextFromURL(progBuff, specifiedContext, options.dockerfileName)
	default:
		return errors.Errorf("unable to prepare context: path %q not found", specifiedContext)
	}

	if err != nil {
		if options.quiet && urlutil.IsURL(specifiedContext) {
			fmt.Fprintln(dockerCli.Err(), progBuff)
		}
		return errors.Errorf("unable to prepare context: %s", err)
	}

	if tempDir != "" {
		defer os.RemoveAll(tempDir)
		contextDir = tempDir
	}

	// read from a directory into tar archive
	if buildCtx == nil {
		excludes, err := build.ReadDockerignore(contextDir)
		if err != nil {
			return err
		}

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
		if err != nil {
			return err
		}
	}

	// replace Dockerfile if it was added from stdin or a file outside the build-context, and there is archive context
	if dockerfileCtx != nil && buildCtx != nil {
		buildCtx, relDockerfile, err = build.AddDockerfileToBuildContext(dockerfileCtx, buildCtx)
		if err != nil {
			return err
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

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
			if err != nil {
				return err
			}
			dockerfileCtx = ioutil.NopCloser(bytes.NewBuffer(newDockerfile))
		}
	}

	if options.compress {
		buildCtx, err = build.Compress(buildCtx)
		if err != nil {
			return err
		}
	}

	// Setup an upload progress bar
	progressOutput := streamformatter.NewProgressOutput(progBuff)
	if !dockerCli.Out().IsTerminal() {
		progressOutput = &lastProgressOutput{output: progressOutput}
	}

	// if up to this point nothing has set the context then we must have another
	// way for sending it(streaming) and set the context to the Dockerfile
	if dockerfileCtx != nil && buildCtx == nil {
		buildCtx = dockerfileCtx
	}

	var body io.Reader
	if buildCtx != nil {
		body = progress.NewProgressReader(buildCtx, progressOutput, 0, "", "Sending build context to Docker daemon")
	}

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

	response, err := dockerCli.Client().ImageBuild(ctx, body, buildOptions)
	if err != nil {
		if options.quiet {
			fmt.Fprintf(dockerCli.Err(), "%s", progBuff)
		}
		cancel()
		return err
	}
	defer response.Body.Close()

	imageID := ""
	aux := func(msg jsonmessage.JSONMessage) {
		var result types.BuildResult
		if err := json.Unmarshal(*msg.Aux, &result); err != nil {
			fmt.Fprintf(dockerCli.Err(), "Failed to parse aux message: %s", err)
		} else {
			imageID = result.ID
		}
	}

	err = jsonmessage.DisplayJSONMessagesStream(response.Body, buildBuff, dockerCli.Out().FD(), dockerCli.Out().IsTerminal(), aux)
	if err != nil {
		if jerr, ok := err.(*jsonmessage.JSONError); ok {
			// If no error code is set, default to 1
			if jerr.Code == 0 {
				jerr.Code = 1
			}
			if options.quiet {
				fmt.Fprintf(dockerCli.Err(), "%s%s", progBuff, buildBuff)
			}
			return cli.StatusError{Status: jerr.Message, StatusCode: jerr.Code}
		}
		return err
	}

	// Windows: show error message about modified file permissions if the
	// daemon isn't running Windows.
	if response.OSType != "windows" && runtime.GOOS == "windows" && !options.quiet {
		fmt.Fprintln(dockerCli.Out(), "SECURITY WARNING: You are building a Docker "+
			"image from Windows against a non-Windows Docker host. All files and "+
			"directories added to build context will have '-rwxr-xr-x' permissions. "+
			"It is recommended to double check and reset permissions for sensitive "+
			"files and directories.")
	}

	// Everything worked so if -q was provided the output from the daemon
	// should be just the image ID and we'll print that to stdout.
	if options.quiet {
		imageID = fmt.Sprintf("%s", buildBuff)
		_, _ = fmt.Fprint(dockerCli.Out(), imageID)
	}

	if options.imageIDFile != "" {
		if imageID == "" {
			return errors.Errorf("Server did not provide an image ID. Cannot write %s", options.imageIDFile)
		}
		if err := ioutil.WriteFile(options.imageIDFile, []byte(imageID), 0666); err != nil {
			return err
		}
	}
	if !options.untrusted {
		// Since the build was successful, now we must tag any of the resolved
		// images from the above Dockerfile rewrite.
		for _, resolved := range resolvedTags {
			if err := TagTrusted(ctx, dockerCli, resolved.digestRef, resolved.tagRef); err != nil {
				return err
			}
		}
	}

	return nil
}
```