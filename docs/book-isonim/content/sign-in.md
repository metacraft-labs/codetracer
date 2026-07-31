---
title: Sign In
description: Sign in to your CodeTracer account.
layout: minimal
hidden: true
---
# Sign In

Sign in to your CodeTracer account.

:::form action="/sign-in" method="get" submit="Sign in"
@field name="Email" label="Email address" type=email placeholder="Email" required
@field name="Password" label="Password" type=password placeholder="Password" required
@field name="remember" label="Remember me" type=checkbox
:::

Not registered? [Sign up](/sign-up).
