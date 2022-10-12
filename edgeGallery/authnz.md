# edgeGallery api的认证与鉴权

## 鉴权

对于eg的api，引入了spring-security框架，使用jwt的token作为口令进行权限验证，比如如下：
```java
    @ApiOperation(value = "Adds AppD rule record", response = String.class)
    @PostMapping(path = "/tenants/{tenant_id}/app_instances/{app_instance_id}/appd_configuration", produces =
            MediaType.APPLICATION_JSON_VALUE)
    @PreAuthorize("hasRole('MECM_TENANT') || hasRole('MECM_ADMIN')")
    public ResponseEntity<Status> addAppdRuleRecord(
            @ApiParam(value = TENANT_IDENTIFIER) @PathVariable(TENANT_ID)
            @Pattern(regexp = Constants.TENANT_ID_REGEX) @Size(max = 64) String tenantId,
            @ApiParam(value = APP_INST_IDENTIFIER) @PathVariable(APP_INSTANCE_ID)
            @Pattern(regexp = Constants.APP_INST_ID_REGX) @Size(max = 64) String appInstanceId,
            @Valid @ApiParam(value = APPD_INV_INFO)
            @RequestBody AppdRuleConfigDto appDRuleConfigDto) {
        Status status = service.addRecord(InventoryUtilities.getAppdRule(tenantId, appInstanceId, appDRuleConfigDto),
                repository);
        return new ResponseEntity<>(status, HttpStatus.OK);
    }
```
此处可以看到注解`@PreAuthorize("hasRole('MECM_TENANT') || hasRole('MECM_ADMIN')")`，从字面可了解该api允许角色为MECM_TENANT或MECM_ADMIN的用户访问，这里看hasRole函数的实现：
```java
//由SecurityExpressionRoot类实现
public abstract class SecurityExpressionRoot implements SecurityExpressionOperations {
    protected final Authentication authentication;
    ...

    public SecurityExpressionRoot(Authentication authentication) {
        if (authentication == null) {
            throw new IllegalArgumentException("Authentication object cannot be null");
        } else {
            this.authentication = authentication;
        }
    }

	...

    public final boolean hasRole(String role) {
        return this.hasAnyRole(role);
    }

    public final boolean hasAnyRole(String... roles) {
        return this.hasAnyAuthorityName(this.defaultRolePrefix, roles);
    }

    private boolean hasAnyAuthorityName(String prefix, String... roles) {
        Set<String> roleSet = this.getAuthoritySet();
        String[] var4 = roles;
        int var5 = roles.length;

        for(int var6 = 0; var6 < var5; ++var6) {
            String role = var4[var6];
            String defaultedRole = getRoleWithDefaultPrefix(prefix, role);
            if (roleSet.contains(defaultedRole)) {
                return true;
            }
        }

        return false;
    }
	...
}
```

那么，这个`getAuthoritySet`的值是从哪里来的呢？从下文可看到来自SecurityExpressionRoot类的authentication对象实现。
```java
    private Set<String> getAuthoritySet() {
        if (this.roles == null) {
			//来自this.authentication.getAuthorities()，
            Collection<? extends GrantedAuthority> userAuthorities = this.authentication.getAuthorities();
            if (this.roleHierarchy != null) {
                userAuthorities = this.roleHierarchy.getReachableGrantedAuthorities(userAuthorities);
            }

            this.roles = AuthorityUtils.authorityListToSet(userAuthorities);
        }

        return this.roles;
    }
```

## 认证

和通用的认证实现思路一致，eg将token的验证放在了过滤器中，并保存在上下文，比如inventory的AccessTokenFilter：
```java
@Component
@Import({ResourceServerTokenServicesConfiguration.class})
@EnableGlobalMethodSecurity(prePostEnabled = true)
public class AccessTokenFilter extends OncePerRequestFilter {

    private static final Logger LOGGER = LoggerFactory.getLogger(AccessTokenFilter.class);
    private static final String INVALID_TOKEN_MESSAGE = "Invalid access token";
    private static final String[] HEALTH_URI = {"/inventory/v1/health"};

	//使用框架的jwtToken去解析
    @Autowired
    TokenStore jwtTokenStore;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
        throws ServletException, IOException {
        // Skip token check for health check URI
		...
        String accessTokenStr = request.getHeader("access_token");
        ...
		//过期验证
        OAuth2AccessToken accessToken = jwtTokenStore.readAccessToken(accessTokenStr);
        ...

        Map<String, Object> additionalInfoMap = accessToken.getAdditionalInformation();
		//读取token中的权限描述，封装为authentication对象
        OAuth2Authentication auth = jwtTokenStore.readAuthentication(accessToken);
        ...
		//如果路径中的userid和token中的不一致，也算失败
        ...
		//放入SecurityContextHolder
        SecurityContextHolder.getContext().setAuthentication(auth);

        filterChain.doFilter(request, response);
    }
```

那么这个`OAuth2Authentication`对象和上文中`SecurityExpressionRoot类的authentication对象`是什么关系呢？

## 总结

因此，可以看到：
1. 通过Filter, 解析token，判断token是否有效，如果有效则把token解析出并封装的对象authentication写入上下文，改对象中含有这个token的权限集合。
2. 调用到具体api时，会通过hasRole方法描述这个api需要的角色(权限)信息。此时，会从authentication中读取token的权限列表，查看是否符合api的权限要求。

那么，
