# 01 — What happens from `main()`: startup vs. request time

> The single most common beginner confusion in Spring Boot Gateway:
> **the numbered request steps (Netty → WebFilter → DispatcherHandler → route match) are not
> called by `main()`.** `main()` builds a machine; the machine then sits idle. Requests are
> handled later, on different threads, by objects `main()` created but never invoked.
>
> Split everything below into **Phase A (startup, runs once)** and **Phase B (per request,
> runs millions of times)**.

---

## Phase A — Startup: what `main()` actually does

```java
// src/main/java/com/habu/apigateway/config/ApiGatewayApplication.java:16-18
@SpringBootApplication(scanBasePackages = {"com.habu.apigateway"})
@EnableConfigurationProperties
public class ApiGatewayApplication {
  public static void main(String[] args) {
    SpringApplication.run(ApiGatewayApplication.class, args);
  }
}
```

That one line does six things in order.

### A1. Decide what kind of application this is

Spring Boot looks at the classpath. It finds `spring-boot-starter-webflux` (`pom.xml:84`) and
**no** `spring-boot-starter-web`, so it creates a **`ReactiveWebServerApplicationContext`**,
not the servlet one. This is why everything downstream is Netty + Reactor (`Mono`/`Flux`)
rather than Tomcat + servlets.

> **ApplicationContext** = Spring's container. A big map of `name -> object` plus the rules
> for building those objects. "Bean" is just Spring's word for an object the container owns.

### A2. Component scan

`scanBasePackages = "com.habu.apigateway"` tells Spring: walk that package tree, and for every
class annotated `@Component`, `@Service`, `@Repository`, `@Configuration`, `@RestController`,
register a bean definition.

This is how these get found without anyone calling `new`:

| Class | Annotation | File |
|---|---|---|
| `PathRateLimitFilter` | `@Component` | `http/filters/ratelimiter/PathRateLimitFilter.java:22` |
| `QuotaRateLimitFilter` | `@Component` | `http/filters/ratelimiter/QuotaRateLimitFilter.java:18` |
| `RequestIdPreFilter` | `@Component` | `http/filters/RequestIdPreFilter.java:19` |
| `RedisRateLimitConfigRepository` | `@Repository` | `repository/RedisRateLimitConfigRepository.java:15` |
| `RateLimiterService` | `@Service` | `service/RateLimiterService.java` |
| `RateLimitConfigManager` | `@Service` | `service/RateLimitConfigManager.java:8` |
| `RateLimiterController` | `@RestController` | `controller/RateLimiterController.java` |
| `ApiGatewayConfig` | `@Configuration` | `config/ApiGatewayConfig.java:23` |
| `RateLimiterConfig` | `@Configuration` | `config/RateLimiterConfig.java:24` |

### A3. Auto-configuration

`@SpringBootApplication` includes `@EnableAutoConfiguration`. Spring reads
`META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` from
**every jar on the classpath** and evaluates each entry's `@Conditional`s.

This is where beans nobody wrote in this repo come from:

| Auto-configuration | Beans it contributes | Why it fires |
|---|---|---|
| `RedisAutoConfiguration` | `LettuceConnectionFactory`, `RedisTemplate`, **`StringRedisTemplate`** | `spring-boot-starter-data-redis` on classpath (`pom.xml:128`) |
| `RedisReactiveAutoConfiguration` | **`ReactiveStringRedisTemplate`** | same, plus Reactor present |
| `GatewayAutoConfiguration` | `RouteLocatorBuilder`, `RoutePredicateHandlerMapping`, `FilteringWebHandler`, all `GlobalFilter`s | `spring-cloud-gateway-server` on classpath |
| `GatewayRedisAutoConfiguration` | **`redisRequestRateLimiterScript`** (the Lua `RedisScript` bean) | gateway + redis both present |
| `WebFluxAutoConfiguration` | `DispatcherHandler`, `HttpHandler` | webflux on classpath |

**This answers "where does `StringRedisTemplate` come from".** Nothing in this repo declares it.
`RedisAutoConfiguration` builds it, and because
`RedisRateLimitConfigRepository` has exactly one constructor
(`RedisRateLimitConfigRepository.java:26`), Spring uses implicit constructor injection to pass
it in. Nobody calls `new RedisRateLimitConfigRepository(...)` anywhere in the codebase —
verified by grep, including tests.

### A4. Instantiate beans and resolve the dependency graph

Spring topologically sorts the graph and constructs in dependency order:

```
StringRedisTemplate  (auto-config)
   └─> RedisRateLimitConfigRepository       [as RateLimitConfigRepository]
          └─> RateLimiterService
                 ├─> RateLimiterConfig
                 │      ├─> PathRateLimitFilter
                 │      └─> QuotaRateLimitFilter
                 └─> RateLimitConfigManager
                        └─> RateLimiterController
```

Note `RateLimiterService` depends on the **interface** `RateLimitConfigRepository`
(`RateLimiterService.java:18`), and Spring supplies the Redis implementation. Swap in a
JDBC implementation later and nothing above the repository changes.

**Circular dependency, and how it is dodged.** `ApiGatewayConfig` needs the two filters, but the
filters sit in the same graph. So they are injected as **`@Lazy` fields**, not constructor args:

```java
// ApiGatewayConfig.java:67-73
@Lazy @Autowired private PathRateLimitFilter pathRateLimitFilter;
@Lazy @Autowired private QuotaRateLimitFilter quotaRateLimitFilter;
```

`@Lazy` injects a **proxy** — a stand-in object that only resolves the real bean the first
time a method is called on it. That lets `ApiGatewayConfig` finish constructing before the
filters exist.

### A5. Run the `@Configuration` classes' `@Bean` methods

Spring now calls every `@Bean` method. For `ApiGatewayConfig` that is ~15 `RouteLocator`
methods (`:103` through `:266`), each handed a `RouteLocatorBuilder` from
`GatewayAutoConfiguration`.

**Nobody "calls" `ApiGatewayConfig`.** Spring instantiates it, fills its `@Value` fields from
`application.yml`, and invokes each `@Bean` method once. The returned `RouteLocator`s go into
the context. After startup the class is never touched again.

All the `RouteLocator` beans are then merged by gateway auto-config into a
**`CompositeRouteLocator`**, then wrapped in a `CachingRouteLocator`. That is why one bean per
downstream service works instead of the last one winning — each contributes its routes to one
merged table.

### A6. Start Netty and bind the port

The reactive context starts a `NettyReactiveWebServer` on `${SERVER_LISTEN:8443}` with TLS from
the PKCS12 keystore (`application.yml:24-32`).

**Startup is now finished. `main()` returns nothing further to do. Zero requests have been
handled.**

---

## Phase B — Per request: who calls the numbered steps

A request arrives. **Netty's event loop**, not `main()`, drives everything below.

```
Netty event loop thread
  │
  ├─ ① ReactorHttpHandlerAdapter        TLS already terminated by Netty's SslHandler.
  │                                     Wraps the raw request in a ServerWebExchange.
  │
  ├─ ② WebFilter chain                  Spring WebFlux level — BEFORE gateway routing.
  │     RequestIdPreFilter (Ordered, PRE)   RequestIdPreFilter.java:20
  │       adds X-Request-Id if absent
  │     RequestIdPostFilter (Ordered, POST)
  │     ⚠ NO SecurityWebFilterChain exists in this service.
  │
  ├─ ③ DispatcherHandler                The reactive front controller. Asks each
  │                                     HandlerMapping "can you handle this?"
  │     └─ RoutePredicateHandlerMapping     from GatewayAutoConfiguration
  │
  ├─ ④ Route matching                   Walks the merged route table, evaluates each
  │                                     route's predicates, takes the FIRST match.
  │
  ├─ ⑤ FilteringWebHandler              Builds globalFilters + route filters, sorts,
  │                                     runs them as a reactive chain.
  │
  └─ ⑥ NettyRoutingFilter               (order LOWEST_PRECEDENCE) makes the actual
                                        outbound HTTP call to the downstream service.
```

### The mental model that makes it click

| | Phase A (startup) | Phase B (per request) |
|---|---|---|
| Triggered by | `main()` | a TCP connection |
| Runs | once | per request |
| Thread | main thread | Netty event loop |
| Produces | beans, routes, a bound port | an HTTP response |
| Your `@Configuration` code | **runs here** | never runs again |
| Your `@Component` filter code | constructed here | **`filter()` runs here** |

`ApiGatewayConfig` is *entirely* Phase A. `PathRateLimitFilter.filter()` is *entirely* Phase B.
The `RouteLocator` you build in Phase A is the **data** that Phase B's
`RoutePredicateHandlerMapping` reads.

This is **inversion of control**: you never call the framework, the framework calls you. You
hand Spring objects at startup, and Spring invokes them later on its own threads.

---

## Related

- [`02-request-lifecycle-v1-cleanroom.md`](02-request-lifecycle-v1-cleanroom.md) — Phase B traced end-to-end
- [`03-filter-ordering-defect.md`](03-filter-ordering-defect.md) — what goes wrong at step ⑤
