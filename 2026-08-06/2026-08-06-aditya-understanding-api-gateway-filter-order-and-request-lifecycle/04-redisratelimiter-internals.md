# 04 — Inside `RedisRateLimiter.isAllowed()`

`RedisRateLimiter` is a **Spring Cloud Gateway** class
(`org.springframework.cloud.gateway.filter.ratelimit.RedisRateLimiter`), not Habu code. This
project constructs it directly rather than using it as a route filter, which is unusual and
worth understanding.

---

## Why `setApplicationContext` matters

```java
// RedisRateLimiter.java:209-220 (4.3.5 sources)
@Override
public void setApplicationContext(ApplicationContext context) throws BeansException {
    if (initialized.compareAndSet(false, true)) {
        if (this.redisTemplate == null) {
            this.redisTemplate = context.getBean(ReactiveStringRedisTemplate.class);
        }
        this.script = context.getBean(REDIS_SCRIPT_NAME, RedisScript.class);
        if (context.getBeanNamesForType(ConfigurationService.class).length > 0) {
            setConfigurationService(context.getBean(ConfigurationService.class));
        }
    }
}
```

This is the **only** place the limiter acquires its `ReactiveStringRedisTemplate` and its Lua
`RedisScript`. Without it:

```java
// RedisRateLimiter.java:233-236
public Mono<Response> isAllowed(String routeId, String id) {
    if (!this.initialized.get()) {
        throw new IllegalStateException("RedisRateLimiter is not initialized");
    }
```

That is precisely what `RateLimiterConfig.buildLimiter` (`RateLimiterConfig.java:55-64`) exists
to guarantee:

```java
private RedisRateLimiter buildLimiter(int replenishRate, int burstCapacity, int requestedTokens) {
    RedisRateLimiter limiter = new RedisRateLimiter(replenishRate, burstCapacity, requestedTokens);
    if (applicationContext != null) {
        limiter.setApplicationContext(applicationContext);
    }
    return limiter;
}
```

Normally Spring's `ApplicationContextAware` post-processor does this automatically for beans.
But these limiters are created with **`new` at request time**, not by the container, so nothing
would call it. Hence `RateLimiterConfig implements ApplicationContextAware` (`:26`) purely to
capture the context and hand it on.

**Note the two different Redis clients in play:**

| Client | Bean | Used by | Blocking? |
|---|---|---|---|
| `StringRedisTemplate` | `RedisAutoConfiguration` | `RedisRateLimitConfigRepository` — reads the *config* | **yes** |
| `ReactiveStringRedisTemplate` | `RedisReactiveAutoConfiguration` | `RedisRateLimiter` — runs the *bucket* | no |

## `routeId` is not what it looks like

```java
// RedisRateLimiter.java:238, 288-298
Config routeConfig = loadConfiguration(routeId);

Config loadConfiguration(String routeId) {
    Config routeConfig = getConfig().getOrDefault(routeId, defaultConfig);
    ...
}
```

In normal gateway usage, `routeId` looks up a per-route `Config` registered via properties.
Here, `getConfig()` is empty and `defaultConfig` was baked in by the constructor
`new RedisRateLimiter(replenishRate, burstCapacity, requestedTokens)` — which
`RateLimiterConfig` populated from the values it just read out of Redis.

So the strings `"quota_organization"` and `"api_path_method_organization"` are **not** config
lookups. They resolve to `defaultConfig` every time. Their only real effect is as a **Redis key
namespace**:

```java
// RedisRateLimiter.java:150-161
static List<String> getKeys(String id, String routeId) {
    String prefix = "request_rate_limiter.{" + routeId + "." + id + "}.";
    String tokenKey     = prefix + "tokens";
    String timestampKey = prefix + "timestamp";
    return Arrays.asList(tokenKey, timestampKey);
}
```

The `{...}` braces are **Redis Cluster hash tags** — they force both keys onto the same shard so
the Lua script can touch them atomically.

### Concrete keys for `GET /v1/cleanroom`, org `abc-123`

```
request_rate_limiter.{quota_organization.abc-123}.tokens
request_rate_limiter.{quota_organization.abc-123}.timestamp

request_rate_limiter.{api_path_method_organization./v1/cleanroom:GET:abc-123}.tokens
request_rate_limiter.{api_path_method_organization./v1/cleanroom:GET:abc-123}.timestamp
```

> **Cardinality hazard.** The path bucket keys on the **raw URI path**. A client hitting
> `/v1/cleanroom/{id}` with a thousand distinct ids creates a thousand independent buckets,
> each with a full budget. Per-path limits therefore do not constrain ID-enumerating clients —
> the **org quota** is the only real control. (Consistent with the 2026-08-03 finding on the
> `rate_limit_exceeded` metric being tagged with the raw path.)

## The token bucket, in Lua

`META-INF/scripts/request_rate_limiter.lua`, shipped inside the gateway jar:

```lua
local tokens_key    = KEYS[1]
local timestamp_key = KEYS[2]

local rate      = tonumber(ARGV[1])   -- replenishRate
local capacity  = tonumber(ARGV[2])   -- burstCapacity
local now       = tonumber(ARGV[3]) or redis.call('TIME')[1]
local requested = tonumber(ARGV[4])   -- requestedTokens

local fill_time = capacity / rate
local ttl       = math.floor(fill_time * 2)

local last_tokens    = tonumber(redis.call("get", tokens_key))    or capacity
local last_refreshed = tonumber(redis.call("get", timestamp_key)) or 0

local delta         = math.max(0, now - last_refreshed)
local filled_tokens = math.min(capacity, last_tokens + (delta * rate))
local allowed       = filled_tokens >= requested
local new_tokens    = allowed and filled_tokens - requested or filled_tokens

if ttl > 0 then
  redis.call("setex", tokens_key, ttl, new_tokens)
  redis.call("setex", timestamp_key, ttl, now)
end

return { allowed and 1 or 0, new_tokens }
```

Reading it plainly:

1. **Lazy refill.** Nothing runs on a timer. The bucket is refilled *on read*, by
   `elapsed_seconds × rate`, capped at `capacity`.
2. **A missing key means a full bucket** (`or capacity`) — a first-ever request always passes.
3. **Atomicity comes free.** Redis executes a script single-threaded, so no other client can
   interleave between the read and the write. This is why it's a script and not
   GET-then-SET.
4. **`now` is Redis's clock** (`redis.call('TIME')`), because ARGV[3] is passed as `""` from
   `isAllowed`. Gateway pods do not need synchronised clocks.
5. **TTL = `2 × capacity/rate` seconds.** An idle bucket expires and is reborn full — which is
   correct, since a fully-refilled bucket is indistinguishable from a new one.

### Worked example — `replenishRate=10`, `burstCapacity=20`

| t (s) | last_tokens | delta | filled | requested | allowed | new_tokens |
|---|---|---|---|---|---|---|
| 0 | 20 (fresh) | 0 | 20 | 1 | ✅ | 19 |
| 0 | 19 | 0 | 19 | 1 | ✅ | 18 |
| … 20 requests at t=0 … | 0 | 0 | 0 | 1 | ❌ **429** | 0 |
| 1 | 0 | 1 | 10 | 1 | ✅ | 9 |
| 5 | 9 | 4 | 20 (capped) | 1 | ✅ | 19 |

`burstCapacity` is the depth of the bucket — how big an instantaneous spike is tolerated.
`replenishRate` is the sustained rate. TTL here is `floor(20/10 * 2) = 4` seconds.

## Fail-open, twice

```java
// RedisRateLimiter.java:257-260 — Lua/Redis error inside the reactive stream
return flux.onErrorResume(throwable -> {
    log.error("Error calling rate limiter lua", throwable);
    return Flux.just(Arrays.asList(1L, -1L));   // 1 = allowed
})
...
// RedisRateLimiter.java:275-283 — anything thrown synchronously
catch (Exception e) {
    log.error("Error determining if user allowed from redis", e);
}
return Mono.just(new Response(true, getHeaders(routeConfig, -1L)));
```

The upstream comment is explicit: *"We don't want a hard dependency on Redis to allow traffic.
Make sure to set an alert so you know if this is happening too much."*

**If Redis is down, every request is allowed.** Combined with the gateway's own fail-open paths
(no quota config → unlimited, `QuotaRateLimitFilter:44`), rate limiting is best-effort by
design. That is a defensible choice for availability, but it means **rate limiting must never
be the only control for anything security-critical**, and the "rate limiter erroring" alert the
upstream comment asks for should exist.
