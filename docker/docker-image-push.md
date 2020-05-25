# docker image push

记录docker image push的实现过程

## docker client

push image和pull image在client端的代码结构相似，定位到`docker/cli/cli/command/image/push.go`中的NewPushCommand函数：
```
func NewPushCommand(dockerCli command.Cli) *cobra.Command {
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
}
```
可以看到一个cobra的docker push命令定义，当push一个本地的镜像如myharbor.com/test1/image1:1.0时，这个值作为opts.remote传入RunPush，进入RunPush函数，首先做的就是解析myharbor.com/test1/image1:1.0，将其封装至reference结构体中：
```
func RunPush(dockerCli command.Cli, opts pushOptions) error {
	ref, err := reference.ParseNormalizedNamed(opts.remote)
	...
}
```
其中reference的定义以及继承关系如下，可以看到通过ref的封装，可以得到image的name/tag/repo/registry：
```
type reference struct {
	namedRepository
	tag    string
	digest digest.Digest
}

type namedRepository interface {
	Named
	Domain() string
	Path() string
}

type Named interface {
	Reference
	Name() string
}

type Reference interface {
	// String returns the full reference
	String() string
}
```

之后，和docker pull不同的是，RunPush将根据封装的ref，得到一个repoInfo的信息，调用的函数为`repoInfo, err := registry.ParseRepositoryInfo(ref)`.这段代码的最主要作用是解析ref中描述的registry，并将其信息(是否为官方、https/http)封装到refoInfo。其中repoInfo的定义如下所示：

```
type RepositoryInfo struct {
	Name reference.Named //ref
	
	Index *registrytypes.IndexInfo //registry仓库的信息
	
	Official bool //是否为官方镜像
	// Class represents the class of the repository, such as "plugin"
	// or "image".
	Class string
}

type IndexInfo struct {
	// Name is the name of the registry, such as "docker.io"
	Name string
	// Mirrors is a list of mirrors, expressed as URIs
	Mirrors []string //仓库镜像，在daemon.json中配置
	// Secure is set to false if the registry is part of the list of
	// insecure registries. Insecure registries accept HTTP and/or accept
	// HTTPS with certificates from unknown CAs.
	Secure bool //这个registry是否在doemon.json中的in-security中
	// Official indicates whether this is an official registry
	Official bool 
}
```

下一步，就需要获取认证相关的信息了。docker的config.json中以k-v形式对认证信息进行了保存，其中key就是registry域名。因此，根据repoInfo的Index，解析认证信息，具体实现函数为：
```
func ResolveAuthConfig(ctx context.Context, cli Cli, index *registrytypes.IndexInfo) types.AuthConfig {
	configKey := index.Name
	if index.Official {
		configKey = ElectAuthServer(ctx, cli)
	}

	a, _ := cli.ConfigFile().GetAuthConfig(configKey)
	return types.AuthConfig(a)
}
```
最后，在真正调用push函数前，首先创建一个`RegistryAuthenticationPrivilegedFunc`。 那么这个函数的作用是什么呢？先继续往下看，调用`responseBody, err := imagePushPrivileged(ctx, dockerCli, authConfig, ref, requestPrivilege)`,这是push的主函数，而刚才那个func作为参数requestPrivilege也一并传入。函数内部其实只做了一层封装，继续调用cli.Client().ImagePush：
```
	encodedAuth, err := command.EncodeAuthToBase64(authConfig)
	if err != nil {
		return nil, err
	}
	options := types.ImagePushOptions{
		RegistryAuth:  encodedAuth,
		PrivilegeFunc: requestPrivilege,
	}

	return cli.Client().ImagePush(ctx, reference.FamiliarString(ref), options)
```
ImagePush的实现如下,大致分为两步，第一步为构造请求参数，第二步为发送请求：
```
func (cli *Client) ImagePush(ctx context.Context, image string, options types.ImagePushOptions) (io.ReadCloser, error) {
	ref, err := reference.ParseNormalizedNamed(image)
	if err != nil {
		return nil, err
	}

	if _, isCanonical := ref.(reference.Canonical); isCanonical {
		return nil, errors.New("cannot push a digest reference")
	}

	tag := ""
	name := reference.FamiliarName(ref)

	if nameTaggedRef, isNamedTagged := ref.(reference.NamedTagged); isNamedTagged {
		tag = nameTaggedRef.Tag()
	}

	query := url.Values{}
	query.Set("tag", tag)

	resp, err := cli.tryImagePush(ctx, name, query, options.RegistryAuth)
	//重点在这里，注意PrivilegeFunc的调用时机
	if errdefs.IsUnauthorized(err) && options.PrivilegeFunc != nil {
		newAuthHeader, privilegeErr := options.PrivilegeFunc()
		if privilegeErr != nil {
			return nil, privilegeErr
		}
		resp, err = cli.tryImagePush(ctx, name, query, newAuthHeader)
	}
	if err != nil {
		return nil, err
	}
	return resp.body, nil
}
```
当进行tryImagePush时，出现未授权的err时，则调用之前创建的函数变量PrivilegeFunc。因此猜测这个函数的作用为授权操作，具体的场景为：虽然通过config.json得到了auth信息，但是，这个auth信息所包含的用户并不能够将image push到这个repo上，因此需要用授权的另一个账户登录，从而拿新的auth信息来操作。

因此，回过头看下`RegistryAuthenticationPrivilegedFunc`完成的工作，猜想得到验证：
```
func RegistryAuthenticationPrivilegedFunc(cli Cli, index *registrytypes.IndexInfo, cmdName string) types.RequestPrivilegeFunc {
	return func() (string, error) {
		//提示login
		fmt.Fprintf(cli.Out(), "\nPlease login prior to %s:\n", cmdName)
		indexServer := registry.GetAuthConfigKey(index)
		//判断是否为默认registry
		isDefaultRegistry := indexServer == ElectAuthServer(context.Background(), cli)
		authConfig, err := GetDefaultAuthConfig(cli, true, indexServer, isDefaultRegistry)
		if err != nil {
			fmt.Fprintf(cli.Err(), "Unable to retrieve stored credentials for %s, error: %s.\n", indexServer, err)
		}
		//新的accpunt/pwd信息
		err = ConfigureAuth(cli, "", "", authConfig, isDefaultRegistry)
		if err != nil {
			return "", err
		}
		return EncodeAuthToBase64(*authConfig)
	}
}
```

## docker daemon

和docker pull一样，docker push的api位于/engine/api/server/router/image/image.go中。具体的路由为：`router.NewPostRoute("/images/{name:.*}/push", r.postImagesPush),`。 回顾docker push函数:
```
Usage:  docker push [OPTIONS] NAME[:TAG]

Push an image or a repository to a registry

Options:
      --disable-content-trust   Skip image signing (default true)
```
push后指定要上传镜像的repo/image/tag，因此猜测，整体过程为：
 
1. 根据repo/image:tag，在repositories.json中获取image的digest

2. 根据这个image digest，从imagedb的content中得到具体的layer配置信息

3. 根据layer信息，从layerdb中得到具体的layer文件，将layer文件上传

4. 根据上传的layer在distribution目录中更新内容，制作manifest文件，并签名后上传

下面进入`postImagesPush`函数，实现如下：
```
func (s *imageRouter) postImagesPush(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	//对于auth信息的处理，如果有auth信息，则取出后解base64
	...
	authConfig := &types.AuthConfig{}
	authEncoded := r.Header.Get("X-Registry-Auth")
	if authEncoded != "" {
		// the new format is to handle the authConfig as a header
		authJSON := base64.NewDecoder(base64.URLEncoding, strings.NewReader(authEncoded))
		...
	} else {
		...
		//老版本从body中获取
	}
	//解析image信息
	image := vars["name"]
	tag := r.Form.Get("tag")
	output := ioutils.NewWriteFlusher(w)
	...
	w.Header().Set("Content-Type", "application/json")
	//backend的push实现
	if err := s.backend.PushImage(ctx, image, tag, metaHeaders, authConfig, output); err != nil {
		...
	}
	return nil
}
```

上面的函数只做了参数解析的工作，一是解析了auth信息，二是image信息，然后就直接调用了backend的PushImage函数：
```
func (i *ImageService) PushImage(ctx context.Context, image, tag string, metaHeaders map[string][]string, authConfig *types.AuthConfig, outStream io.Writer) error {
	start := time.Now()
	//将image信息封装为reference
	ref, err := reference.ParseNormalizedNamed(image)
	...
	if tag != "" {
		ref, err = reference.WithTag(ref, tag)
		...
	}
	//定义用于输出push过程信息的chan以及标志结束的无缓冲chan
	progressChan := make(chan progress.Progress, 100)
	writesDone := make(chan struct{})
	ctx, cancelFunc := context.WithCancel(ctx)
	//用一个routine 从progressChan中读取信息并写到stdout
	go func() {
		progressutils.WriteDistributionProgress(cancelFunc, outStream, progressChan)
		close(writesDone)
	}()
	//配置image push config
	imagePushConfig := &distribution.ImagePushConfig{
		Config: distribution.Config{ //基本image信息
			MetaHeaders:      metaHeaders,
			AuthConfig:       authConfig,
			ProgressOutput:   progress.ChanOutput(progressChan),
			RegistryService:  i.registryService,
			ImageEventLogger: i.LogImageEvent,
			MetadataStore:    i.distributionMetadataStore,
			ImageStore:       distribution.NewImageConfigStoreFromStore(i.imageStore),
			ReferenceStore:   i.referenceStore,
		},
		ConfigMediaType: schema2.MediaTypeImageConfig,//image版本描述
		LayerStores:     distribution.NewLayerProvidersFromStores(i.layerStores), //具体layer的存储实现
		TrustKey:        i.trustKey,
 		UploadManager:   i.uploadManager, //看名字像是上传实现相关的
	}
	//调用distribution的push
	err = distribution.Push(ctx, ref, imagePushConfig)
	close(progressChan)
	//等待done开关
	<-writesDone
	imageActions.WithValues("push").UpdateSince(start)
	return err
}
```
上面这个函数也只做了两件事，一是定义一个progressChan用于接收push的信息并打印，二是封装了一个imagePushConfig的结构体。这个结构体中，除了基本的image信息，也定义了mediaType，即image的格式版本(回忆pull)，根据os环境layerStore的对象。继续进入`err = distribution.Push(ctx, ref, imagePushConfig)`,从包名字distribution可以联想到，这个包和image存储时的distribution相关。有关distribution的信息，请参阅[docker-image-store](docker-image-store.md) 。进入函数，实现如下：

```
func Push(ctx context.Context, ref reference.Named, imagePushConfig *ImagePushConfig) error {
	//解析出RepositoryInfo结构体，这个结构体封装了docker repo的信息,除了ref域，还有registry，是否为官方registry的flag
	repoInfo, err := imagePushConfig.RegistryService.ResolveRepository(ref)
	...
	//根据repoInfo的ref，解析出endpoints，即registry的socket组
	endpoints, err := imagePushConfig.RegistryService.LookupPushEndpoints(reference.Domain(repoInfo.Name))
	...
	//根据ref,解析出association，这是个描述image的二元组struct，两个字段，一个ref,一个image的digest，猜想1验证
	associations := imagePushConfig.ReferenceStore.ReferencesByName(repoInfo.Name)
	...
	//根据endpoint操作，某个endpoint操作成功就返回
	for _, endpoint := range endpoints {
		...//版本验证
		//tls验证
		if endpoint.URL.Scheme != "https" {
			if _, confirmedTLS := confirmedTLSRegistries[endpoint.URL.Host]; confirmedTLS {
				logrus.Debugf("Skipping non-TLS endpoint %s for host/port that appears to use TLS", endpoint.URL)
				continue
			}
		}
		//push对入参进行了封装，并根据入参中registry的版本信息，生成不同的push
		pusher, err := NewPusher(ref, endpoint, repoInfo, imagePushConfig)
		...
		if err := pusher.Push(ctx); err != nil {
			// Was this push cancelled? If so, don't try to fall
			// back.
			select {
			case <-ctx.Done():
			default:
				//fallback err时，换一个endpoint然后continue
				...
			}
			...
		}
		imagePushConfig.ImageEventLogger(reference.FamiliarString(ref), reference.FamiliarName(repoInfo.Name), "push")
		return nil
	}
	...
	return lastErr
}
```

上述代码主要是解析endpoint，，并得到image的digest，即**前文的步骤1**。endpoint的结构如下,：
```
type APIEndpoint struct {
	Mirror                         bool //docker mirror，镜像加速设置
	URL                            *url.URL	//registry url
	Version                        APIVersion //registry version
	AllowNondistributableArtifacts bool  //本地registry配置，在daemon.json的allow-nondistributable-artifacts"中设置
	Official                       bool // 是否官方registry
	TrimHostname                   bool 
	TLSConfig                      *tls.Config //https config
}
```
然后进行了image/registry的版本校验，依次将image push到解析出的所有endpoint，直到一个endpoint成功。在push时，通过Pusher接口封装了push所需的信息，并根据registry版本提供了v2版本的实现。继续进入v2Pusher的实现：
```
func (p *v2Pusher) Push(ctx context.Context) (err error) {
	//通过map的k v判断，key是layerID，descriptor是layer内容的描述
	p.pushState.remoteLayers = make(map[layer.DiffID]distribution.Descriptor)
	p.repo, p.pushState.confirmedV2, err = NewV2Repository(ctx, p.repoInfo, p.endpoint, p.config.MetaHeaders, p.config.AuthConfig, "push", "pull")
	p.pushState.hasAuthInfo = p.config.AuthConfig.RegistryToken != "" || (p.config.AuthConfig.Username != "" && p.config.AuthConfig.Password != "")
	...
	if err = p.pushV2Repository(ctx); err != nil {
		//判断是否尝试下一个endpoint，如果是，返回一个fallback err
		...
	}
	return err
}
```
上述代码对v2pusher中的各个字段进行了填充，其中的descriptor结构描述了一个layer，其内容如下：
```
type Descriptor struct {
	MediaType string  //类型
	Size int64  //大小
	Digest digest.Digest //ID，用于做内容校验
	URLs []string  //layer的源url
	Annotations map[string]string //注释信息
	Platform *v1.Platform //layer所属架构
}
```
继续进入函数`p.pushV2Repository(ctx)`,这个函数的主要功能为，根据tag信息，进行具体的Push操作，如果有tag，直接push，否则，push所有的tag.
```
func (p *v2Pusher) pushV2Repository(ctx context.Context) (err error) {
	//如果有tag信息，则解析出image digest，
	if namedTagged, isNamedTagged := p.ref.(reference.NamedTagged); isNamedTagged {
		imageID, err := p.config.ReferenceStore.Get(p.ref)
		...
		return p.pushV2Tag(ctx, namedTagged, imageID)
	}
	...
	pushed := 0
	//因为在前面的代码已经解析过association，所以此处一定存在，push all tag
	for _, association := range p.config.ReferenceStore.ReferencesByName(p.ref) {
		if namedTagged, isNamedTagged := association.Ref.(reference.NamedTagged); isNamedTagged {
			pushed++
			if err := p.pushV2Tag(ctx, namedTagged, association.ID); err != nil {
				return err
			}
		}
	}
	...
}
```
因此，进入pushV2Tag,一段段来看，首先是根据image digest得到iamge config以及相关信息，比如layer/platform和layer内容，也就是**前文的步骤2**：

```
func (p *v2Pusher) pushV2Tag(ctx context.Context, ref reference.NamedTagged, id digest.Digest) error {
	//根据image digest，获取image的配置信息，这部分信息调用了ImageConfigStore接口的get方法，就是imagedb里的content目录中内容
	imgConfig, err := p.config.ImageStore.Get(id)
	//获取配置信息中的rootfs字段，里面存放了组成image的各个layer diff_id ，即layer id
	...
	rootfs, err := p.config.ImageStore.RootFSFromConfig(imgConfig)
	...
	//platform ，即os字段linux
	platform, err := p.config.ImageStore.PlatformFromConfig(imgConfig)
```
继续获取layer信息，得到layer的内容描述l，即**前文的步骤3**：
```
	...
	//l为具体的layer内容
	l, err := p.config.LayerStores[platform.OS].Get(rootfs.ChainID())
	...
	//计算认证信息摘要，防篡改
	hmacKey, err := metadata.ComputeV2MetadataHMACKey(p.config.AuthConfig)
	...
	defer l.Release()
	...
```
上面代码获取的imageconfig就是docker存储image时的imagedb中的content目录中某个iamge的内容，可以根据上面的代码对应下面的每一个项上，imageconfig的结构如下：
```
{
  "architecture": "amd64",
  "config": {
    ...
  },
  "container": "f7e67f16a539f8bbf53aae18cdb5f8c53e6a56930e7660010d9396ae77f7acfa",
  "container_config": {
   ...
  },
  "created": "2020-04-14T19:19:53.590635493Z",
  "docker_version": "18.09.7",
  "history": [
   ...
  ],
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:5b0d2d635df829f65d0ffb45eab2c3124a470c4f385d6602bda0c21c5248bcab"
    ]
  }
}

```
基本信息获取后，封装一个descriptors的切片，这个切片的每个元素就是layer和registry的具体信息。
```
	...
	var descriptors []xfer.UploadDescriptor
	descriptorTemplate := v2PushDescriptor{
		v2MetadataService: p.v2MetadataService,
		hmacKey:           hmacKey,
		repoInfo:          p.repoInfo.Name,
		ref:               p.ref,
		endpoint:          p.endpoint,
		repo:              p.repo,
		pushState:         &p.pushState,
	}
	//根据image config的rootfs项遍历layer
	for range rootfs.DiffIDs {
		descriptor := descriptorTemplate
		descriptor.layer = l
		descriptor.checkedDigests = make(map[digest.Digest]struct{})
		descriptors = append(descriptors, &descriptor)
		//当前镜像的父image
		l = l.Parent()
	}
	//
	if err := p.config.UploadManager.Upload(ctx, descriptors, p.config.ProgressOutput); err != nil {
		return err
	}
```
继续进入`p.config.UploadManager.Upload`内部实现,根据docker push的行为表现，知道layer是一层层push的，即同步的。在此函数的注释中看到对此过程的描述：
```
// Upload is a blocking function which ensures the listed layers are present on
// the remote registry. It uses the string returned by the Key method to
// deduplicate uploads.
func (lum *LayerUploadManager) Upload(ctx context.Context, layers []UploadDescriptor, progressOutput progress.Output) error {
	var (
		uploads          []*uploadTransfer
		dedupDescriptors = make(map[string]*uploadTransfer)
	)
	//遍历每一个layer，执行xferFunc函数
	for _, descriptor := range layers {
		progress.Update(progressOutput, descriptor.ID(), "Preparing")

		key := descriptor.Key()
		//如果这个layer上传过了，则跳过
		if _, present := dedupDescriptors[key]; present {
			continue
		}
		xferFunc := lum.makeUploadFunc(descriptor)
		upload, watcher := lum.tm.Transfer(descriptor.Key(), xferFunc, progressOutput)
		defer upload.Release(watcher)
		//切片保存
		uploads = append(uploads, upload.(*uploadTransfer))
		//将上传过的layer缓存
		dedupDescriptors[key] = upload.(*uploadTransfer)
	}
	//遍历上传过的layer，处理返回
	for _, upload := range uploads {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-upload.Transfer.Done():
			if upload.err != nil {
				return upload.err
			}
		}
	}
	//填充layer的remoteDescriptor字段，标注哪些layer已经upload
	for _, l := range layers {
		l.SetRemoteDescriptor(dedupDescriptors[l.Key()].remoteDescriptor)
	}

	return nil
}
```
上述代码完成了upload的框架性功能，就是依次upload，处理返回信息，进入upload的函数变量xferFunc实现：
```
func (lum *LayerUploadManager) makeUploadFunc(descriptor UploadDescriptor) DoFunc {
	return func(progressChan chan<- progress.Progress, start <-chan struct{}, inactive chan<- struct{}) Transfer {
		u := &uploadTransfer{
			Transfer: NewTransfer(),
		}
		//定义goroutine异步处理push
		go func() {
			defer func() {
				close(progressChan)
			}()

			progressOutput := progress.ChanOutput(progressChan)
			//同步控制，等待父layer完成后，进行当前layer的push
			select {
			case <-start:
			default:
				progress.Update(progressOutput, descriptor.ID(), "Waiting")
				<-start
			}
			//循环push，直到失败
			retries := 0
			for {
				//如果上传成功，将remoteDescriptor写于uploadTransfer
				remoteDescriptor, err := descriptor.Upload(u.Transfer.Context(), progressOutput)
				if err == nil {
					u.remoteDescriptor = remoteDescriptor
					break
				}
				//取消处理
				select {
				case <-u.Transfer.Context().Done():
					u.err = err
					return
				default:
				}
				//重传控制
				...
			}
		}()
		return u
	}
}
```
上述代码为每一个layer开启了一个goroutine去push，push完成后将layer描述写入uploadTransfer。并通过channel去进行同步控制，继续看`remoteDescriptor, err := descriptor.Upload(u.Transfer.Context(), progressOutput)`的实现,其中descriptor的类型为v2PushDescriptor：
```
func (pd *v2PushDescriptor) Upload(ctx context.Context, progressOutput progress.Output) (distribution.Descriptor, error) {
	//nondistributable artifacts配置
	...
	diffID := pd.DiffID()
	...
	//缓存处理，如果已经push，则return
	...
	//根据layer计算push配置参数
	maxMountAttempts, maxExistenceChecks, checkOtherRepositories := getMaxMountAndExistenceCheckAttempts(pd.layer)
	//metadata即distribution目录中layer id和digest的对应关系
	v2Metadata, err := pd.v2MetadataService.GetMetadata(diffID)
	//如果这个layer已经被别的image push（因为image会共享父layer），则layer已经存在。直接返回这个layer
	...
	//以上检查都false 说明这个layer没有被push过，则准备push，首先封装一个registry的blob
	bs := pd.repo.Blobs(ctx)
	var layerUpload distribution.BlobWriter

	//之前都是在同一个repo中的image上find已经上传的layer,现在去不同的repo中找，如果存在，则进行mount，并将信息作为Push参数
	candidates := getRepositoryMountCandidates(pd.repoInfo, pd.hmacKey, maxMountAttempts, v2Metadata)
	isUnauthorizedError := false
	for _, mountCandidate := range candidates {
		mountCandidate.SourceRepository)
		createOpts := []distribution.BlobCreateOption{}
		if len(mountCandidate.SourceRepository) > 0 {
			namedRef, err := reference.ParseNormalizedNamed(mountCandidate.SourceRepository)
			...
			remoteRef, err := reference.WithName(reference.Path(namedRef))
			...
			canonicalRef, err := reference.WithDigest(reference.TrimNamed(remoteRef), mountCandidate.Digest)
			...
			createOpts = append(createOpts, client.WithMountFrom(canonicalRef))
		}

		//根据bs，创建一个post请求的http client，创建过程其实首选发送了一个post，获取resp中的UUID header，这里猜测是防重放
		lu, err := bs.Create(ctx, createOpts...)
		...
		// when error is unauthorizedError and user don't hasAuthInfo that's the case user don't has right to push layer to register
		// auth check
		...
		if lu != nil {
			// cancel previous upload
			cancelLayerUpload(ctx, mountCandidate.Digest, layerUpload)
			layerUpload = lu
		}
	}
	...
	//如果layer完全是新的，则push
	if layerUpload == nil {
		layerUpload, err = bs.Create(ctx)
		...
	}
	defer layerUpload.Close()
	// 最终的push
	return pd.uploadUsingSession(ctx, progressOutput, diffID, layerUpload)
}
```
进入` pd.uploadUsingSession(ctx, progressOutput, diffID, layerUpload)`内部，猜测其完成了**步骤3中的push layer以及distribution更新**：
```
func (pd *v2PushDescriptor) uploadUsingSession(
	ctx context.Context,
	progressOutput progress.Output,
	diffID layer.DiffID,
	layerUpload distribution.BlobWriter,
) (distribution.Descriptor, error) {
	//常规io操作
	contentReader, err := pd.layer.Open()
	...
	size, _ := pd.layer.Size()
	reader = progress.NewProgressReader(ioutils.NewCancelReadCloser(ctx, contentReader), progressOutput, size, pd.ID(), "Pushing")
	...
	digester := digest.Canonical.Digester()
	tee := io.TeeReader(reader, digester.Hash())
	//push layer在此处，这个layerUpload的具体类型为httpBlobUpload，通过http PATCH请求发送layer数据，并返回layer大小信息
	nn, err := layerUpload.ReadFrom(tee)
	reader.Close()
	...
	//验证已经push的Layer，将layer的digest 通过http put方法发送给registry做校验？
	pushDigest := digester.Digest()
	if _, err := layerUpload.Commit(ctx, distribution.Descriptor{Digest: pushDigest}); err != nil {
		return distribution.Descriptor{}, retryOnError(err)
	}
	...
	// 将已经push的layer添加到cache
	if err := pd.v2MetadataService.TagAndAdd(diffID, pd.hmacKey, metadata.V2Metadata{
		Digest:           pushDigest,
		SourceRepository: pd.repoInfo.Name(),
	}); err != nil {
		return distribution.Descriptor{}, xfer.DoNotRetry{Err: err}
	}
	desc := distribution.Descriptor{
		Digest:    pushDigest,
		MediaType: schema2.MediaTypeLayer,
		Size:      nn,
	}
	...
	return desc, nil
}
```
至此，返回`makeUploadFunc`看到之后的最主要工作是将返回的desc赋值给uploadTransfer，继续返回，在`func (lum *LayerUploadManager) Upload`函数中，执行完所有的layer后，更新distribution目录信息：
```
for _, upload := range uploads {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-upload.Transfer.Done():
			if upload.err != nil {
				return upload.err
			}
		}
	}
	for _, l := range layers {
		l.SetRemoteDescriptor(dedupDescriptors[l.Key()].remoteDescriptor)
	}

	return nil
```
继续返回上层函数至`func (p *v2Pusher) pushV2Tag(ctx context.Context, ref reference.NamedTagged, id digest.Digest)`,最后，根据**步骤4的猜测，将生成manifest并更新给registry**，具体代码如下：
```
	//构建manifest内容
	builder := schema2.NewManifestBuilder(p.repo.Blobs(ctx), p.config.ConfigMediaType, imgConfig)
	manifest, err := manifestFromBuilder(ctx, builder, descriptors)
	manSvc, err := p.repo.Manifests(ctx)
	...
	putOptions := []distribution.ManifestServiceOption{distribution.WithTag(ref.Tag())}
	//具体的put实现，manifests发送http put请求，
	if _, err = manSvc.Put(ctx, manifest, putOptions...); err != nil {
		//根据err 进行版本适配等reput
		...
	}

	var canonicalManifest []byte
	switch v := manifest.(type) {
	case *schema1.SignedManifest:
		canonicalManifest = v.Canonical
	case *schema2.DeserializedManifest:
		_, canonicalManifest, err = v.Payload()
		if err != nil {
			return err
		}
	}
	//本地保存digest
	...
	return nil
}
```


