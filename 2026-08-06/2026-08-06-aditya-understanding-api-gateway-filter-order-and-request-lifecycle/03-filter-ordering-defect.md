# 03 — The filter-ordering defect: `getOrder()` is never called

> **This document corrects a claim in
> [2026-08-04 rate-limit-habu-all](../../2026-08-04/2026-08-04-aditya-rate-limit-habu-all/SUMMARY.md),
> which states the filters run at "Order −2 (first)" and "−1 (second)".**
> The *observable behaviour* — quota first, then path — is correct. The *mechanism* is not.
> The framework never reads those numbers.

---

## The claim under test

```java
// QuotaRateLimitFilter.java:124-127
@Override
public int getOrder() { return -2; }

// PathRateLimitFilter.java:143-146
@Override
public int getOrder() { return -1; }
```

Reading this, every reasonable engineer concludes: quota runs before path because −2 < −1.
That conclusion is **wrong**, and the code would behave identically if the numbers were `+500`
and `-9000`.

## Why: Java has nominal typing, not duck typing

`getOrder()` is declared on this project's own interface:

```java
// RateLimitFilter.java:8-13
public interface RateLimitFilter extends GatewayFilter {
    Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain);
    int getOrder();
}
```

And `GatewayFilter`, verified from the 4.3.5 jar, is:

```java
public interface GatewayFilter extends ShortcutConfigurable {
    Mono<Void> filter(ServerWebExchange, GatewayFilterChain);
}
```

**`GatewayFilter` does not extend `org.springframework.core.Ordered`, and neither does
`RateLimitFilter`.** So `QuotaRateLimitFilter` has a method *named* `getOrder()` that has no
relationship whatsoever to Spring's `Ordered` contract. It is a coincidence of naming.

In Java, an interface is a **type**, and `instanceof` is a **type** check. Having a
matching method signature does not make you an instance of the type — you must declare
`implements`. (In Go or Python, structural / duck typing means the method alone would be
enough. Java is not those languages.)

Contrast with a filter in the same codebase that gets it right:

```java
// RequestIdPreFilter.java:20
public class RequestIdPreFilter implements WebFilter, Ordered { ... }
```

## What Spring Cloud Gateway actually does

`GatewayFilterSpec.filter(GatewayFilter)`, decompiled from
`spring-cloud-gateway-server-4.3.5.jar`:

```
0: aload_1
1: instanceof    org/springframework/core/Ordered
4: ifeq          18              <-- NOT Ordered -> jump to 18
7:   ...routeBuilder.filter(gatewayFilter)   (keeps the filter's own order)
16:  areturn
18: aload_0
19: aload_1
20: iconst_0                     <-- the literal int 0
21: invokevirtual filter:(GatewayFilter;I)   -> OrderedGatewayFilter(filter, 0)
24: areturn
```

Equivalent source:

```java
public GatewayFilterSpec filter(GatewayFilter gatewayFilter) {
    if (gatewayFilter instanceof Ordered) {
        this.routeBuilder.filter(gatewayFilter);   // honours its getOrder()
        return this;
    }
    return this.filter(gatewayFilter, 0);          // wraps with order 0
}
```

Because neither rate-limit filter is `Ordered`, **both are wrapped as
`OrderedGatewayFilter(filter, 0)`**. Both have order `0`. `getOrder()` is dead code.

## So why does quota still run first?

`FilteringWebHandler.getAllFilters(route)`:

```java
List<GatewayFilter> combined = new ArrayList<>(this.globalFilters);
combined.addAll(route.getFilters());
AnnotationAwareOrderComparator.sort(combined);
```

`AnnotationAwareOrderComparator.sort` delegates to `List.sort`, which is **TimSort — a stable
sort**. Stable means equal elements keep their original relative order.

Both filters are order `0`, so they retain insertion order. And insertion order is:

```java
// ApiGatewayConfig.java:91-92
f.filter(quotaRateLimitFilter);   // added 1st
f.filter(pathRateLimitFilter);    // added 2nd
```

**Quota runs first because line 91 comes before line 92.** Nothing else.

## Why this matters

- Swapping those two lines silently inverts the security semantics — an org that has blown its
  entire quota would still get per-path limits evaluated first, and the `-2`/`-1` would not
  prevent it.
- The same pattern is duplicated at `:179-180` and `:254-255`. Three places to keep in sync,
  with a comment at `:88-90` asserting a guarantee the code does not provide.
- A future reader "cleaning up" the ordering by editing `getOrder()` will change nothing and
  conclude the framework is broken.

## The fix — and the trap in the obvious one

### Option A (obvious, but has a side effect): `implements Ordered`

```java
public interface RateLimitFilter extends GatewayFilter, Ordered { ... }
```

Now `instanceof Ordered` is `true`, `routeBuilder.filter()` keeps the filter as-is, and
`AnnotationAwareOrderComparator` calls `getOrder()` → −2 sorts before −1. Correct *relative*
to each other.

**But it also moves them relative to Spring Cloud Gateway's global filters**, which live at
these orders (verified from the 4.3.5 sources):

| Global filter | Order |
|---|---|
| `RemoveCachedBodyFilter` | `HIGHEST_PRECEDENCE` |
| `AdaptCachedBodyGlobalFilter` | `HIGHEST_PRECEDENCE + 1000` |
| **`NettyWriteResponseFilter`** | **`-1`** |
| `ForwardPathFilter` | `0` |
| `RouteToRequestUrlFilter` | `10000` |
| `NettyRoutingFilter` | `LOWEST_PRECEDENCE` |

Going to −2/−1 places the rate limiters **before or tied with `NettyWriteResponseFilter`**,
changing where the response-writing wrapper sits in the chain. That is a behavioural change
nobody asked for.

### Option B (recommended): keep the absolute position, make the relative order explicit

```java
f.filter(quotaRateLimitFilter, 0);   // explicit
f.filter(pathRateLimitFilter,  1);   // strictly after quota
```

`GatewayFilterSpec.filter(GatewayFilter, int)` wraps a non-`Ordered` filter as
`OrderedGatewayFilter(filter, order)`. Quota stays exactly where it is today (order `0`), path
moves to `1`, and the ordering is now enforced by the framework rather than by line order.
No interleaving surprises with the global filters.

> If you take Option A, note that `filter(GatewayFilter, int)` **ignores** the explicit order
> for an `Ordered` filter and logs a warning — the two options do not compose.

### Either way

Delete the misleading `getOrder()` from `RateLimitFilter`, or make it real. Leaving a method
that looks load-bearing but is never invoked is the actual defect here.
