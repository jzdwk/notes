# docker image push

��¼docker image push��ʵ�ֹ���

## docker client

push image��pull image��client�˵Ĵ���ṹ���ƣ���λ��`docker/cli/cli/command/image/push.go`�е�NewPushCommand������
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
���Կ���һ��cobra��docker push����壬��pushһ�����صľ�����myharbor.com/test1/image1:1.0ʱ�����ֵ��Ϊopts.remote����RunPush������RunPush�������������ľ��ǽ���myharbor.com/test1/image1:1.0�������װ��reference�ṹ���У�
```
func RunPush(dockerCli command.Cli, opts pushOptions) error {
	ref, err := reference.ParseNormalizedNamed(opts.remote)
	...
}
```
����reference�Ķ����Լ��̳й�ϵ���£����Կ���ͨ��ref�ķ�װ�����Եõ�image��name/tag/repo/registry��
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

֮�󣬺�docker pull��ͬ���ǣ�RunPush�����ݷ�װ��ref���õ�һ��repoInfo����Ϣ�����õĺ���Ϊ`repoInfo, err := registry.ParseRepositoryInfo(ref)`.��δ��������Ҫ�����ǽ���ref��������registry����������Ϣ(�Ƿ�Ϊ�ٷ���https/http)��װ��refoInfo������repoInfo�Ķ���������ʾ��

```
type RepositoryInfo struct {
	Name reference.Named //ref
	
	Index *registrytypes.IndexInfo //registry�ֿ����Ϣ
	
	Official bool //�Ƿ�Ϊ�ٷ�����
	// Class represents the class of the repository, such as "plugin"
	// or "image".
	Class string
}

type IndexInfo struct {
	// Name is the name of the registry, such as "docker.io"
	Name string
	// Mirrors is a list of mirrors, expressed as URIs
	Mirrors []string //�ֿ⾵����daemon.json������
	// Secure is set to false if the registry is part of the list of
	// insecure registries. Insecure registries accept HTTP and/or accept
	// HTTPS with certificates from unknown CAs.
	Secure bool //���registry�Ƿ���doemon.json�е�in-security��
	// Official indicates whether this is an official registry
	Official bool 
}
```

��һ��������Ҫ��ȡ��֤��ص���Ϣ�ˡ�docker��config.json����k-v��ʽ����֤��Ϣ�����˱��棬����key����registry��������ˣ�����repoInfo��Index��������֤��Ϣ������ʵ�ֺ���Ϊ��
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
�������������push����ǰ�����ȴ���һ��`RegistryAuthenticationPrivilegedFunc`�� ��ô���������������ʲô�أ��ȼ������¿�������`responseBody, err := imagePushPrivileged(ctx, dockerCli, authConfig, ref, requestPrivilege)`,����push�������������ղ��Ǹ�func��Ϊ����requestPrivilegeҲһ�����롣�����ڲ���ʵֻ����һ���װ����������cli.Client().ImagePush��
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
ImagePush��ʵ������,���·�Ϊ��������һ��Ϊ��������������ڶ���Ϊ��������
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
	//�ص������ע��PrivilegeFunc�ĵ���ʱ��
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
������tryImagePushʱ������δ��Ȩ��errʱ�������֮ǰ�����ĺ�������PrivilegeFunc����˲²��������������Ϊ��Ȩ����������ĳ���Ϊ����Ȼͨ��config.json�õ���auth��Ϣ�����ǣ����auth��Ϣ���������û������ܹ���image push�����repo�ϣ������Ҫ����Ȩ����һ���˻���¼���Ӷ����µ�auth��Ϣ��������

��ˣ��ع�ͷ����`RegistryAuthenticationPrivilegedFunc`��ɵĹ���������õ���֤��
```
func RegistryAuthenticationPrivilegedFunc(cli Cli, index *registrytypes.IndexInfo, cmdName string) types.RequestPrivilegeFunc {
	return func() (string, error) {
		//��ʾlogin
		fmt.Fprintf(cli.Out(), "\nPlease login prior to %s:\n", cmdName)
		indexServer := registry.GetAuthConfigKey(index)
		//�ж��Ƿ�ΪĬ��registry
		isDefaultRegistry := indexServer == ElectAuthServer(context.Background(), cli)
		authConfig, err := GetDefaultAuthConfig(cli, true, indexServer, isDefaultRegistry)
		if err != nil {
			fmt.Fprintf(cli.Err(), "Unable to retrieve stored credentials for %s, error: %s.\n", indexServer, err)
		}
		//�µ�accpunt/pwd��Ϣ
		err = ConfigureAuth(cli, "", "", authConfig, isDefaultRegistry)
		if err != nil {
			return "", err
		}
		return EncodeAuthToBase64(*authConfig)
	}
}
```

## docker daemon

��docker pullһ����docker push��apiλ��/engine/api/server/router/image/image.go�С������·��Ϊ��`router.NewPostRoute("/images/{name:.*}/push", r.postImagesPush),`�� �ع�docker push����:
```
Usage:  docker push [OPTIONS] NAME[:TAG]

Push an image or a repository to a registry

Options:
      --disable-content-trust   Skip image signing (default true)
```
push��ָ��Ҫ�ϴ������repo/image/tag����˲²⣬�������Ϊ��
 
1. ����repo/image:tag����repositories.json�л�ȡimage��digest

2. �������image digest����imagedb��content�еõ������layer������Ϣ

3. ����layer��Ϣ����layerdb�еõ������layer�ļ�����layer�ļ��ϴ�

4. �����ϴ���layer��distributionĿ¼�и������ݣ�����manifest�ļ�����ǩ�����ϴ�

�������`postImagesPush`������ʵ�����£�
```
func (s *imageRouter) postImagesPush(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	//����auth��Ϣ�Ĵ��������auth��Ϣ����ȡ�����base64
	...
	authConfig := &types.AuthConfig{}
	authEncoded := r.Header.Get("X-Registry-Auth")
	if authEncoded != "" {
		// the new format is to handle the authConfig as a header
		authJSON := base64.NewDecoder(base64.URLEncoding, strings.NewReader(authEncoded))
		...
	} else {
		...
		//�ϰ汾��body�л�ȡ
	}
	//����image��Ϣ
	image := vars["name"]
	tag := r.Form.Get("tag")
	output := ioutils.NewWriteFlusher(w)
	...
	w.Header().Set("Content-Type", "application/json")
	//backend��pushʵ��
	if err := s.backend.PushImage(ctx, image, tag, metaHeaders, authConfig, output); err != nil {
		...
	}
	return nil
}
```

����ĺ���ֻ���˲��������Ĺ�����һ�ǽ�����auth��Ϣ������image��Ϣ��Ȼ���ֱ�ӵ�����backend��PushImage������
```
func (i *ImageService) PushImage(ctx context.Context, image, tag string, metaHeaders map[string][]string, authConfig *types.AuthConfig, outStream io.Writer) error {
	start := time.Now()
	//��image��Ϣ��װΪreference
	ref, err := reference.ParseNormalizedNamed(image)
	...
	if tag != "" {
		ref, err = reference.WithTag(ref, tag)
		...
	}
	//�����������push������Ϣ��chan�Լ���־�������޻���chan
	progressChan := make(chan progress.Progress, 100)
	writesDone := make(chan struct{})
	ctx, cancelFunc := context.WithCancel(ctx)
	//��һ��routine ��progressChan�ж�ȡ��Ϣ��д��stdout
	go func() {
		progressutils.WriteDistributionProgress(cancelFunc, outStream, progressChan)
		close(writesDone)
	}()
	//����image push config
	imagePushConfig := &distribution.ImagePushConfig{
		Config: distribution.Config{ //����image��Ϣ
			MetaHeaders:      metaHeaders,
			AuthConfig:       authConfig,
			ProgressOutput:   progress.ChanOutput(progressChan),
			RegistryService:  i.registryService,
			ImageEventLogger: i.LogImageEvent,
			MetadataStore:    i.distributionMetadataStore,
			ImageStore:       distribution.NewImageConfigStoreFromStore(i.imageStore),
			ReferenceStore:   i.referenceStore,
		},
		ConfigMediaType: schema2.MediaTypeImageConfig,//image�汾����
		LayerStores:     distribution.NewLayerProvidersFromStores(i.layerStores), //����layer�Ĵ洢ʵ��
		TrustKey:        i.trustKey,
 		UploadManager:   i.uploadManager, //�����������ϴ�ʵ����ص�
	}
	//����distribution��push
	err = distribution.Push(ctx, ref, imagePushConfig)
	close(progressChan)
	//�ȴ�done����
	<-writesDone
	imageActions.WithValues("push").UpdateSince(start)
	return err
}
```
�����������Ҳֻ���������£�һ�Ƕ���һ��progressChan���ڽ���push����Ϣ����ӡ�����Ƿ�װ��һ��imagePushConfig�Ľṹ�塣����ṹ���У����˻�����image��Ϣ��Ҳ������mediaType����image�ĸ�ʽ�汾(����pull)������os����layerStore�Ķ��󡣼�������`err = distribution.Push(ctx, ref, imagePushConfig)`,�Ӱ�����distribution�������뵽���������image�洢ʱ��distribution��ء��й�distribution����Ϣ�������[docker-image-store](docker-image-store.md) �����뺯����ʵ�����£�

```
func Push(ctx context.Context, ref reference.Named, imagePushConfig *ImagePushConfig) error {
	//������RepositoryInfo�ṹ�壬����ṹ���װ��docker repo����Ϣ,����ref�򣬻���registry���Ƿ�Ϊ�ٷ�registry��flag
	repoInfo, err := imagePushConfig.RegistryService.ResolveRepository(ref)
	...
	//����repoInfo��ref��������endpoints����registry��socket��
	endpoints, err := imagePushConfig.RegistryService.LookupPushEndpoints(reference.Domain(repoInfo.Name))
	...
	//����ref,������association�����Ǹ�����image�Ķ�Ԫ��struct�������ֶΣ�һ��ref,һ��image��digest������1��֤
	associations := imagePushConfig.ReferenceStore.ReferencesByName(repoInfo.Name)
	...
	//����endpoint������ĳ��endpoint�����ɹ��ͷ���
	for _, endpoint := range endpoints {
		...//�汾��֤
		//tls��֤
		if endpoint.URL.Scheme != "https" {
			if _, confirmedTLS := confirmedTLSRegistries[endpoint.URL.Host]; confirmedTLS {
				logrus.Debugf("Skipping non-TLS endpoint %s for host/port that appears to use TLS", endpoint.URL)
				continue
			}
		}
		//push����ν����˷�װ�������������registry�İ汾��Ϣ�����ɲ�ͬ��push
		pusher, err := NewPusher(ref, endpoint, repoInfo, imagePushConfig)
		...
		if err := pusher.Push(ctx); err != nil {
			// Was this push cancelled? If so, don't try to fall
			// back.
			select {
			case <-ctx.Done():
			default:
				//fallback errʱ����һ��endpointȻ��continue
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

����������Ҫ�ǽ���endpoint�������õ�image��digest����**ǰ�ĵĲ���1**��endpoint�Ľṹ����,��
```
type APIEndpoint struct {
	Mirror                         bool //docker mirror�������������
	URL                            *url.URL	//registry url
	Version                        APIVersion //registry version
	AllowNondistributableArtifacts bool  //����registry���ã���daemon.json��allow-nondistributable-artifacts"������
	Official                       bool // �Ƿ�ٷ�registry
	TrimHostname                   bool 
	TLSConfig                      *tls.Config //https config
}
```
Ȼ�������image/registry�İ汾У�飬���ν�image push��������������endpoint��ֱ��һ��endpoint�ɹ�����pushʱ��ͨ��Pusher�ӿڷ�װ��push�������Ϣ��������registry�汾�ṩ��v2�汾��ʵ�֡���������v2Pusher��ʵ�֣�
```
func (p *v2Pusher) Push(ctx context.Context) (err error) {
	//ͨ��map��k v�жϣ�key��layerID��descriptor��layer���ݵ�����
	p.pushState.remoteLayers = make(map[layer.DiffID]distribution.Descriptor)
	p.repo, p.pushState.confirmedV2, err = NewV2Repository(ctx, p.repoInfo, p.endpoint, p.config.MetaHeaders, p.config.AuthConfig, "push", "pull")
	p.pushState.hasAuthInfo = p.config.AuthConfig.RegistryToken != "" || (p.config.AuthConfig.Username != "" && p.config.AuthConfig.Password != "")
	...
	if err = p.pushV2Repository(ctx); err != nil {
		//�ж��Ƿ�����һ��endpoint������ǣ�����һ��fallback err
		...
	}
	return err
}
```
���������v2pusher�еĸ����ֶν�������䣬���е�descriptor�ṹ������һ��layer�����������£�
```
type Descriptor struct {
	MediaType string  //����
	Size int64  //��С
	Digest digest.Digest //ID������������У��
	URLs []string  //layer��Դurl
	Annotations map[string]string //ע����Ϣ
	Platform *v1.Platform //layer�����ܹ�
}
```
�������뺯��`p.pushV2Repository(ctx)`,�����������Ҫ����Ϊ������tag��Ϣ�����о����Push�����������tag��ֱ��push������push���е�tag.
```
func (p *v2Pusher) pushV2Repository(ctx context.Context) (err error) {
	//�����tag��Ϣ���������image digest��
	if namedTagged, isNamedTagged := p.ref.(reference.NamedTagged); isNamedTagged {
		imageID, err := p.config.ReferenceStore.Get(p.ref)
		...
		return p.pushV2Tag(ctx, namedTagged, imageID)
	}
	...
	pushed := 0
	//��Ϊ��ǰ��Ĵ����Ѿ�������association�����Դ˴�һ�����ڣ�push all tag
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
��ˣ�����pushV2Tag,һ�ζ������������Ǹ���image digest�õ�iamge config�Լ������Ϣ������layer/platform��layer���ݣ�Ҳ����**ǰ�ĵĲ���2**��

```
func (p *v2Pusher) pushV2Tag(ctx context.Context, ref reference.NamedTagged, id digest.Digest) error {
	//����image digest����ȡimage��������Ϣ���ⲿ����Ϣ������ImageConfigStore�ӿڵ�get����������imagedb���contentĿ¼������
	imgConfig, err := p.config.ImageStore.Get(id)
	//��ȡ������Ϣ�е�rootfs�ֶΣ������������image�ĸ���layer diff_id ����layer id
	...
	rootfs, err := p.config.ImageStore.RootFSFromConfig(imgConfig)
	...
	//platform ����os�ֶ�linux
	platform, err := p.config.ImageStore.PlatformFromConfig(imgConfig)
```
������ȡlayer��Ϣ���õ�layer����������l����**ǰ�ĵĲ���3**��
```
	...
	//lΪ�����layer����
	l, err := p.config.LayerStores[platform.OS].Get(rootfs.ChainID())
	...
	//������֤��ϢժҪ�����۸�
	hmacKey, err := metadata.ComputeV2MetadataHMACKey(p.config.AuthConfig)
	...
	defer l.Release()
	...
```
��������ȡ��imageconfig����docker�洢imageʱ��imagedb�е�contentĿ¼��ĳ��iamge�����ݣ����Ը�������Ĵ����Ӧ�����ÿһ�����ϣ�imageconfig�Ľṹ���£�
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
������Ϣ��ȡ�󣬷�װһ��descriptors����Ƭ�������Ƭ��ÿ��Ԫ�ؾ���layer��registry�ľ�����Ϣ��
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
	//����image config��rootfs�����layer
	for range rootfs.DiffIDs {
		descriptor := descriptorTemplate
		descriptor.layer = l
		descriptor.checkedDigests = make(map[digest.Digest]struct{})
		descriptors = append(descriptors, &descriptor)
		//��ǰ����ĸ�image
		l = l.Parent()
	}
	//
	if err := p.config.UploadManager.Upload(ctx, descriptors, p.config.ProgressOutput); err != nil {
		return err
	}
```
��������`p.config.UploadManager.Upload`�ڲ�ʵ��,����docker push����Ϊ���֣�֪��layer��һ���push�ģ���ͬ���ġ��ڴ˺�����ע���п����Դ˹��̵�������
```
// Upload is a blocking function which ensures the listed layers are present on
// the remote registry. It uses the string returned by the Key method to
// deduplicate uploads.
func (lum *LayerUploadManager) Upload(ctx context.Context, layers []UploadDescriptor, progressOutput progress.Output) error {
	var (
		uploads          []*uploadTransfer
		dedupDescriptors = make(map[string]*uploadTransfer)
	)
	//����ÿһ��layer��ִ��xferFunc����
	for _, descriptor := range layers {
		progress.Update(progressOutput, descriptor.ID(), "Preparing")

		key := descriptor.Key()
		//������layer�ϴ����ˣ�������
		if _, present := dedupDescriptors[key]; present {
			continue
		}
		xferFunc := lum.makeUploadFunc(descriptor)
		upload, watcher := lum.tm.Transfer(descriptor.Key(), xferFunc, progressOutput)
		defer upload.Release(watcher)
		//��Ƭ����
		uploads = append(uploads, upload.(*uploadTransfer))
		//���ϴ�����layer����
		dedupDescriptors[key] = upload.(*uploadTransfer)
	}
	//�����ϴ�����layer��������
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
	//���layer��remoteDescriptor�ֶΣ���ע��Щlayer�Ѿ�upload
	for _, l := range layers {
		l.SetRemoteDescriptor(dedupDescriptors[l.Key()].remoteDescriptor)
	}

	return nil
}
```
�������������upload�Ŀ���Թ��ܣ���������upload����������Ϣ������upload�ĺ�������xferFuncʵ�֣�
```
func (lum *LayerUploadManager) makeUploadFunc(descriptor UploadDescriptor) DoFunc {
	return func(progressChan chan<- progress.Progress, start <-chan struct{}, inactive chan<- struct{}) Transfer {
		u := &uploadTransfer{
			Transfer: NewTransfer(),
		}
		//����goroutine�첽����push
		go func() {
			defer func() {
				close(progressChan)
			}()

			progressOutput := progress.ChanOutput(progressChan)
			//ͬ�����ƣ��ȴ���layer��ɺ󣬽��е�ǰlayer��push
			select {
			case <-start:
			default:
				progress.Update(progressOutput, descriptor.ID(), "Waiting")
				<-start
			}
			//ѭ��push��ֱ��ʧ��
			retries := 0
			for {
				//����ϴ��ɹ�����remoteDescriptorд��uploadTransfer
				remoteDescriptor, err := descriptor.Upload(u.Transfer.Context(), progressOutput)
				if err == nil {
					u.remoteDescriptor = remoteDescriptor
					break
				}
				//ȡ������
				select {
				case <-u.Transfer.Context().Done():
					u.err = err
					return
				default:
				}
				//�ش�����
				...
			}
		}()
		return u
	}
}
```
��������Ϊÿһ��layer������һ��goroutineȥpush��push��ɺ�layer����д��uploadTransfer����ͨ��channelȥ����ͬ�����ƣ�������`remoteDescriptor, err := descriptor.Upload(u.Transfer.Context(), progressOutput)`��ʵ��,����descriptor������Ϊv2PushDescriptor��
```
func (pd *v2PushDescriptor) Upload(ctx context.Context, progressOutput progress.Output) (distribution.Descriptor, error) {
	//nondistributable artifacts����
	...
	diffID := pd.DiffID()
	...
	//���洦������Ѿ�push����return
	...
	//����layer����push���ò���
	maxMountAttempts, maxExistenceChecks, checkOtherRepositories := getMaxMountAndExistenceCheckAttempts(pd.layer)
	//metadata��distributionĿ¼��layer id��digest�Ķ�Ӧ��ϵ
	v2Metadata, err := pd.v2MetadataService.GetMetadata(diffID)
	//������layer�Ѿ������image push����Ϊimage�Ṳ��layer������layer�Ѿ����ڡ�ֱ�ӷ������layer
	...
	//���ϼ�鶼false ˵�����layerû�б�push������׼��push�����ȷ�װһ��registry��blob
	bs := pd.repo.Blobs(ctx)
	var layerUpload distribution.BlobWriter

	//֮ǰ������ͬһ��repo�е�image��find�Ѿ��ϴ���layer,����ȥ��ͬ��repo���ң�������ڣ������mount��������Ϣ��ΪPush����
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

		//����bs������һ��post�����http client������������ʵ��ѡ������һ��post����ȡresp�е�UUID header������²��Ƿ��ط�
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
	//���layer��ȫ���µģ���push
	if layerUpload == nil {
		layerUpload, err = bs.Create(ctx)
		...
	}
	defer layerUpload.Close()
	// ���յ�push
	return pd.uploadUsingSession(ctx, progressOutput, diffID, layerUpload)
}
```
����` pd.uploadUsingSession(ctx, progressOutput, diffID, layerUpload)`�ڲ����²��������**����3�е�push layer�Լ�distribution����**��
```
func (pd *v2PushDescriptor) uploadUsingSession(
	ctx context.Context,
	progressOutput progress.Output,
	diffID layer.DiffID,
	layerUpload distribution.BlobWriter,
) (distribution.Descriptor, error) {
	//����io����
	contentReader, err := pd.layer.Open()
	...
	size, _ := pd.layer.Size()
	reader = progress.NewProgressReader(ioutils.NewCancelReadCloser(ctx, contentReader), progressOutput, size, pd.ID(), "Pushing")
	...
	digester := digest.Canonical.Digester()
	tee := io.TeeReader(reader, digester.Hash())
	//push layer�ڴ˴������layerUpload�ľ�������ΪhttpBlobUpload��ͨ��http PATCH������layer���ݣ�������layer��С��Ϣ
	nn, err := layerUpload.ReadFrom(tee)
	reader.Close()
	...
	//��֤�Ѿ�push��Layer����layer��digest ͨ��http put�������͸�registry��У�飿
	pushDigest := digester.Digest()
	if _, err := layerUpload.Commit(ctx, distribution.Descriptor{Digest: pushDigest}); err != nil {
		return distribution.Descriptor{}, retryOnError(err)
	}
	...
	// ���Ѿ�push��layer��ӵ�cache
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
���ˣ�����`makeUploadFunc`����֮�������Ҫ�����ǽ����ص�desc��ֵ��uploadTransfer���������أ���`func (lum *LayerUploadManager) Upload`�����У�ִ�������е�layer�󣬸���distributionĿ¼��Ϣ��
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
���������ϲ㺯����`func (p *v2Pusher) pushV2Tag(ctx context.Context, ref reference.NamedTagged, id digest.Digest)`,��󣬸���**����4�Ĳ²⣬������manifest�����¸�registry**������������£�
```
	//����manifest����
	builder := schema2.NewManifestBuilder(p.repo.Blobs(ctx), p.config.ConfigMediaType, imgConfig)
	manifest, err := manifestFromBuilder(ctx, builder, descriptors)
	manSvc, err := p.repo.Manifests(ctx)
	...
	putOptions := []distribution.ManifestServiceOption{distribution.WithTag(ref.Tag())}
	//�����putʵ�֣�manifests����http put����
	if _, err = manSvc.Put(ctx, manifest, putOptions...); err != nil {
		//����err ���а汾�����reput
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
	//���ر���digest
	...
	return nil
}
```


