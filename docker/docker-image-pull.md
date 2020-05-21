# docker image pull

主要记录docker image pull 实现

镜像pull首先是要执行docker pull命令。从命令可以看出，是docker client首先发送pull请求至docker daemon. Docker Daemon在执行这条命令时，会将Docker Image从Docker Registry下载至本地，并保存在本地Docker Daemon管理的Graph中。其流程总结为：

1. 用户通过Docker Client发送pull请求，用于让Docker Daemon下载指定名称的镜像
2. Docker Server接收Docker镜像的pull请求，创建下载镜像任务并触发执行
3. Docker Daemon执行镜像下载任务，从Docker Registry中下载指定镜像，并将其存储于本地的Graph中。

## docker client

在docker client的笔记中，讲解了client的整体工作机制，镜像下载使用了docker image pull，就以`docker image pull test/hello-world:1.0`举例说明，其实发送http请求的套路和所有命令都一致，就看下后面的参数（args）怎么解析。

1. 在3级命令NewPullCommand中，首先取到了args\[0\],即`test/hello-world:1.0`这个值，并将其赋值给了remote域，然后进入RunPull函数：

```
	cmd := &cobra.Command{
		Use:   "pull [OPTIONS] NAME[:TAG|@DIGEST]",
		Short: "Pull an image or a repository from a registry",
		Args:  cli.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.remote = args[0]
			return RunPull(dockerCli, opts)
		},
	}
```

2. 进入RunPull，主要关注opts参数，在第一句就对这个remote做了解析,`distributionRef, err := reference.ParseNormalizedNamed(opts.remote)`,进入这个prase函数，可以看到其主要工作是解析remote后将其封装为一个Named接口，这个接口的实现有digestReference canonicalReference  taggedReference。代码的大致逻辑为：

```
	//合法性检查
	...
	//根据test/hello-world:1.0 解析中其中的仓库地址domamin，以及repo镜像/tag
	//其中splictDockerDomain对应3中情况:
	//1.address/repo/image:tag  2.repo/image:tag 3.image:tag 4.image
	//对于3,4,domain = defaultDomain(docker.io);对于1,domain为address;对于3,4 将默认使用library作为repo
	domain, remainder := splitDockerDomain(s)
	var remoteName string
	if tagSep := strings.IndexRune(remainder, ':'); tagSep > -1 {
		remoteName = remainder[:tagSep]
	} else {
		remoteName = remainder
	}
	...
	//返回具体的Named实现，包括了digestReference canonicalReference  taggedReference
	ref, err := Parse(domain + "/" + remainder)
    ...
	named, isNamed := ref.(Named)
	if !isNamed {
		return nil, fmt.Errorf("reference %s has no name", ref.String())
	}
	return named, nil
```


3. 解析完成后，将对registry的信息，以及认证信息做进一步的封装，封装的结构体如下：

```
type ImageRefAndAuth struct {
	original   string
	authConfig *types.AuthConfig
	reference  reference.Named
	repoInfo   *registry.RepositoryInfo
	tag        string
	digest     digest.Digest
}
```

其具体实现的函数为`imgRefAndAuth, err := trust.GetImageReferencesAndAuth(ctx, nil, AuthResolver(cli), distributionRef.String())`,其中AuthResolver返回了一个函数func变量`func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig`,如下所示：

```
func AuthResolver(cli command.Cli) func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig {
	return func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig {
		return command.ResolveAuthConfig(ctx, cli, index)
	}
}
```

因此，当AuthResolver被调用时，将根据传入的实际参数，调用command.ResolveAuthConfig(ctx, cli, index)，这个函数的大致逻辑为读取**docker的config.json**里内容，获取认证信息。(*思考？为何在GetImageReferencesAndAuth中使用函数变量，而不是在函数中直接调用呢？答：这样实现了认证信息的解耦，在GetImageReferencesAndAuth的形参中，只需要定义一个函数变量，规定其入参和返回值，而调用者根据实际情况，可选择传入AuthResolver的实现或者Othersolver，对于GetImageReferencesAndAuth内部，则不用关心。否则，其内部的调用逻辑将随着不同认证信息的获取方式改变而难以维护*)

4. 之后，根据cli以及ImageRefAndAuthde的信息，调用`imagePullPrivileged`执行pull操作。在这个函数中，主要是对镜像信息ref和认证信息encodeAuth做了进一步的封装，即options：
```
	options := types.ImagePullOptions{
		RegistryAuth:  encodedAuth,
		PrivilegeFunc: requestPrivilege,
		All:           opts.all,
		Platform:      opts.platform,
	}
```
最后调用client的`ImagePull`函数进行请求的发送，核心的逻辑为首先向daemon的api请求`cli.post(ctx, "/images/create"`，如果需要认证，则调用注册的认证func PrivilegeFunc处理认证信息后重新发送请求：
```
	resp, err := cli.tryImageCreate(ctx, query, options.RegistryAuth)
	if errdefs.IsUnauthorized(err) && options.PrivilegeFunc != nil {
		newAuthHeader, privilegeErr := options.PrivilegeFunc()
		if privilegeErr != nil {
			return nil, privilegeErr
		}
		resp, err = cli.tryImageCreate(ctx, query, newAuthHeader)
	}
```

## docker daemon

docker daemon的api相关代码位于docker-ce/engine/api/server/router/\*，并根据不同的模块分为了container，network，image等包。根据client端的pull请求，定位到以下path定义：
```
func (r *imageRouter) initRoutes() {
	r.routes = []router.Route{
		// GET
		router.NewGetRoute("/images/json", r.getImagesJSON),
		router.NewGetRoute("/images/search", r.getImagesSearch),
		router.NewGetRoute("/images/get", r.getImagesGet),
		router.NewGetRoute("/images/{name:.*}/get", r.getImagesGet),
		router.NewGetRoute("/images/{name:.*}/history", r.getImagesHistory),
		router.NewGetRoute("/images/{name:.*}/json", r.getImagesByName),
		// POST
		router.NewPostRoute("/images/load", r.postImagesLoad),
		router.NewPostRoute("/images/create", r.postImagesCreate),
		router.NewPostRoute("/images/{name:.*}/push", r.postImagesPush),
		router.NewPostRoute("/images/{name:.*}/tag", r.postImagesTag),
		router.NewPostRoute("/images/prune", r.postImagesPrune),
		// DELETE
		router.NewDeleteRoute("/images/{name:.*}", r.deleteImages),
	}
}
```
进入对应的postImageCreate函数，这里主要进行了一些参数的解析，包括请求的image信息和auth信息，解析后直接调用后端的PullImage函数：
```
	//解析请求参数
	var (
		image    = r.Form.Get("fromImage")  //hello-world
		repo     = r.Form.Get("repo") //test
		tag      = r.Form.Get("tag") //1.0
		message  = r.Form.Get("message")
		err      error
		output   = ioutils.NewWriteFlusher(w)
		platform *specs.Platform
	)
	...
	if image != "" { // pull
		metaHeaders := map[string][]string{}
		for k, v := range r.Header {
			if strings.HasPrefix(k, "X-Meta-") {
				metaHeaders[k] = v
			}
		}

		authEncoded := r.Header.Get("X-Registry-Auth")
		authConfig := &types.AuthConfig{}
		//解析auth
		if authEncoded != "" {
			authJSON := base64.NewDecoder(base64.URLEncoding, strings.NewReader(authEncoded))
			if err := json.NewDecoder(authJSON).Decode(authConfig); err != nil {
				authConfig = &types.AuthConfig{}
			}
		}
		//核心函数，image=hello-word tag=1.0 platform= metaHeaders=X-Meta相关 authConfig认证 output为stdout输出
		err = s.backend.PullImage(ctx, image, tag, platform, metaHeaders, authConfig, output)
	} else {
		//import
	}
	if err != nil {
		...
		_, _ = output.Write(streamformatter.FormatError(err))
	}

	return nil
```

PullImage函数在registryBackend接口中定义，由ImageService实现。在函数内部，经过解析image/tag以及auth信息，调用pullImageWithReference来进行,这个函数的主要作用是定义了两个chan,progressChan用于打印pull进度，writesDone是个无缓冲chan，用于标识完成pull。cancelFunc则定义了一组资源清理的逻辑，当使用goroutine读取进度progress过程中出错，则进行资源清理。最后，在进行了进一步的封装后，调用distribution.Pull函数。

```
	progressChan := make(chan progress.Progress, 100)
	writesDone := make(chan struct{})
	ctx, cancelFunc := context.WithCancel(ctx)

	go func() {
		progressutils.WriteDistributionProgress(cancelFunc, outStream, progressChan)
		...
	}()

	imagePullConfig := &distribution.ImagePullConfig{
		Config: distribution.Config{
			MetaHeaders:      metaHeaders,
			AuthConfig:       authConfig,
			ProgressOutput:   progress.ChanOutput(progressChan),
			RegistryService:  i.registryService,
			ImageEventLogger: i.LogImageEvent,
			MetadataStore:    i.distributionMetadataStore,
			ImageStore:       distribution.NewImageConfigStoreFromStore(i.imageStore),
			ReferenceStore:   i.referenceStore,
		},
		DownloadManager: i.downloadManager,
		Schema2Types:    distribution.ImageTypes,
		Platform:        platform,
	}

	err := distribution.Pull(ctx, ref, imagePullConfig)
	<-writesDone
```

进入distribution.Pull函数，其中是一个解析过程，获取repo和endpoints，并根据解析的endpoints信息，得到一个v2Puller对象*（注意这个v2puller是在new中写死的？是否可以解耦）*,这个对象实现了Puller接口，代码如下：

```
	//根据ref信息解析出test/hello-world
	repoInfo, err := imagePullConfig.RegistryService.ResolveRepository(ref)
	....
	//解析出test， 注意此时的endpoints为一个切片，原因？
	endpoints, err := imagePullConfig.RegistryService.LookupPullEndpoints(reference.Domain(repoInfo.Name))
	...
	for _, endpoint := range endpoints {
		//根据api版本初始不同配置信息
		...
		puller, err := newPuller(endpoint, repoInfo, imagePullConfig)
		...
		if err := puller.Pull(ctx, ref, imagePullConfig.Platform); err != nil {
			...error handler
		}
```

再看v2puller对于pull的实现，首先根据之前的配置和参数，New了一个Repository对象，这个对象里主要是创建http client，并加入认证信息，以及根据endpoint进行了ping操作：

```
	p.repo, p.confirmedV2, err = NewV2Repository(ctx, p.repoInfo, p.endpoint, p.config.MetaHeaders, p.config.AuthConfig, "pull")

	if err = p.pullV2Repository(ctx, ref, platform); err != nil {
		...
	}
	return err
```

进入pullV2Repository,根据在image参数中是否含有tag走了不同的分支，不再赘述，这个函数最终又调用了pullV2Tag。这是pull过程的核心逻辑。在了解核心逻辑前，需要对docker image的各个概念以及存储有一个简单了解，[请移步](https://github.com/jzdwk/notes/blob/master/docker/docker-image-store.md)
 
docker pull从整体上来说，做了以下工作：

1. docker daemon发送image的name:tag/digest给registry服务器，服务器根据收到的image info，找到相应image的manifest，然后将manifest返回给docker daemon

2. docker daemon得到manifest后，读取里面image配置文件的digest(sha256)，即image的ID

3. 根据ID在本地找有没有存在同样ID的image，有的话就不用继续下载了

4. 如果没有，那么会给registry服务器发请求（里面包含配置文件的sha256和media type），拿到image的配置文件（Image Config）

5. 根据配置文件中的diff_ids（每个diffid对应一个layer tar包的sha256，tar包相当于layer的原始格式），在本地找对应的layer是否存在

6. 如果layer不存在，则根据manifest里面layer的sha256和media type去服务器拿相应的layer（相当去拿压缩格式的包）。

7. 拿到后进行解压，并检查解压后tar包的sha256能否和配置文件（Image Config）中的diff_id对的上，对不上说明有问题，下载失败

8. 根据docker所用的后台文件系统类型，解压tar包并放到指定的目录

9. 等所有的layer都下载完成后，整个image下载完成，就可以使用了

下面看一下pull的核心代码，首先，根据context生成一个manifest的service，[manifest](https://docs.docker.com/registry/spec/manifest-v2-2/) 主要用于描述一个镜像的组成信息，根据版本的不同(schema1/2,2通过引入manifest list，增加了多架构下的image描述)，其解析逻辑存在差异。在解析ref时，根据docker pull的参数的不同，分为了digest和tag两种，这也从侧面说明了pull的不同方式：

```
    manSvc, err := p.repo.Manifests(ctx)
	...
	var (
		manifest    distribution.Manifest
		tagOrDigest string // Used for logging/progress only
	)
	if digested, isDigested := ref.(reference.Canonical); isDigested {
		manifest, err = manSvc.Get(ctx, digested.Digest())
		...
		tagOrDigest = digested.Digest().String()
	} else if tagged, isTagged := ref.(reference.NamedTagged); isTagged {
		manifest, err = manSvc.Get(ctx, "", distribution.WithTag(tagged.Tag()))
		...
		tagOrDigest = tagged.Tag()
	} else {
		return false, fmt.Errorf("internal error: reference has neither a tag nor a digest: %s", reference.FamiliarString(ref))
	}
```

上面代码的重点是manSvc类型的Get函数，该函数的主要作用为向docker仓库发送一个http请求，请求中携带了image和tag or digest的信息(docker pull mysql:5.7 or docker pull mysql@digest)。并返回一个manifest。注意因为manifest的格式存在版本的不同，所以docker仓库在http respHeader中通过字段`Content-Type`进行了说明。
```
	...
	//根据pull的参数，赋值digestOrTag
	for _, option := range options {
		switch opt := option.(type) {
		case distribution.WithTagOption:
			digestOrTag = opt.Tag
			ref, err = reference.WithTag(ms.name, opt.Tag)
			...
		case contentDigestOption:
			contentDgst = opt.digest
		case distribution.WithManifestMediaTypesOption:
			mediaTypes = opt.MediaTypes
		default:
			... err handle
		}
	}
	//http操作
	...
	u, err := ms.ub.BuildManifestURL(ref)
	...
	req, err := http.NewRequest("GET", u, nil)
	...
	resp, err := ms.client.Do(req)
	...
	if resp.StatusCode == http.StatusNotModified {
	...
	//成功后 处理manifest，注意从httpHeader的Docker-Content-Digest读取了digest的sha256值
	} else if SuccessStatus(resp.StatusCode) {
		if contentDgst != nil {
			dgst, err := digest.Parse(resp.Header.Get("Docker-Content-Digest"))
			...
		}
		mt := resp.Header.Get("Content-Type")
		body, err := ioutil.ReadAll(resp.Body)
		...
		m, _, err := distribution.UnmarshalManifest(mt, body)
		...
		return m, nil
	}
	return nil, HandleErrorResponse(resp)
```
拿到manifest后，其内容类似于(manifest v2 schema2)：
```
{
 {
    "schemaVersion": 2,
    "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    "config": {
        "mediaType": "application/vnd.docker.container.image.v1+json",
        "size": 7023,
        "digest": "sha256:b5b2b2c507a0944348e0303114d8d93aaaa081732b86451d9bce1f432a537bc7"
    },
    "layers": [
        {
            "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
            "size": 32654,
            "digest": "sha256:e692418e4cbaf90ca69d05a66403747baa33ee08806650b51fab815ad7fc331f"
        },
        {
            "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
            "size": 16724,
            "digest": "sha256:3c3a4604a545cdc127456d94e421cd355bca5b528f4a9c1905b15da2eb4a4c6b"
        },
        {
            "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
            "size": 73109,
            "digest": "sha256:ec4b8955958665577945c89419d1af06b5f7636b4ac3da7f12184802ad867736"
        }
    ]
}
}
```
这里有几个sha256值要注意区分，在这里做下记录：

- **manifest digest**： 指的是manifest这个文件的sha256值，在http请求manifest后，通过resp的header进行了返回，header的key是`Docker-Content-Digest`也是在docker pull镜像时，stdout打印出的digest。

- **image digest**：对应于Manifest内容的config.digest，它就是docker images输出的镜像ID(docker image)，镜像的ID是镜像配置文件的sha256，我们可以用它继续从Registry上下载镜像配置文件

- **layer digest**：layer层的sha256，取值为把层里所有的文件打包成一个tar，对它计算sha256，得到的就是层id(LayerId)


从中可以看到image基本信息以及layer信息。接下来就是解析manifest，并使用manifest的信息pull image：

```
	...
	//反序列化manifest，得到mediaType，并与docker daemon可支持的type做比对
	if m, ok := manifest.(*schema2.DeserializedManifest); ok {
		var allowedMediatype bool
		for _, t := range p.config.Schema2Types {
			if m.Manifest.Config.MediaType == t {
				allowedMediatype = true
				break
			}
		}
		if !allowedMediatype {
			configClass := mediaTypeClasses[m.Manifest.Config.MediaType]
			if configClass == "" {
				configClass = "unknown"
			}
			return false, invalidManifestClassError{m.Manifest.Config.MediaType, configClass}
		}
	}
	//这句就是我们经常在stdout看到的
	progress.Message(p.config.ProgressOutput, tagOrDigest, "Pulling from "+reference.FamiliarName(p.repo.Named()))
	...
	//不同格式的manifest的pull
	switch v := manifest.(type) {
	case *schema1.SignedManifest:
		...
		id, manifestDigest, err = p.pullSchema1(ctx, ref, v, platform)
	...
	case *schema2.DeserializedManifest:
		id, manifestDigest, err = p.pullSchema2(ctx, ref, v, platform)
		...
	case *ocischema.DeserializedManifest:
		id, manifestDigest, err = p.pullOCI(ctx, ref, v, platform)
		...
	case *manifestlist.DeserializedManifestList:
		id, manifestDigest, err = p.pullManifestList(ctx, ref, v, platform)
		...
	default:
		return false, invalidManifestFormatError{}
	}
```
在本环境下，manifest的版本为schemav2因此进入`p.pullSchema2(ctx, ref, v, platform)`函数。该函数的主要做了一个校验，当pull后的参数是digest时，保证manifest的digest和请求的一致，如果使用非digest的pull，则直接得到manifest的digest并返回。之后根据这个digest，调用函数pullSchema2Layers。首先第一句，如果这个digest在本地有，说明镜像在本地有，就不再继续，直接返回：

```
	if _, err := p.config.ImageStore.Get(target.Digest); err == nil {
		
		return target.Digest, nil
	}
```

函数`pullSchema2Layers(ctx context.Context, target distribution.Descriptor, layers []distribution.Descriptor, platform *specs.Platform)`的4个参数中，target即为manifest的config项，layers为layer项。接下来首先遍历image的所有layer，并封装为一个v2LayerDescriptor切片。后者的定义如下：
```
type v2LayerDescriptor struct {
	digest            digest.Digest  //manifest digest
	diffID            layer.DiffID 
	repoInfo          *registry.RepositoryInfo
	repo              distribution.Repository
	V2MetadataService metadata.V2MetadataService
	tmpFile           *os.File
	verifier          digest.Verifier
	src               distribution.Descriptor // layers
}
```
然后定义了4个chan用于download
```
	configChan := make(chan []byte, 1)  //1长度缓冲chan，获取image config
	configErrChan := make(chan error, 1)  //1长度缓冲chan，获取image config失败时的
	layerErrChan := make(chan error, 1)
	downloadsDone := make(chan struct{})
```
根据manifest里的config.digest,即镜像的sha256,去获取镜像的config信息,**这个config信息，就是在/var/lib/docker/image/imagedb/metadata里的信息**,写入configChan:
```
	var cancel func()
	ctx, cancel = context.WithCancel(ctx)
	defer cancel()
	// Pull the image config
	go func() {
		configJSON, err := p.pullSchema2Config(ctx, target.Digest)
		if err != nil {
			configErrChan <- ImageConfigPullError{Err: err}
			cancel()
			return
		}
		configChan <- configJSON
	}()
```
接下来，将进行layer的下载(暂时忽略windows的内容)，主要调用了RootFSDownloadManager接口的`Download`这个函数，由downloadManager实现：
```
	if p.config.DownloadManager != nil {
		go func() {
			var (
				err    error
				rootFS image.RootFS
			)
			downloadRootFS := *image.NewRootFS()
			rootFS, release, err = p.config.DownloadManager.Download(ctx, downloadRootFS, layerStoreOS, descriptors, p.config.ProgressOutput)
			...
			downloadedRootFS = &rootFS
			close(downloadsDone)
		}()
	} else {
		...
	}
```
进入download内部，有4个入参，其中initialRootFS为一个空的rootfs结构，layers即层信息，progressOutput为要输出的内容。这个函数的实现是一个对于layer的for循环，根据每一个layer，在`l.Download(ctx, progressOutput)`中发送http get去获取layer数据，并将其写入`dm.blobStore.New()`的tmp目录中：
```
for _, l := range layers {
		b, err := dm.blobStore.New()
		...
		rc, _, err := l.Download(ctx, progressOutput)
		defer rc.Close()
		r := io.TeeReader(rc, b)
		inflatedLayerData, err := archive.DecompressStream(r)
		...
}	
```
进入`func (ld *layerDescriptor) Download(ctx context.Context, progressOutput pkgprogress.Output)`。这里首先通过一个newHTTPReadSeeker结构进行fetch，即下载layer，注意这里还封装了一个retry用于尝试多次获取，直到获取成功or超过5次，将返回的layer流rc写入tmp，在写入时，如果发现数据已经存在，即layer已经存在，直接返回：
```
	rc, err := ld.fetcher.Fetch(ctx, ld.desc)
	...
	//根据layer的不同类型，得到对应的digest
	refKey := remotes.MakeRefKey(ctx, ld.desc)
	//写tmp
	if err := content.WriteBlob(ctx, ld.is.ContentStore, refKey, rc, ld.desc); err != nil {
		...
	}
	ra, err := ld.is.ContentStore.ReaderAt(ctx, ld.desc)
	...
	return ioutil.NopCloser(content.NewReader(ra)), ld.desc.Size, nil
```
回到之前函数，当layer下载完成后，进行解压：
```
	for _, l := range layers {
		...
		defer inflatedLayerData.Close()
		digester := digest.Canonical.Digester()
		if _, err := chrootarchive.ApplyLayer(dm.tmpDir, io.TeeReader(inflatedLayerData, digester.Hash())); err != nil {
			return initialRootFS, nil, err
		}
		initialRootFS.Append(layer.DiffID(digester.Digest())) //将每一层的digest append进diff
		d, err := b.Commit()
		if err != nil {
			return initialRootFS, nil, err
		}
		dm.blobs = append(dm.blobs, d)
	}
	return initialRootFS, nil, nil	
```
并将layer信息封装至initialRootFs结构体，rootFS表示一个image的所有定义的文件结构，即image layers，后者的定义如下：
```
type RootFS struct {
	Type    string         `json:"type"` 
	DiffIDs []layer.DiffID `json:"diff_ids,omitempty"` //diff id，每个id代表一个layer

}
```
当函数返回后，这时，我们已经有了：
- 根据manifest中layer项描述的，从registry中download的各个layer以及digest
- 根据manifest中config项的image digest，从registry中download的image的config信息(在../image/imagedb/metadata中)
接下来，pull_v2函数将layer的digest和config中的diff进行比对，确保layer的正确性。
```
	if configJSON == nil {
		configJSON, configRootFS, _, err = receiveConfig(p.config.ImageStore, configChan, configErrChan)
		...
	}
	...
	if downloadedRootFS != nil {
		//layer的检查
		if len(downloadedRootFS.DiffIDs) != len(configRootFS.DiffIDs) {
			return "", errRootFSMismatch
		}
		for i := range downloadedRootFS.DiffIDs {
			if downloadedRootFS.DiffIDs[i] != configRootFS.DiffIDs[i] {
				return "", errRootFSMismatch
			}
		}
	}

	imageID, err := p.config.ImageStore.Put(configJSON)
	...
	return imageID, nil
```
都没有问题后，调用`p.config.ImageStore.Put(configJSON)`将config保存。至此,pull过程完毕并返回image id。





