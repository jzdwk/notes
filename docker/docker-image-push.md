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

4. �����ϴ���layer����manifest�ļ�����ǩ�����ϴ�

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

����������Ҫ�ǽ���endpoint��endpoint�Ľṹ����,��
```
type APIEndpoint struct {
	Mirror                         bool
	URL                            *url.URL	//registry url
	Version                        APIVersion //registry version
	AllowNondistributableArtifacts bool 
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
��ˣ�����pushV2Tag,һ�ζ������������Ǹ���image digest�õ�iamge config�Լ������Ϣ��

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
	...
	//lΪ�����layer����
	l, err := p.config.LayerStores[platform.OS].Get(rootfs.ChainID())
	...
	//������֤��ϢժҪ�����۸�
	hmacKey, err := metadata.ComputeV2MetadataHMACKey(p.config.AuthConfig)
	...
	defer l.Release()
	...
}
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
	//����һ��
	for range rootfs.DiffIDs {
		descriptor := descriptorTemplate
		descriptor.layer = l
		descriptor.checkedDigests = make(map[digest.Digest]struct{})
		descriptors = append(descriptors, &descriptor)
		//����diff����������ȡ��ǰ����ĸ�image
		l = l.Parent()
	}
	//
	if err := p.config.UploadManager.Upload(ctx, descriptors, p.config.ProgressOutput); err != nil {
		return err
	}

	// Try schema2 first
	builder := schema2.NewManifestBuilder(p.repo.Blobs(ctx), p.config.ConfigMediaType, imgConfig)
	manifest, err := manifestFromBuilder(ctx, builder, descriptors)
	if err != nil {
		return err
	}

	manSvc, err := p.repo.Manifests(ctx)
	if err != nil {
		return err
	}

	putOptions := []distribution.ManifestServiceOption{distribution.WithTag(ref.Tag())}
	if _, err = manSvc.Put(ctx, manifest, putOptions...); err != nil {
		if runtime.GOOS == "windows" || p.config.TrustKey == nil || p.config.RequireSchema2 {
			logrus.Warnf("failed to upload schema2 manifest: %v", err)
			return err
		}

		logrus.Warnf("failed to upload schema2 manifest: %v - falling back to schema1", err)

		msg := fmt.Sprintf("[DEPRECATION NOTICE] registry v2 schema1 support will be removed in an upcoming release. Please contact admins of the %s registry NOW to avoid future disruption. More information at https://docs.docker.com/registry/spec/deprecated-schema-v1/", reference.Domain(ref))
		logrus.Warn(msg)
		progress.Message(p.config.ProgressOutput, "", msg)

		manifestRef, err := reference.WithTag(p.repo.Named(), ref.Tag())
		if err != nil {
			return err
		}
		builder = schema1.NewConfigManifestBuilder(p.repo.Blobs(ctx), p.config.TrustKey, manifestRef, imgConfig)
		manifest, err = manifestFromBuilder(ctx, builder, descriptors)
		if err != nil {
			return err
		}

		if _, err = manSvc.Put(ctx, manifest, putOptions...); err != nil {
			return err
		}
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

	manifestDigest := digest.FromBytes(canonicalManifest)
	progress.Messagef(p.config.ProgressOutput, "", "%s: digest: %s size: %d", ref.Tag(), manifestDigest, len(canonicalManifest))

	if err := addDigestReference(p.config.ReferenceStore, ref, manifestDigest, id); err != nil {
		return err
	}

	// Signal digest to the trust client so it can sign the
	// push, if appropriate.
	progress.Aux(p.config.ProgressOutput, apitypes.PushResult{Tag: ref.Tag(), Digest: manifestDigest.String(), Size: len(canonicalManifest)})

	return nil
}
```


