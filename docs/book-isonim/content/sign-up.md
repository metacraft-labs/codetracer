---
title: Sign Up
description: Create a CodeTracer account.
layout: minimal
hidden: true
---
# Sign Up

Create a CodeTracer account.

:::form action="/sign-up" method="get" submit="Sign up"
@field name="Email" label="Email address" type=email placeholder="Email" required
@field name="Password" label="Password" type=password placeholder="Password" required
@field name="Confirm" label="Confirm password" type=password placeholder="Confirm password" required
:::

Already registered? [Sign in](/sign-in).
